using System.Text;
using AINotebook.Core.Ingestion;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    private T WriteRevision<T>(Func<SqliteConnection, SqliteTransaction, T> action)
    {
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            T result = action(_conn, tx);
            tx.Commit();
            return result;
        }
    }

    public SourceRevision InsertRevision(long sourceId, RevisionDraft draft, long now)
        => WriteRevision((c, tx) => RevisionJobSQL.InsertRevision(c, tx, sourceId, draft, now));

    public SourceRevision? Revision(long id)
    {
        lock (_gate) return RevisionJobSQL.ReadRevision(_conn, null, id);
    }

    public IReadOnlyList<RevisionPage> RevisionPages(long revisionId)
    {
        lock (_gate)
            return _conn.Query("""
                SELECT revision_id,page,char_start,char_end FROM revision_pages
                WHERE revision_id=$revisionId ORDER BY page
                """, new { revisionId }).Select(row => new RevisionPage((long)row.revision_id,
                    (int)row.page, (int)row.char_start, (int)row.char_end)).ToArray();
    }

    public bool PublishRevision(long sourceId, long revisionId, IReadOnlyList<RevisionChunkDraft> chunks, JobFence fence, long now)
        => WriteRevision((c, tx) => RevisionJobSQL.PublishRevision(c, tx, sourceId, revisionId, chunks, fence, now));

    public SourceRevision CommitForegroundRevision(long sourceId, RevisionDraft draft, IReadOnlyList<RevisionChunkDraft> chunks, long now, string leaseToken)
        => WriteRevision((c, tx) => RevisionJobSQL.CommitForegroundRevision(c, tx, sourceId, draft, chunks, now, leaseToken));

    public JobFence BeginExtraction(long sourceId, long now, string leaseToken)
        => WriteRevision((c, tx) => RevisionJobSQL.BeginExtraction(c, tx, sourceId, now, leaseToken));

    public SourceRevision? CommitExtraction(long sourceId, RevisionDraft draft, IReadOnlyList<RevisionChunkDraft> chunks, JobFence fence, long now)
        => WriteRevision((c, tx) => RevisionJobSQL.CommitExtraction(c, tx, sourceId, draft, chunks, fence, now));
}

/// <summary>Transaction kernels. Caller owns its connection's gate and transaction.</summary>
internal static partial class RevisionJobSQL
{
    internal static SourceRevision? ReadRevision(SqliteConnection c, SqliteTransaction? tx, long id)
    {
        var row = c.QuerySingleOrDefault("SELECT * FROM source_revisions WHERE id=$id", new { id }, tx);
        return row is null ? null : new SourceRevision((long)row.id, (long)row.source_id, (int)row.revision,
            new RevisionDraft((string)row.content_hash, (string)row.canonical_text, (int)row.text_format_version, (int)row.chunker_version),
            new DateTimeOffset(SqliteDate.FromDb((string)row.created_at)).ToUnixTimeSeconds());
    }

    internal static SourceRevision InsertRevision(SqliteConnection c, SqliteTransaction tx, long sourceId, RevisionDraft draft, long now)
    {
        if (string.IsNullOrEmpty(draft.ContentHash) || draft.TextFormatVersion is not (1 or SpreadsheetText.FormatVersion) || draft.ChunkerVersion is not (1 or 2))
            throw new StorageV19Exception("invalidValue");
        if (!c.ExecuteScalar<bool>("SELECT EXISTS(SELECT 1 FROM sources WHERE id=$sourceId)", new { sourceId }, tx))
            throw new StorageV19Exception("notFound");
        long id = c.ExecuteScalar<long>("""
            INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
            SELECT $sourceId,coalesce(max(revision),0)+1,$hash,$text,$format,$chunker,$created
            FROM source_revisions WHERE source_id=$sourceId;
            SELECT last_insert_rowid();
            """, new { sourceId, hash = draft.ContentHash, text = draft.CanonicalText,
                format = draft.TextFormatVersion, chunker = draft.ChunkerVersion,
                created = SqliteDate.ToDb(DateTimeOffset.FromUnixTimeSeconds(now).UtcDateTime) }, tx);
        c.Execute("UPDATE sources SET current_revision=$id WHERE id=$sourceId", new { id, sourceId }, tx);
        return ReadRevision(c, tx, id)!;
    }

    internal static void InsertChunkSet(SqliteConnection c, SqliteTransaction tx, long revisionId, IReadOnlyList<RevisionChunkDraft> chunks)
    {
        var revision = ReadRevision(c, tx, revisionId) ?? throw new StorageV19Exception("notFound");
        if (c.ExecuteScalar<bool>("""
            SELECT EXISTS(SELECT 1 FROM source_chunks WHERE revision_id=$revisionId)
              OR EXISTS(SELECT 1 FROM sources WHERE published_revision_id=$revisionId)
              OR EXISTS(SELECT 1 FROM ingest_jobs WHERE kind='extract' AND target_revision=$revisionId AND state='done')
            """, new { revisionId }, tx))
            throw new StorageV19Exception("immutableRevision");
        var scalars = revision.Draft.CanonicalText.EnumerateRunes().ToArray();
        foreach (var chunk in chunks)
        {
            if (chunk.Lang is not (null or "cs" or "sk" or "en" or "de" or "und")
                || chunk.LangInherited && chunk.Lang is null || chunk.TokenCount < 0)
                throw new StorageV19Exception("invalidValue");
            if (revision.Draft.ChunkerVersion == 1)
            {
                if (chunk.CharStart is not null || chunk.CharEnd is not null)
                    throw new StorageV19Exception("invalidSpan");
            }
            else
            {
                if (chunk.CharStart is not int start || chunk.CharEnd is not int end || start < 0 || start >= end || end > scalars.Length)
                    throw new StorageV19Exception("invalidSpan");
                string slice = string.Concat(scalars.Skip(start).Take(end - start).Select(r => r.ToString()));
                if (!string.Equals(slice, chunk.Text, StringComparison.Ordinal))
                    throw new StorageV19Exception("invalidSpan");
            }
        }
        for (int ord = 0; ord < chunks.Count; ord++)
        {
            var chunk = chunks[ord];
            c.Execute("""
                INSERT INTO source_chunks(source_id,revision_id,ord,text,token_count,page_hint,char_start,char_end,lang,lang_inherited)
                VALUES($source,$revisionId,$ord,$Text,$TokenCount,$PageHint,$CharStart,$CharEnd,$Lang,$LangInherited)
                """, new { source = revision.SourceId, revisionId, ord, chunk.Text, chunk.TokenCount, chunk.PageHint,
                    chunk.CharStart, chunk.CharEnd, chunk.Lang, chunk.LangInherited }, tx);
        }
    }

    internal static bool PublishRevision(SqliteConnection c, SqliteTransaction tx, long sourceId, long revisionId,
        IReadOnlyList<RevisionChunkDraft> chunks, JobFence fence, long now)
    {
        var job = ValidateFence(c, tx, fence, now);
        if (job is null) return false;
        var revision = ReadRevision(c, tx, revisionId) ?? throw new StorageV19Exception("notFound");
        if (revision.SourceId != sourceId || job.Draft.Kind != "extract" || job.Draft.Target != $"source:{sourceId}"
            || job.Draft.TargetRevision != revisionId)
            throw new StorageV19Exception("staleRevision");
        long? current = c.ExecuteScalar<long?>("SELECT current_revision FROM sources WHERE id=$sourceId", new { sourceId }, tx);
        if (current != revisionId)
        {
            CancelJob(c, tx, fence, now);
            return false;
        }
        InsertChunkSet(c, tx, revisionId, chunks);
        c.Execute("""
            UPDATE sources SET published_revision_id=$revisionId,status='ready',error=NULL,content_hash=$hash WHERE id=$sourceId
            """, new { sourceId, revisionId, hash = revision.Draft.ContentHash }, tx);
        RetryBudgetSQL.Clear(c, tx, sourceId);
        if (!FinishPublishedJob(c, tx, fence, now)) throw new StorageV19Exception("staleLease");
        return true;
    }

    internal static JobFence BeginExtraction(SqliteConnection c, SqliteTransaction tx, long sourceId, long now, string leaseToken)
    {
        var source = c.QuerySingleOrDefault("SELECT current_revision FROM sources WHERE id=$sourceId", new { sourceId }, tx)
            ?? throw new StorageV19Exception("notFound");
        // A foreground (re)ingestion is a user action on new or explicitly retried content (ingestion-retry-cap-v1 §5).
        RetryBudgetSQL.ResetIfGaveUp(c, tx, sourceId);
        string target = $"source:{sourceId}";
        c.Execute("""
            UPDATE ingest_jobs SET state='cancelled',lease_until=NULL,lease_token=NULL,next_retry_at=NULL
            WHERE kind='extract' AND target=$target
              AND (state IN ('queued','running','paused') OR (state='failed' AND next_retry_at IS NOT NULL))
            """, new { target }, tx);
        long id = EnqueueJob(c, tx, new IngestJobDraft("extract", target, (long?)source.current_revision), now);
        var job = ClaimJob(c, tx, now, leaseToken, id) ?? throw new StorageV19Exception("staleLease");
        c.Execute("UPDATE sources SET status='chunking',error=NULL WHERE id=$sourceId", new { sourceId }, tx);
        return new JobFence(job.Id, leaseToken);
    }

    internal static SourceRevision? CommitExtraction(SqliteConnection c, SqliteTransaction tx, long sourceId, RevisionDraft draft,
        IReadOnlyList<RevisionChunkDraft> chunks, JobFence fence, long now)
    {
        var job = ValidateFence(c, tx, fence, now);
        if (job is null || job.Draft.Kind != "extract" || job.Draft.Target != $"source:{sourceId}") return null;
        var source = c.QuerySingleOrDefault("SELECT current_revision FROM sources WHERE id=$sourceId", new { sourceId }, tx);
        if (source is null || (long?)source.current_revision != job.Draft.TargetRevision)
        {
            CancelJob(c, tx, fence, now);
            return null;
        }
        var revision = InsertRevision(c, tx, sourceId, draft, now);
        c.Execute("UPDATE ingest_jobs SET target_revision=$revisionId WHERE id=$id", new { revisionId = revision.Id, id = job.Id }, tx);
        if (!PublishRevision(c, tx, sourceId, revision.Id, chunks, fence, now)) throw new StorageV19Exception("staleLease");
        return revision;
    }

    internal static SourceRevision CommitForegroundRevision(SqliteConnection c, SqliteTransaction tx, long sourceId,
        RevisionDraft draft, IReadOnlyList<RevisionChunkDraft> chunks, long now, string leaseToken)
    {
        var fence = BeginExtraction(c, tx, sourceId, now, leaseToken);
        return CommitExtraction(c, tx, sourceId, draft, chunks, fence, now) ?? throw new StorageV19Exception("staleLease");
    }
}

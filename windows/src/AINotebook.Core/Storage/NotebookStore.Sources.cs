using AINotebook.Core.Models;
using Dapper;
using Microsoft.Data.Sqlite;
using System.Security.Cryptography;
using System.Text;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    private static Source MapSource(dynamic r) => new Source(
        (long)r.id, (long)r.notebook_id,
        SourceTypeExtensions.FromDb((string)r.type), (string)r.title,
        r.uri is null ? null : (string)r.uri,
        r.raw_path is null ? null : (string)r.raw_path,
        SourceStatusExtensions.FromDb((string)r.status),
        r.error is null ? null : (string)r.error,
        SqliteDate.FromDb((string)r.ingested_at),
        r.last_synced_at is null ? (DateTime?)null : SqliteDate.FromDb((string)r.last_synced_at),
        r.content_hash is null ? null : (string)r.content_hash,
        (long?)r.folder_id, (string?)r.rel_path, (long?)r.mtime, (long?)r.size_bytes,
        (string)r.availability, (long)r.eligible != 0, (string?)r.lang, (string?)r.lang_coverage,
        (string?)r.descriptor, (long?)r.current_revision, (long?)r.published_revision_id, (string?)r.encoding);

    public Source CreateSource(long notebookId, SourceType type, string title, string? uri, string? rawPath)
    {
        lock (_gate)
        {
            var trimmed = title.Trim();
            if (trimmed.Length == 0) throw new StoreException.InvalidSourceTitle(title);
            var now = DateTime.UtcNow;
            var id = Connection.ExecuteScalar<long>(
                """
                INSERT INTO sources(notebook_id, type, title, uri, raw_path, status, error, ingested_at)
                VALUES($nb, $type, $title, $uri, $raw, $status, NULL, $ingested);
                SELECT last_insert_rowid();
                """,
                new
                {
                    nb = notebookId, type = type.ToDb(), title = trimmed, uri, raw = rawPath,
                    status = SourceStatus.Pending.ToDb(), ingested = SqliteDate.ToDb(now)
                });
            return new Source(id, notebookId, type, trimmed, uri, rawPath, SourceStatus.Pending, null, now);
        }
    }

    private const string SourceCols =
        "id, notebook_id, type, title, uri, raw_path, status, error, ingested_at, last_synced_at, content_hash, " +
        "folder_id, rel_path, mtime, size_bytes, availability, eligible, lang, lang_coverage, descriptor, current_revision, published_revision_id, encoding";

    public IReadOnlyList<Source> Sources(long notebookId)
    {
        lock (_gate)
            return Connection.Query(
                $"SELECT {SourceCols} FROM sources WHERE notebook_id=$nb AND type<>'note' ORDER BY ingested_at DESC",
                new { nb = notebookId })
                .Select(r => (Source)MapSource(r)).ToList();
    }

    public IReadOnlyList<Source> SourcesIncludingShadow(long notebookId)
    {
        lock (_gate)
            return Connection.Query(
                $"SELECT {SourceCols} FROM sources WHERE notebook_id=$nb ORDER BY ingested_at DESC",
                new { nb = notebookId })
                .Select(r => (Source)MapSource(r)).ToList();
    }

    public Source? Source(long id)
    {
        lock (_gate)
        {
            var row = Connection.QueryFirstOrDefault(
                $"SELECT {SourceCols} FROM sources WHERE id=$id", new { id });
            return row is null ? null : MapSource(row);
        }
    }

    public void UpdateSourceStatus(long id, SourceStatus status, string? error)
    {
        lock (_gate)
        {
            var rows = Connection.Execute(
                "UPDATE sources SET status=$status, error=$error WHERE id=$id",
                new { status = status.ToDb(), error, id });
            if (rows == 0) throw new StoreException.SourceNotFound(id);
        }
    }

    public void UpdateSourceTitle(long id, string title)
    {
        lock (_gate)
        {
            using var cmd = Connection.CreateCommand();
            cmd.CommandText = "UPDATE sources SET title = $t WHERE id = $id";
            cmd.Parameters.AddWithValue("$t", title);
            cmd.Parameters.AddWithValue("$id", id);
            cmd.ExecuteNonQuery();
        }
    }

    public void UpdateSourceSyncInfo(long id, DateTime lastSyncedAt, string contentHash)
    {
        lock (_gate)
        {
            Connection.Execute(
                "UPDATE sources SET last_synced_at=$ts, content_hash=$hash WHERE id=$id",
                new { ts = SqliteDate.ToDb(lastSyncedAt), hash = contentHash, id });
        }
    }

    public void DeleteSource(long id)
    {
        lock (_gate)
        {
            var rows = Connection.Execute("DELETE FROM sources WHERE id=$id", new { id });
            if (rows == 0) throw new StoreException.SourceNotFound(id);
        }
    }

    public void ReplaceChunks(long sourceId, IReadOnlyList<ChunkDraft> chunks)
    {
        lock (_gate)
        {
            using var tx = Connection.BeginTransaction();
            string text = string.Join("\n\n", chunks.Select(chunk => chunk.Text));
            string hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
            RevisionJobSQL.CommitForegroundRevision(Connection, tx, sourceId, new(hash, text, 1, 1),
                chunks.Select(chunk => new RevisionChunkDraft(chunk.Text, chunk.TokenCount, chunk.PageHint, null, null, null, false)).ToArray(),
                DateTimeOffset.UtcNow.ToUnixTimeSeconds(), Guid.NewGuid().ToString("N"));
            tx.Commit();
        }
    }

    public IReadOnlyList<SourceChunk> Chunks(long sourceId)
    {
        lock (_gate)
            return Connection.Query(
                $"SELECT {ChunkColumns} FROM source_chunks sc JOIN sources s ON s.published_revision_id=sc.revision_id WHERE s.id=$sid ORDER BY sc.ord ASC",
                new { sid = sourceId })
                .Select(r => (SourceChunk)MapChunk(r))
                .ToList();
    }

    private const string ChunkColumns = "sc.id,sc.source_id,sc.ord,sc.text,sc.token_count,sc.page_hint,sc.context,sc.revision_id,sc.char_start,sc.char_end,sc.lang,sc.lang_inherited";

    private static SourceChunk MapChunk(dynamic r) => new((long)r.id, (long)r.source_id, (int)r.ord,
        (string)r.text, (int)r.token_count, (int?)(long?)r.page_hint, (string?)r.context,
        (long?)r.revision_id, (int?)(long?)r.char_start, (int?)(long?)r.char_end, (string?)r.lang, (long)r.lang_inherited != 0);

    public void SetChunkContext(long sourceId, long? chunkId, string context)
    {
        lock (_gate)
        {
            if (chunkId is null) return;
            Connection.Execute(
                "UPDATE source_chunks SET context=$ctx WHERE id=$id",
                new { ctx = context, id = chunkId });
        }
    }

    /// <summary>The persisted summary for a source, or null if not yet computed.</summary>
    public string? SourceSummary(long id)
    {
        lock (_gate)
            return Connection.ExecuteScalar<string?>(
                "SELECT summary FROM sources WHERE id=$id", new { id });
    }

    public void SetSourceSummary(long id, string text)
    {
        lock (_gate)
            Connection.Execute(
                "UPDATE sources SET summary=$text WHERE id=$id", new { text, id });
    }
}

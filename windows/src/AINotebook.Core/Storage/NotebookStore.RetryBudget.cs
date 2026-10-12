using System.Globalization;
using AINotebook.Core.Models;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

/// <summary>
/// The extraction failure budget (contract <c>ingestion-retry-cap-v1</c>, same values as macOS
/// <c>ExtractionRetryBudget</c>). A source — folder member or loose — whose extraction failed <see cref="Failures"/> times
/// for the same content is given up: it stays <c>error</c>, scans treat it as settled and nothing re-queues it until the
/// content changes or the user explicitly retries.
/// </summary>
public static class ExtractionRetryBudget
{
    /// <summary>Failed attempts per source and content (counted across jobs).</summary>
    public const int Failures = 3;

    /// <summary>
    /// Attempts of one extract job (folder or loose source). Scan, embed and gc jobs keep five; the frozen job fixtures
    /// that pinned five for extract jobs are superseded by <c>ingestion-retry-cap-v1</c> (§1a).
    /// </summary>
    public const int ExtractMaxAttempts = 3;

    /// <summary>Attempts of every other job (frozen <c>folder-rag-v1</c> value).</summary>
    internal const int OtherMaxAttempts = 5;

    /// <summary>Error code of a loose source whose queued retry has nothing to re-read (no local file, no URL).</summary>
    public const string RetryUnavailable = "retryUnavailable";

    /// <summary>
    /// Single switch for automatic (background) re-fetches of a failed loose web source (§3a). Off (user decision
    /// 2026-10-11): only an explicit user action fetches — a failed URL attempt is never retried automatically (its job
    /// ends terminally, the failure still counts), and the worker fetches a URL only for the first attempt of a job queued
    /// by an explicit Retry (<see cref="UserRetryKey"/>). Same value as macOS.
    /// </summary>
    public const bool BackgroundWebRetry = false;

    /// <summary><c>ingest_jobs.options_json</c> key marking an extract job queued by an explicit user retry.</summary>
    public const string UserRetryKey = "userRetry";
}

public sealed partial class NotebookStore
{
    /// <summary>
    /// Explicit user retry of one failed source: resets its failure budget and queues extraction. Returns false (changing
    /// nothing) unless the source is a present, eligible source with status <c>error</c> that can be re-read: a folder
    /// member, or a loose source with a local file or a URL (§5).
    /// </summary>
    public bool RetryFailedExtraction(long sourceId, long now)
    {
        long? notebookId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            notebookId = _conn.QuerySingleOrDefault<long?>(
                $"SELECT notebook_id FROM sources WHERE id=$sourceId AND {RetryBudgetSQL.RetryablePredicate}", new { sourceId }, tx);
            if (notebookId is null) return false;
            RetryUser(tx, sourceId, now);
            tx.Commit();
        }
        NotifyFolderIngestionChanged(notebookId.Value);
        return true;
    }

    /// <summary>
    /// "Retry all failed": <see cref="RetryFailedExtraction"/> for every retryable failed source (folder and loose) of the
    /// notebook in ascending id. Returns the number of retried sources.
    /// </summary>
    public int RetryFailedExtractions(long notebookId, long now)
    {
        int count;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var ids = _conn.Query<long>(
                $"SELECT id FROM sources WHERE notebook_id=$notebookId AND {RetryBudgetSQL.RetryablePredicate} ORDER BY id",
                new { notebookId }, tx).ToArray();
            foreach (long sourceId in ids)
            {
                RetryUser(tx, sourceId, now);
            }
            count = ids.Length;
            tx.Commit();
        }
        if (count > 0) NotifyFolderIngestionChanged(notebookId);
        return count;
    }

    /// <summary>
    /// An explicit retry: a given-up budget starts over, otherwise the attempt simply counts; the queued job is marked as
    /// user-initiated (§5).
    /// </summary>
    private void RetryUser(SqliteTransaction tx, long sourceId, long now)
    {
        RetryBudgetSQL.ResetIfGaveUp(_conn, tx, sourceId);
        RequireExtraction(tx, sourceId, keepRunning: true, now);
        _conn.Execute($"""
            UPDATE ingest_jobs SET options_json=json_set(options_json,'$.{ExtractionRetryBudget.UserRetryKey}',json('true'))
            WHERE kind='extract' AND target=$target AND state='queued' AND attempts=0
            """, new { target = SourceTarget(sourceId) }, tx);
    }

    /// <summary>The loose (non-folder) source a queued extract job re-reads, or null for a folder member or a missing source.</summary>
    internal LooseExtractionTarget? LooseExtractionTarget(long sourceId)
    {
        lock (_gate)
        {
            var row = _conn.QuerySingleOrDefault(
                "SELECT notebook_id,type,raw_path,uri FROM sources WHERE id=$sourceId AND folder_id IS NULL", new { sourceId });
            if (row is null) return null;
            var type = SourceTypeExtensions.FromDb((string)row.type);
            string? raw = row.raw_path, uri = row.uri;
            return new LooseExtractionTarget(sourceId, (long)row.notebook_id, type,
                type is SourceType.Web or SourceType.Note ? null : raw,
                type == SourceType.Web && uri is not null && Uri.TryCreate(uri, UriKind.Absolute, out var url) ? url : null);
        }
    }

    /// <summary>
    /// A loose source's queued retry has nothing to re-read: the owned job ends terminally (no attempt is counted) and an
    /// owned source becomes <c>error</c> <c>retryUnavailable</c> instead of staying <c>chunking</c> (§3a).
    /// </summary>
    public bool AbandonLooseExtraction(JobFence fence, long now)
    {
        ArgumentNullException.ThrowIfNull(fence);
        long? notebookId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var job = RevisionJobSQL.ValidateFence(_conn, tx, fence, now);
            if (job is null || job.Draft.Kind != "extract" || !job.Draft.Target.StartsWith("source:", StringComparison.Ordinal))
                return false;
            long sourceId = long.Parse(job.Draft.Target["source:".Length..], NumberStyles.None, CultureInfo.InvariantCulture);
            string code = ExtractionRetryBudget.RetryUnavailable;
            if (_conn.Execute("""
                UPDATE ingest_jobs SET state='failed',next_retry_at=NULL,error=$code,lease_until=NULL,lease_token=NULL
                WHERE id=$id AND state='running' AND lease_token=$token AND lease_until>$now
                """, new { code, id = fence.JobId, token = fence.LeaseToken, now }, tx) != 1)
                return false;
            _conn.Execute("""
                UPDATE sources SET status='error',error=$code WHERE id=$sourceId AND current_revision IS $revision
                    AND NOT EXISTS (SELECT 1 FROM ingest_jobs WHERE kind='extract' AND target=$target AND id>$jobId AND attempts>0)
                """, new { code, sourceId, revision = job.Draft.TargetRevision, target = job.Draft.Target, jobId = job.Id }, tx);
            notebookId = RevisionJobSQL.NotebookOf(_conn, tx, job.Draft.Target);
            tx.Commit();
        }
        if (notebookId is long notebook) NotifyFolderIngestionChanged(notebook);
        return true;
    }

    /// <summary>Ids of the notebook's sources whose extraction was given up.</summary>
    public IReadOnlySet<long> GaveUpSourceIds(long notebookId)
    {
        lock (_gate)
            return _conn.Query<long>(
                $"SELECT id FROM sources WHERE notebook_id=$notebookId AND {RetryBudgetSQL.GaveUpPredicate}",
                new { notebookId }).ToHashSet();
    }
}

/// <summary>What the folder worker re-reads for a loose source: its local file path, or its URL (web sources).</summary>
internal sealed record LooseExtractionTarget(long SourceId, long NotebookId, SourceType Kind, string? File, Uri? Url);

/// <summary>Transaction-scoped budget operations. The caller holds its connection gate.</summary>
internal static class RetryBudgetSQL
{
    /// <summary>A source (unqualified <c>sources</c> columns) whose extraction was given up (3 = <see cref="ExtractionRetryBudget.Failures"/>).</summary>
    internal const string GaveUpPredicate =
        "(status='error' AND coalesce((SELECT b.failures FROM source_extract_budget b WHERE b.source_id=sources.id),0)>=3)";

    /// <summary>The source aliased <c>s</c> has budget left (3 = <see cref="ExtractionRetryBudget.Failures"/>).</summary>
    internal const string BudgetLeftPredicate =
        "coalesce((SELECT b.failures FROM source_extract_budget b WHERE b.source_id=s.id),0)<3";

    /// <summary>
    /// A failed source the user may retry: a folder member, or a loose source the folder worker can re-read (a local file
    /// or a URL; never a note).
    /// </summary>
    internal const string RetryablePredicate =
        "status='error' AND availability='present' AND eligible=1 AND type<>'note'" +
        " AND (folder_id IS NOT NULL OR raw_path IS NOT NULL OR uri IS NOT NULL)";

    /// <summary>An explicit user action on unchanged content: a spent budget starts over; one with attempts left keeps counting.</summary>
    internal static void ResetIfGaveUp(SqliteConnection c, SqliteTransaction tx, long sourceId)
    {
        if (Exhausted(c, tx, sourceId)) Reset(c, tx, sourceId);
    }

    /// <summary>Whether <paramref name="job"/> was queued by an explicit user retry and this is its first attempt.</summary>
    internal static bool UserInitiated(IngestJob job)
    {
        if (job.Attempts != 1) return false;
        try
        {
            using var options = System.Text.Json.JsonDocument.Parse(job.Draft.OptionsJson);
            return options.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object
                && options.RootElement.TryGetProperty(ExtractionRetryBudget.UserRetryKey, out var flag)
                && flag.ValueKind == System.Text.Json.JsonValueKind.True;
        }
        catch (System.Text.Json.JsonException) { return false; }
    }

    /// <summary>Clears the failure count; the recorded content hash stays (same content).</summary>
    internal static void Reset(SqliteConnection c, SqliteTransaction tx, long sourceId) =>
        c.Execute("UPDATE source_extract_budget SET failures=0 WHERE source_id=$sourceId", new { sourceId }, tx);

    /// <summary>Forgets the budget: the source is settled (<c>ready</c>).</summary>
    internal static void Clear(SqliteConnection c, SqliteTransaction tx, long sourceId) =>
        c.Execute("DELETE FROM source_extract_budget WHERE source_id=$sourceId", new { sourceId }, tx);

    internal static bool Exhausted(SqliteConnection c, SqliteTransaction tx, long sourceId) =>
        (c.QuerySingleOrDefault<long?>("SELECT failures FROM source_extract_budget WHERE source_id=$sourceId",
            new { sourceId }, tx) ?? 0) >= ExtractionRetryBudget.Failures;

    /// <summary>
    /// A scan observed the file: a different content resets the budget (§4). <paramref name="hash"/> is null when the
    /// scanner did not read the file; <paramref name="sameStamp"/> compares the observed mtime/size with the stored ones.
    /// </summary>
    internal static void Observe(SqliteConnection c, SqliteTransaction tx, long sourceId, string? hash, bool sameStamp)
    {
        string? stored = c.QuerySingleOrDefault<string?>(
            "SELECT content_hash FROM source_extract_budget WHERE source_id=$sourceId", new { sourceId }, tx);
        if (hash is not null)
        {
            if (stored is not null && StringComparer.Ordinal.Equals(stored, hash)) return;
            // Unknown content with an unchanged stamp is the same content: adopt the hash.
            bool keep = stored is null && sameStamp;
            c.Execute("""
                INSERT INTO source_extract_budget(source_id,failures,content_hash) VALUES($sourceId,0,$hash)
                ON CONFLICT(source_id) DO UPDATE SET content_hash=excluded.content_hash,
                    failures=CASE WHEN $keep THEN failures ELSE 0 END
                """, new { sourceId, hash, keep }, tx);
        }
        else if (!sameStamp)
        {
            Clear(c, tx, sourceId);
        }
    }

    /// <summary>
    /// Records one failed attempt of <paramref name="job"/> against its folder source when the job still owns the source
    /// status, and returns whether the job is exhausted: its own attempt cap, or the source budget spent (§3).
    /// </summary>
    internal static bool RecordFailure(SqliteConnection c, SqliteTransaction tx, IngestJob job)
    {
        if (job.Draft.Kind != "extract" || !job.Draft.Target.StartsWith("source:", StringComparison.Ordinal)
            || !long.TryParse(job.Draft.Target["source:".Length..], NumberStyles.None, CultureInfo.InvariantCulture, out long sourceId))
            return job.Attempts >= ExtractionRetryBudget.OtherMaxAttempts;
        int changed = c.Execute("""
            INSERT INTO source_extract_budget(source_id,failures)
            SELECT id,1 FROM sources WHERE id=$sourceId AND current_revision IS $revision AND type<>'note'
              AND NOT EXISTS (SELECT 1 FROM ingest_jobs WHERE kind='extract' AND target=$target AND id>$jobId AND attempts>0)
            ON CONFLICT(source_id) DO UPDATE SET failures=failures+1
            """, new { sourceId, revision = job.Draft.TargetRevision, target = job.Draft.Target, jobId = job.Id }, tx);
        bool spent = changed == 1 && Exhausted(c, tx, sourceId);
        // Without background web retries a loose URL's failed attempt is final: only the user fetches again.
        bool looseWeb = !ExtractionRetryBudget.BackgroundWebRetry && c.ExecuteScalar<long?>(
            "SELECT folder_id IS NULL AND type='web' FROM sources WHERE id=$sourceId", new { sourceId }, tx) == 1;
        return spent || looseWeb || job.Attempts >= ExtractionRetryBudget.ExtractMaxAttempts;
    }
}

using System.Globalization;
using System.Text.Json;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    public long EnqueueJob(IngestJobDraft draft, long now)
    {
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction(deferred: false);
            long id = RevisionJobSQL.EnqueueJob(_conn, transaction, draft, now);
            transaction.Commit();
            return id;
        }
    }

    public IngestJob? Job(long id)
    {
        lock (_gate) return RevisionJobSQL.Job(_conn, null, id);
    }

    /// <summary>Replace coalesced options only before the first claim, while the job is queued.</summary>
    public bool CoalesceQueuedJobOptions(long id, string optionsJson)
        => WriteRevision((c, tx) => RevisionJobSQL.CoalesceQueuedJobOptions(c, tx, id, optionsJson));

    /// <summary>Requeues due retryable jobs; posts <see cref="FolderIngestionChanged"/> per affected notebook.</summary>
    public int RequeueRetryableJobs(long now)
    {
        int count;
        IReadOnlySet<long> notebooks;
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction(deferred: false);
            notebooks = RevisionJobSQL.NotebooksOf(_conn, transaction, RevisionJobSQL.RetryableSql, now);
            count = RevisionJobSQL.RequeueRetryableJobs(_conn, transaction, now);
            transaction.Commit();
        }
        NotifyIndexingStatusChanged(notebooks);
        return count;
    }

    /// <summary>Posts for the claimed job's notebook and every notebook whose expired lease the claim recovered.</summary>
    public IngestJob? ClaimJob(long now, string leaseToken, long? id = null)
    {
        IngestJob? job;
        HashSet<long> notebooks;
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction(deferred: false);
            notebooks = new HashSet<long>(RevisionJobSQL.NotebooksOf(_conn, transaction, RevisionJobSQL.ExpiredSql, now));
            job = RevisionJobSQL.ClaimJob(_conn, transaction, now, leaseToken, id);
            if (job is not null && RevisionJobSQL.NotebookOf(_conn, transaction, job.Draft.Target) is long notebook)
                notebooks.Add(notebook);
            transaction.Commit();
        }
        NotifyIndexingStatusChanged(notebooks);
        return job;
    }

    public int RecoverExpiredJobs(long now)
    {
        int count;
        IReadOnlySet<long> notebooks;
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction(deferred: false);
            notebooks = RevisionJobSQL.NotebooksOf(_conn, transaction, RevisionJobSQL.ExpiredSql, now);
            count = RevisionJobSQL.RecoverExpiredJobs(_conn, transaction, now);
            transaction.Commit();
        }
        NotifyIndexingStatusChanged(notebooks);
        return count;
    }

    public bool RenewJob(JobFence fence, long now)
    {
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction(deferred: false);
            bool changed = RevisionJobSQL.RenewJob(_conn, transaction, fence, now);
            transaction.Commit();
            return changed;
        }
    }

    /// <summary>Fenced completion (e.g. an empty bootstrap); posts for the job's notebook.</summary>
    public bool CompleteJob(JobFence fence, long now, string? target = null)
    {
        bool changed;
        long? notebook = null;
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction(deferred: false);
            var job = RevisionJobSQL.Job(_conn, transaction, fence.JobId);
            changed = RevisionJobSQL.CompleteJob(_conn, transaction, fence, now, target);
            if (changed && job is not null) notebook = RevisionJobSQL.NotebookOf(_conn, transaction, job.Draft.Target);
            transaction.Commit();
        }
        if (notebook is long id) NotifyIndexingStatusChanged(id);
        return changed;
    }

    /// <summary>Continue the same bootstrap attempt after discovering its generation's dimensions.</summary>
    public bool RetargetEmbedJob(JobFence fence, long generationId, long now)
        => WriteRevision((c, tx) => RevisionJobSQL.RetargetEmbedJob(c, tx, fence,
            $"generation:{generationId.ToString(CultureInfo.InvariantCulture)}", now));

    public bool FailJob(JobFence fence, string error, long now)
    {
        bool changed;
        long? notebook = null;
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction(deferred: false);
            var job = RevisionJobSQL.Job(_conn, transaction, fence.JobId);
            changed = RevisionJobSQL.FailJob(_conn, transaction, fence, error, now);
            if (changed && job is not null) notebook = RevisionJobSQL.NotebookOf(_conn, transaction, job.Draft.Target);
            transaction.Commit();
        }
        if (notebook is long id) NotifyIndexingStatusChanged(id);
        return changed;
    }

    public bool RetryJob(long id, long now)
    {
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction(deferred: false);
            bool changed = RevisionJobSQL.RetryJob(_conn, transaction, id, now);
            transaction.Commit();
            return changed;
        }
    }

    public void PauseJob(long id)
    {
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction(deferred: false);
            RevisionJobSQL.PauseJob(_conn, transaction, id);
            transaction.Commit();
        }
    }

    public void ResumeJob(long id, long now)
    {
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction(deferred: false);
            RevisionJobSQL.ResumeJob(_conn, transaction, id, now);
            transaction.Commit();
        }
    }

    public void CancelJob(long id)
    {
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction(deferred: false);
            RevisionJobSQL.CancelJob(_conn, transaction, id);
            transaction.Commit();
        }
    }

    /// <summary>Fenced cancellation (e.g. the owned extraction of a gone source); posts for the job's notebook.</summary>
    public bool CancelJob(JobFence fence, long now)
    {
        bool changed;
        long? notebook = null;
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction(deferred: false);
            var job = RevisionJobSQL.Job(_conn, transaction, fence.JobId);
            changed = RevisionJobSQL.CancelJob(_conn, transaction, fence, now);
            if (changed && job is not null) notebook = RevisionJobSQL.NotebookOf(_conn, transaction, job.Draft.Target);
            transaction.Commit();
        }
        if (notebook is long id) NotifyIndexingStatusChanged(id);
        return changed;
    }
}

/// <summary>Transaction-scoped operations. The caller holds its connection gate.</summary>
internal static partial class RevisionJobSQL
{
    /// <summary>Running jobs whose lease expired (recovered by RecoverExpiredJobs).</summary>
    internal const string ExpiredSql = "SELECT target FROM ingest_jobs WHERE state='running' AND lease_until<=$now";

    /// <summary>Failed jobs whose automatic retry is due (requeued by RequeueRetryableJobs).</summary>
    internal const string RetryableSql =
        "SELECT target FROM ingest_jobs WHERE state='failed' AND attempts<5 AND next_retry_at IS NOT NULL AND next_retry_at<=$now";

    /// <summary>The notebook a job target belongs to; null when the target row is gone.</summary>
    internal static long? NotebookOf(SqliteConnection c, SqliteTransaction? tx, string target)
    {
        int colon = target.IndexOf(':');
        if (colon < 0 || !long.TryParse(target[(colon + 1)..], NumberStyles.None, CultureInfo.InvariantCulture, out long id)) return null;
        string? sql = target[..colon] switch
        {
            "folder" => "SELECT notebook_id FROM folder_sources WHERE id=$id",
            "source" => "SELECT notebook_id FROM sources WHERE id=$id",
            "notebook" => "SELECT id FROM notebooks WHERE id=$id",
            "generation" => "SELECT notebook_id FROM index_generations WHERE id=$id",
            _ => null
        };
        return sql is null ? null : c.QuerySingleOrDefault<long?>(sql, new { id }, tx);
    }

    /// <summary>Notebooks of the job targets a <c>SELECT target …</c> query with <c>$now</c> returns.</summary>
    internal static IReadOnlySet<long> NotebooksOf(SqliteConnection c, SqliteTransaction? tx, string sql, long now) =>
        c.Query<string>(sql, new { now }, tx).Select(target => NotebookOf(c, tx, target)).OfType<long>().ToHashSet();

    internal static IngestJob? Job(SqliteConnection c, SqliteTransaction? tx, long id)
    {
        var row = c.QuerySingleOrDefault("SELECT * FROM ingest_jobs WHERE id=$id", new { id }, tx);
        return row is null ? null : ReadJob(row);
    }

    internal static long EnqueueJob(SqliteConnection c, SqliteTransaction tx, IngestJobDraft draft, long now)
    {
        ValidateJobTarget(c, tx, draft);
        ValidateOptions(draft.OptionsJson);
        return c.ExecuteScalar<long>("""
            INSERT INTO ingest_jobs(kind,target,target_revision,next_retry_at,options_json)
            VALUES($kind,$target,$revision,$now,$options); SELECT last_insert_rowid();
            """, new { kind = draft.Kind, target = draft.Target, revision = draft.TargetRevision, now, options = draft.OptionsJson }, tx);
    }

    internal static bool CoalesceQueuedJobOptions(SqliteConnection c, SqliteTransaction tx, long id, string optionsJson)
    {
        ValidateOptions(optionsJson);
        return c.Execute("""
            UPDATE ingest_jobs SET options_json=$optionsJson WHERE id=$id AND state='queued' AND attempts=0
            """, new { id, optionsJson }, tx) == 1;
    }

    private static void ValidateOptions(string optionsJson)
    {
        if (string.IsNullOrWhiteSpace(optionsJson)) throw new StorageV19Exception("invalidValue");
        try
        {
            using var json = JsonDocument.Parse(optionsJson);
            if (json.RootElement.ValueKind != JsonValueKind.Object) throw new StorageV19Exception("invalidValue");
        }
        catch (JsonException) { throw new StorageV19Exception("invalidValue"); }
    }

    internal static IngestJob? ClaimJob(SqliteConnection c, SqliteTransaction tx, long now, string leaseToken, long? id)
    {
        if (string.IsNullOrWhiteSpace(leaseToken)) throw new StorageV19Exception("invalidValue");
        RecoverExpiredJobs(c, tx, now);
        while (true)
        {
            long? selected = c.QuerySingleOrDefault<long?>("""
                SELECT id FROM ingest_jobs
                WHERE state='queued' AND attempts<5 AND (next_retry_at IS NULL OR next_retry_at<=$now)
                    AND ($id IS NULL OR id=$id)
                ORDER BY next_retry_at,id LIMIT 1
                """, new { now, id }, tx);
            if (selected is null) return null;
            var job = Job(c, tx, selected.Value)!;
            if (!ValidateQueuedTarget(c, tx, job)) continue;
            int changed = c.Execute("""
                UPDATE ingest_jobs SET state='running',attempts=attempts+1,next_retry_at=NULL,
                    lease_until=$leaseUntil,lease_token=$leaseToken,error=NULL
                WHERE id=$selected AND state='queued' AND attempts<5
                    AND (next_retry_at IS NULL OR next_retry_at<=$now)
                """, new { selected, now, leaseToken, leaseUntil = LeaseDeadline(now) }, tx);
            if (changed != 1) return null;
            UpdateExtractStatus(c, tx, job, "chunking", null);
            return Job(c, tx, selected.Value);
        }
    }

    internal static IngestJob? ValidateFence(SqliteConnection c, SqliteTransaction tx, JobFence fence, long now)
    {
        if (string.IsNullOrWhiteSpace(fence.LeaseToken)) return null;
        var row = c.QuerySingleOrDefault("""
            SELECT * FROM ingest_jobs WHERE id=$id AND state='running'
                AND lease_token=$token AND lease_until>$now
            """, new { id = fence.JobId, token = fence.LeaseToken, now }, tx);
        return row is null ? null : ReadJob(row);
    }

    internal static int RecoverExpiredJobs(SqliteConnection c, SqliteTransaction tx, long now)
    {
        var expired = c.Query("SELECT * FROM ingest_jobs WHERE state='running' AND lease_until<=$now ORDER BY id", new { now }, tx)
            .Select(row => (IngestJob)ReadJob(row)).ToArray();
        int recovered = 0;
        foreach (var job in expired)
        {
            // A lease expiry is a failed attempt (ingestion-retry-cap-v1 §3).
            bool exhausted = RetryBudgetSQL.RecordFailure(c, tx, job);
            // A retryable refresh stays pending; only exhaustion is a source error.
            UpdateOwnedExtractStatus(c, tx, job, exhausted ? "error" : "pending", exhausted ? "leaseExpired" : null);
            recovered += c.Execute("""
                UPDATE ingest_jobs SET state=CASE WHEN $exhausted THEN 'failed' ELSE 'queued' END,
                    next_retry_at=CASE WHEN $exhausted THEN NULL ELSE $now+(30*(1<<attempts)) END,
                    lease_until=NULL,lease_token=NULL,error='leaseExpired'
                WHERE id=$id AND state='running' AND lease_until<=$now
                """, new { id = job.Id, exhausted, now }, tx);
        }
        return recovered;
    }

    internal static bool RenewJob(SqliteConnection c, SqliteTransaction tx, JobFence fence, long now)
    {
        if (ValidateFence(c, tx, fence, now) is null) return false;
        return c.Execute("""
            UPDATE ingest_jobs SET lease_until=$deadline WHERE id=$id AND state='running'
                AND lease_token=$token AND lease_until>$now
            """, new { id = fence.JobId, token = fence.LeaseToken, now, deadline = LeaseDeadline(now) }, tx) == 1;
    }

    internal static bool CompleteJob(SqliteConnection c, SqliteTransaction tx, JobFence fence, long now, string? target = null)
    {
        var job = ValidateFence(c, tx, fence, now);
        if (job is null) return false;
        if (job.Draft.Kind == "extract") throw new StorageV19Exception("invalidValue");
        if (target is not null && !RetargetEmbedJob(c, tx, fence, target, now)) return false;
        return FinishPublishedJob(c, tx, fence, now);
    }

    internal static bool RetargetEmbedJob(SqliteConnection c, SqliteTransaction tx, JobFence fence, string target, long now)
    {
        var job = ValidateFence(c, tx, fence, now);
        if (job is null) return false;
        if (job.Draft.Kind != "embed" || !TryParseTarget(job.Draft.Target, out string fromKind, out long notebookId)
            || fromKind != "notebook" || !TryParseTarget(target, out string toKind, out long generationId) || toKind != "generation")
            throw new StorageV19Exception("invalidValue");
        ValidateJobTarget(c, tx, job.Draft);
        ValidateJobTarget(c, tx, job.Draft with { Target = target });
        if (c.ExecuteScalar<long>("SELECT notebook_id FROM index_generations WHERE id=$generationId", new { generationId }, tx) != notebookId)
            throw new StorageV19Exception("notebookMismatch");
        return c.Execute("""
            UPDATE ingest_jobs SET target=$target WHERE id=$id AND state='running'
                AND lease_token=$token AND lease_until>$now
            """, new { target, id = fence.JobId, token = fence.LeaseToken, now }, tx) == 1;
    }

    internal static bool FinishPublishedJob(SqliteConnection c, SqliteTransaction tx, JobFence fence, long now)
        => c.Execute("""
            UPDATE ingest_jobs SET state='done',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
            WHERE id=$id AND state='running' AND lease_token=$token AND lease_until>$now
            """, new { id = fence.JobId, token = fence.LeaseToken, now }, tx) == 1;

    internal static bool FailJob(SqliteConnection c, SqliteTransaction tx, JobFence fence, string error, long now)
    {
        var job = ValidateFence(c, tx, fence, now);
        if (job is null) return false;
        bool exhausted = RetryBudgetSQL.RecordFailure(c, tx, job);
        UpdateOwnedExtractStatus(c, tx, job, "error", error);
        return c.Execute("""
            UPDATE ingest_jobs SET state='failed',
                next_retry_at=CASE WHEN $exhausted THEN NULL ELSE $now+(30*(1<<attempts)) END,
                error=$error,lease_until=NULL,lease_token=NULL
            WHERE id=$id AND state='running' AND lease_token=$token AND lease_until>$now
            """, new { id = fence.JobId, token = fence.LeaseToken, error, now, exhausted }, tx) == 1;
    }

    internal static int RequeueRetryableJobs(SqliteConnection c, SqliteTransaction tx, long now)
    {
        var ids = c.Query<long>("""
            SELECT id FROM ingest_jobs WHERE state='failed' AND attempts<5
                AND next_retry_at IS NOT NULL AND next_retry_at<=$now ORDER BY id
            """, new { now }, tx).ToArray();
        return ids.Count(id => RetryJob(c, tx, id, now));
    }

    internal static bool RetryJob(SqliteConnection c, SqliteTransaction tx, long id, long now)
    {
        var job = Job(c, tx, id);
        if (job is null || job.State != "failed" || job.Attempts >= 5 || job.NextRetryAt is not long due || due > now)
            return false;
        if (!ValidateQueuedTarget(c, tx, job)) return false;
        int changed = c.Execute("""
            UPDATE ingest_jobs SET state='queued' WHERE id=$id AND state='failed' AND attempts<5
                AND next_retry_at IS NOT NULL AND next_retry_at<=$now
            """, new { id, now }, tx);
        if (changed == 1) UpdateExtractStatus(c, tx, job, "pending", null);
        return changed == 1;
    }

    private static bool ValidateQueuedTarget(SqliteConnection c, SqliteTransaction tx, IngestJob job)
    {
        try
        {
            ValidateJobTarget(c, tx, job.Draft);
            if (job.Draft.Kind == "extract")
            {
                TryParseTarget(job.Draft.Target, out _, out long sourceId);
                if (!c.ExecuteScalar<bool>("""
                    SELECT EXISTS(SELECT 1 FROM sources WHERE id=$sourceId AND current_revision IS $revision
                        AND NOT EXISTS (SELECT 1 FROM ingest_jobs
                            WHERE kind='extract' AND target=$target AND id>$jobId AND attempts>0))
                    """, new { sourceId, revision = job.Draft.TargetRevision, target = job.Draft.Target, jobId = job.Id }, tx))
                    throw new StorageV19Exception("staleRevision");
            }
            return true;
        }
        catch (StorageV19Exception error) when (error.Code is "notFound" or "staleRevision" or "notebookMismatch" or "invalidValue")
        {
            c.Execute("""
                UPDATE ingest_jobs SET state='cancelled',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
                WHERE id=$id AND state IN ('queued','failed')
                """, new { id = job.Id }, tx);
            return false;
        }
    }

    internal static void PauseJob(SqliteConnection c, SqliteTransaction tx, long id)
    {
        var job = Job(c, tx, id) ?? throw new StorageV19Exception("notFound");
        if (job.State != "queued") throw new StorageV19Exception("invalidValue");
        c.Execute("UPDATE ingest_jobs SET state='paused' WHERE id=$id AND state='queued'", new { id }, tx);
    }

    internal static void ResumeJob(SqliteConnection c, SqliteTransaction tx, long id, long now)
    {
        var job = Job(c, tx, id) ?? throw new StorageV19Exception("notFound");
        if (job.State != "paused") throw new StorageV19Exception("invalidValue");
        c.Execute("UPDATE ingest_jobs SET state='queued' WHERE id=$id AND state='paused'", new { id }, tx);
    }

    internal static void CancelJob(SqliteConnection c, SqliteTransaction tx, long id)
    {
        var job = Job(c, tx, id) ?? throw new StorageV19Exception("notFound");
        if (job.State is not ("queued" or "running" or "paused")) throw new StorageV19Exception("invalidValue");
        c.Execute("""
            UPDATE ingest_jobs SET state='cancelled',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
            WHERE id=$id AND state IN ('queued','running','paused')
            """, new { id }, tx);
    }

    internal static bool CancelJob(SqliteConnection c, SqliteTransaction tx, JobFence fence, long now)
        => c.Execute("""
            UPDATE ingest_jobs SET state='cancelled',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
            WHERE id=$id AND state='running' AND lease_token=$token AND lease_until>$now
            """, new { id = fence.JobId, token = fence.LeaseToken, now }, tx) == 1;

    private static long LeaseDeadline(long now)
    {
        try { return checked(now + 300); }
        catch (OverflowException) { throw new StorageV19Exception("invalidValue"); }
    }

    private static void UpdateExtractStatus(SqliteConnection c, SqliteTransaction tx, IngestJob job, string status, string? error)
    {
        if (job.Draft.Kind != "extract") return;
        if (!TryParseTarget(job.Draft.Target, out string kind, out long sourceId) || kind != "source") return;
        c.Execute("""
            UPDATE sources SET status=$status,error=$error WHERE id=$sourceId AND current_revision IS $revision
            """, new { sourceId, revision = job.Draft.TargetRevision, status, error }, tx);
    }

    private static void UpdateOwnedExtractStatus(SqliteConnection c, SqliteTransaction tx, IngestJob job, string status, string? error)
    {
        if (job.Draft.Kind != "extract") return;
        if (!TryParseTarget(job.Draft.Target, out string kind, out long sourceId) || kind != "source") return;
        // A newer claimed job owns the source status even while it still targets the same revision.
        c.Execute("""
            UPDATE sources SET status=$status,error=$error WHERE id=$sourceId AND current_revision IS $revision
                AND NOT EXISTS (SELECT 1 FROM ingest_jobs
                    WHERE kind='extract' AND target=$target AND id>$jobId AND attempts>0)
            """, new { sourceId, revision = job.Draft.TargetRevision, target = job.Draft.Target, jobId = job.Id, status, error }, tx);
    }

    private static void ValidateJobTarget(SqliteConnection c, SqliteTransaction tx, IngestJobDraft draft)
    {
        string expected = draft.Kind switch
        {
            "scan" => "folder", "extract" => "source", "embed" or "gc" => "generation",
            _ => throw new StorageV19Exception("invalidValue")
        };
        if (!TryParseTarget(draft.Target, out string targetKind, out long targetId)
            || (targetKind != expected && !(draft.Kind == "embed" && targetKind == "notebook")))
            throw new StorageV19Exception("invalidValue");
        string sql = targetKind switch
        {
            "folder" => "SELECT notebook_id FROM folder_sources WHERE id=$targetId",
            "source" => "SELECT notebook_id FROM sources WHERE id=$targetId",
            "notebook" => "SELECT id FROM notebooks WHERE id=$targetId",
            _ => "SELECT notebook_id FROM index_generations WHERE id=$targetId"
        };
        long? notebook = c.QuerySingleOrDefault<long?>(sql, new { targetId }, tx);
        if (notebook is null) throw new StorageV19Exception("notFound");
        if (draft.TargetRevision is not long revisionId) return;
        var owner = c.QuerySingleOrDefault("""
            SELECT r.source_id,s.notebook_id FROM source_revisions r JOIN sources s ON s.id=r.source_id WHERE r.id=$revisionId
            """, new { revisionId }, tx);
        if (owner is null) throw new StorageV19Exception("notFound");
        if (targetKind == "source" && (long)owner.source_id != targetId) throw new StorageV19Exception("staleRevision");
        if ((long)owner.notebook_id != notebook.Value) throw new StorageV19Exception("notebookMismatch");
    }

    private static bool TryParseTarget(string target, out string kind, out long id)
    {
        kind = "";
        id = 0;
        if (string.IsNullOrEmpty(target)) return false;
        int separator = target.IndexOf(':');
        if (separator <= 0 || separator == target.Length - 1) return false;
        string number = target[(separator + 1)..];
        if (number[0] == '0' || number.Any(c => c is < '0' or > '9') ||
            !long.TryParse(number, NumberStyles.None, CultureInfo.InvariantCulture, out id) || id <= 0)
            return false;
        kind = target[..separator];
        return kind is "folder" or "source" or "generation" or "notebook";
    }

    private static IngestJob ReadJob(dynamic row) => new((long)row.id,
        new IngestJobDraft((string)row.kind, (string)row.target, (long?)row.target_revision, (string)row.options_json),
        checked((int)(long)row.attempts), (long?)row.next_retry_at, (string)row.state,
        (long?)row.lease_until, (string?)row.lease_token, (string?)row.error);
}

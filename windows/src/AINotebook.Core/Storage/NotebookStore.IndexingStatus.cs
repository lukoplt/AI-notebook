using System.Globalization;
using AINotebook.Core.Ingestion;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

/// <summary>Indexing status inputs (contract <c>indexing-status-v1</c> §1) and the "Retry now" store primitive.</summary>
public sealed partial class NotebookStore
{
    /// <summary>
    /// Embeddable chunks (<c>embedding-plan-v1</c> §3) of the generation's non-excluded manifest revisions, and how many
    /// already have a vector there. Read every second while indexing runs: chunks are reached only through the covering
    /// idx_chunks_revision_ord (a revision's chunks always belong to the manifest source, so no chunk row has to be read
    /// to check source_id; the spreadsheet cap compares ord, which the index carries).
    /// </summary>
    internal const string ChunkProgressSql = $"""
        SELECT count(*) AS total, coalesce(sum(EXISTS(SELECT 1 FROM chunk_embeddings e
            WHERE e.chunk_id=c.id AND e.generation_id=m.generation_id)),0) AS done
        FROM index_generation_manifest m JOIN sources s ON s.id=m.source_id
        JOIN source_chunks c ON c.revision_id=m.revision_id
        WHERE m.generation_id=$generationId AND m.state<>'excluded' AND {EmbeddingPlan.EmbeddableSql}
        """;

    /// <summary>
    /// One read batch of the notebook's indexing inputs. <paramref name="availability"/> and
    /// <paramref name="runtimeError"/> are runtime facts supplied by the caller.
    /// </summary>
    public IndexingInputs IndexingInputs(long notebookId, long now, EmbeddingAvailability availability = EmbeddingAvailability.Ready,
        string? runtimeError = null)
    {
        lock (_gate)
        {
            RequireNotebookV19(notebookId);
            var folders = _conn.Query("""
                SELECT id,scan_state,last_scan_error,scan_generation FROM folder_sources WHERE notebook_id=$notebookId ORDER BY id
                """, new { notebookId }).Select(row =>
            {
                long id = (long)row.id;
                string state = (string)row.scan_state;
                int? seen = state == "scanning"
                    ? _conn.ExecuteScalar<int>("SELECT count(*) FROM scan_items WHERE folder_id=$id AND seen_generation=$generation",
                        new { id, generation = (long)row.scan_generation })
                    : null;
                return new IndexingFolderInput(id, state, (string?)row.last_scan_error, seen);
            }).ToArray();
            int scans = _conn.ExecuteScalar<int>("""
                SELECT count(*) FROM ingest_jobs WHERE kind='scan' AND state IN ('queued','running')
                  AND target IN (SELECT 'folder:'||id FROM folder_sources WHERE notebook_id=$notebookId)
                """, new { notebookId });
            var extract = _conn.Query("""
                SELECT state,count(*) AS n FROM ingest_jobs WHERE kind='extract' AND state IN ('queued','running')
                  AND target IN (SELECT 'source:'||id FROM sources WHERE notebook_id=$notebookId) GROUP BY state
                """, new { notebookId }).ToDictionary(row => (string)row.state, row => (int)(long)row.n, StringComparer.Ordinal);
            var sources = _conn.Query("""
                SELECT status,count(*) AS n FROM sources WHERE notebook_id=$notebookId AND availability='present' AND eligible=1 GROUP BY status
                """, new { notebookId }).ToDictionary(row => (string)row.status, row => (int)(long)row.n, StringComparer.Ordinal);
            // Addendum §8: a running/unfinished job wins; a bootstrap of a building space reports that build.
            var selected = StatusEmbedJobLocked(notebookId, null);
            int done = 0, total = 0;
            IndexingEmbedJobInput? embedJob = null;
            if (selected is not null)
            {
                if (selected.ProgressGenerationId is long generationId)
                {
                    var progress = _conn.QuerySingle(ChunkProgressSql, new { generationId });
                    total = (int)(long)progress.total;
                    done = (int)(long)progress.done;
                }
                embedJob = new IndexingEmbedJobInput(selected.Job.State, selected.Job.Attempts, selected.Job.NextRetryAt,
                    selected.Job.Error, selected.Bootstrap);
            }
            return new IndexingInputs
            {
                Now = now,
                RuntimeError = runtimeError,
                EmbeddingAvailability = availability,
                Folders = folders,
                ScanJobsPending = scans,
                ExtractQueued = extract.GetValueOrDefault("queued"),
                ExtractRunning = extract.GetValueOrDefault("running"),
                SourcesTotal = sources.Values.Sum(),
                SourcesReady = sources.GetValueOrDefault("ready"),
                SourcesError = sources.GetValueOrDefault("error"),
                NeedsEmbedding = NotebookNeedsEmbeddingLocked(notebookId, null),
                EmbedJob = embedJob,
                EmbedChunksDone = done,
                EmbedChunksTotal = total
            };
        }
    }

    /// <summary>Reads the inputs and derives the notebook's status (pure function, contract §2).</summary>
    public IndexingStatus IndexingStatus(long notebookId, long now, EmbeddingAvailability availability = EmbeddingAvailability.Ready,
        string? runtimeError = null) =>
        IndexingStatusDerivation.Derive(IndexingInputs(notebookId, now, availability, runtimeError));

    /// <summary>
    /// True when an eligible present source has a published revision with chunks that is not <c>done</c> in the active
    /// generation (independent of the selected embedding space).
    /// </summary>
    public bool NotebookNeedsEmbedding(long notebookId)
    {
        lock (_gate) return NotebookNeedsEmbeddingLocked(notebookId, null);
    }

    /// <summary>An embed/bootstrap job of the notebook is queued, running, paused, or failed with a retry pending.</summary>
    public bool HasUnfinishedEmbedJob(long notebookId)
    {
        lock (_gate)
            return _conn.ExecuteScalar<bool>($"""
                SELECT EXISTS(SELECT 1 FROM ingest_jobs WHERE kind='embed' AND {EmbedJobsOf}
                  AND (state IN ('queued','running','paused') OR (state='failed' AND attempts<5 AND next_retry_at IS NOT NULL)))
                """, new { notebookId, target = IndexingNotebookTarget(notebookId) });
    }

    /// <summary>"Retry now": the notebook's embed job waiting for its retry deadline becomes due. False when none waited.</summary>
    public bool ExpediteEmbedRetry(long notebookId, long now)
    {
        int changed;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var args = new { notebookId, target = IndexingNotebookTarget(notebookId), now };
            changed = _conn.Execute($"""
                UPDATE ingest_jobs SET state='queued',next_retry_at=NULL
                WHERE kind='embed' AND {EmbedJobsOf} AND state='failed' AND attempts<5 AND next_retry_at IS NOT NULL
                """, args, tx);
            changed += _conn.Execute($"""
                UPDATE ingest_jobs SET next_retry_at=NULL
                WHERE kind='embed' AND {EmbedJobsOf} AND state='queued' AND next_retry_at IS NOT NULL AND next_retry_at>$now
                """, args, tx);
            tx.Commit();
        }
        if (changed > 0) NotifyFolderIngestionChanged(notebookId);
        return changed > 0;
    }

    /// <summary>Highest job id so far (0 when none): the baseline of a scan outcome.</summary>
    internal long MaxIngestJobId()
    {
        lock (_gate) return _conn.ExecuteScalar<long?>("SELECT max(id) FROM ingest_jobs") ?? 0;
    }

    /// <summary>
    /// The folder's last scan: extract jobs queued for its sources after <paramref name="sinceJobId"/> and eligible files
    /// seen in its current scan generation. Null when the folder is gone.
    /// </summary>
    internal FolderScanOutcome? FolderScanOutcome(long folderId, long sinceJobId, long now)
    {
        lock (_gate)
        {
            long? generation = _conn.QuerySingleOrDefault<long?>("SELECT scan_generation FROM folder_sources WHERE id=$folderId",
                new { folderId });
            if (generation is null) return null;
            int changed = _conn.ExecuteScalar<int>("""
                SELECT count(DISTINCT target) FROM ingest_jobs WHERE kind='extract' AND id>$sinceJobId
                  AND target IN (SELECT 'source:'||id FROM sources WHERE folder_id=$folderId)
                """, new { sinceJobId, folderId });
            int seen = _conn.ExecuteScalar<int>("""
                SELECT count(*) FROM scan_items WHERE folder_id=$folderId AND seen_generation=$generation AND kind='eligible'
                """, new { folderId, generation });
            return new FolderScanOutcome(folderId, changed, seen, now);
        }
    }

    /// <summary>
    /// The embed job behind the status and its progress generation (<c>indexing-status-v1</c> §8). Reads only the
    /// unfinished jobs plus the newest one: the selection is the same.
    /// </summary>
    internal StatusEmbedJob? StatusEmbedJobLocked(long notebookId, SqliteTransaction? tx)
    {
        var jobs = _conn.Query($"""
            SELECT id,target,state,attempts,next_retry_at,error,options_json FROM ingest_jobs WHERE kind='embed' AND {EmbedJobsOf}
              AND (state IN ('queued','running','paused') OR (state='failed' AND attempts<5 AND next_retry_at IS NOT NULL)
                OR id=(SELECT max(id) FROM ingest_jobs WHERE kind='embed' AND {EmbedJobsOf}))
            ORDER BY id
            """, new { notebookId, target = IndexingNotebookTarget(notebookId) }, tx).Select(EmbedJobSnapshotOf).ToArray();
        return jobs.Length == 0 ? null : EmbedJobPlanning.StatusJob(jobs, GenerationSnapshots(_conn, tx, notebookId));
    }

    internal static EmbedJobSnapshot EmbedJobSnapshotOf(dynamic row) => new((long)row.id, (string)row.target, (string)row.state,
        (int)(long)row.attempts, (long?)row.next_retry_at, (string?)row.error, EmbedJobOptions.Parse((string)row.options_json));

    /// <summary>The notebook's building and active generations.</summary>
    internal static IReadOnlyList<GenerationSnapshot> GenerationSnapshots(SqliteConnection c, SqliteTransaction? tx, long notebookId) =>
        c.Query<long>("SELECT id FROM index_generations WHERE notebook_id=$notebookId AND state IN ('building','active') ORDER BY id",
                new { notebookId }, tx)
            .Select(id => GenerationSQL.Read(c, tx, id)!).Select(g => new GenerationSnapshot(g.Id, g.State, g.Identity)).ToArray();

    /// <summary>Embed jobs of the notebook: its bootstrap target or any of its generations (params <c>$notebookId</c>, <c>$target</c>).</summary>
    private const string EmbedJobsOf =
        "(target=$target OR target IN (SELECT 'generation:'||id FROM index_generations WHERE notebook_id=$notebookId))";

    private static string IndexingNotebookTarget(long notebookId) => "notebook:" + notebookId.ToString(CultureInfo.InvariantCulture);

    internal bool NotebookNeedsEmbeddingLocked(long notebookId, SqliteTransaction? tx) =>
        _conn.ExecuteScalar<bool>("""
            SELECT EXISTS(SELECT 1 FROM sources s WHERE s.notebook_id=$notebookId AND s.availability='present' AND s.eligible=1
                AND s.published_revision_id IS NOT NULL
                AND EXISTS(SELECT 1 FROM source_chunks c WHERE c.revision_id=s.published_revision_id)
                AND NOT EXISTS(SELECT 1 FROM index_generations g JOIN index_generation_manifest m ON m.generation_id=g.id
                    WHERE g.notebook_id=s.notebook_id AND g.state='active' AND m.source_id=s.id
                      AND m.revision_id=s.published_revision_id AND m.state='done'))
            """, new { notebookId }, tx);
}

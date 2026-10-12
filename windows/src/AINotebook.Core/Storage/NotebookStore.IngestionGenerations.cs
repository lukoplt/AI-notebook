using System.Globalization;
using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

/// <summary>
/// Durable index progress for one notebook; <c>PausedForChat</c> is overlaid by the coordinator. <c>Copied</c> counts
/// vectors this build copied from an identical chunk text instead of a provider call (<c>embedding-plan-v1</c> §6).
/// </summary>
public sealed record GenerationProgress(long? GenerationId, int Done, int Total, int Excluded, bool Failed, bool PausedForChat,
    bool HasActive, long? JobId, bool Preparing, string? ErrorCode, int Copied = 0);

/// <summary>
/// One build round (<c>embedding-plan-v1</c> §5): unique provider inputs, same-text chunks joining an input, the
/// vectors copied without a provider call, the keyset cursor after the walk, and whether settling reset the cursor.
/// </summary>
public sealed record EmbeddingRound(IReadOnlyList<FolderEmbeddingItem> Items, IReadOnlyList<EmbeddingDuplicate> Joined,
    int Copied, EmbeddingCursor? Cursor, bool Reset);

/// <summary>One chunk of an embedding batch, pinned to the explicit revision it was read from.</summary>
public sealed record FolderEmbeddingItem(long ChunkId, long RevisionId, long SourceId, string Text);

/// <summary>
/// Generation orchestration over WP3 kernels (WP6 Task 15). Every typed mutation validates the live embed
/// fence inside one immediate transaction; an old active generation is never touched by a building one.
/// </summary>
public sealed partial class NotebookStore
{
    /// <summary>Explicit re-index with verified dimensions: a fresh building generation (no copy) plus one job.</summary>
    public long RequestReindex(long notebookId, GenerationIdentity identity, long now)
    {
        ArgumentNullException.ThrowIfNull(identity);
        var selection = new EmbeddingSelection(identity.ProviderId, identity.EndpointRevision, identity.Model, identity.ModelDigest,
            identity.Dims, identity.Normalization, identity.QueryFormatVersion, identity.DocFormatVersion, identity.ChunkerVersion);
        long generationId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            RequireNotebookV19(notebookId, tx);
            long jobId = IngestionGenerationSQL.QueueEmbedding(_conn, tx, notebookId, selection, copyExisting: false, now);
            generationId = TargetId(RevisionJobSQL.Job(_conn, tx, jobId)!.Draft.Target);
            tx.Commit();
        }
        NotifyFolderIngestionChanged(notebookId);
        return generationId;
    }

    /// <summary>
    /// Persists a captured selection as durable embed work and returns the job ID. Known dimensions build a
    /// generation (copying identical unchanged vectors when <paramref name="copyExisting"/>); unknown dimensions
    /// queue one notebook-target bootstrap job that embeds the first real corpus batch.
    /// </summary>
    public long RequestEmbeddingBuild(long notebookId, EmbeddingSelection selection, bool copyExisting, long now)
    {
        ArgumentNullException.ThrowIfNull(selection);
        long jobId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            RequireNotebookV19(notebookId, tx);
            jobId = IngestionGenerationSQL.QueueEmbedding(_conn, tx, notebookId, selection, copyExisting, now);
            tx.Commit();
        }
        NotifyFolderIngestionChanged(notebookId);
        return jobId;
    }

    /// <summary>
    /// Next pending embeddable chunks of a building generation in build order (<c>embedding-plan-v1</c> §4): published,
    /// eligible, present and without a vector; no side effects.
    /// </summary>
    public IReadOnlyList<FolderEmbeddingItem> NextEmbeddingBatch(long generationId, int size)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(size, 1);
        lock (_gate)
        {
            var items = new List<FolderEmbeddingItem>();
            for (int priorityClass = 0; priorityClass <= 1 && items.Count < size; priorityClass++)
                items.AddRange(Candidates(null, generationId, priorityClass, null, size - items.Count).Select(c => c.Item));
            return items;
        }
    }

    /// <summary>First real corpus embeddable chunks in build order for a dimension bootstrap (never a probe string).</summary>
    public IReadOnlyList<FolderEmbeddingItem> NextBootstrapBatch(long notebookId, int size)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(size, 1);
        lock (_gate)
        {
            var items = new List<FolderEmbeddingItem>();
            for (int priorityClass = 0; priorityClass <= 1 && items.Count < size; priorityClass++)
                items.AddRange(_conn.Query($"""
                    SELECT c.id,c.revision_id,c.source_id,c.text FROM sources s
                    JOIN source_chunks c ON c.revision_id=s.published_revision_id
                    WHERE s.notebook_id=$notebookId AND s.availability='present' AND s.eligible=1
                      AND {EmbeddingPlan.ClassSql}=$priorityClass AND {EmbeddingPlan.EmbeddableSql}
                    ORDER BY s.id,c.ord LIMIT $limit
                    """, new { notebookId, priorityClass, limit = size - items.Count }).Select(Item));
            return items;
        }
    }

    /// <summary>
    /// One fenced build round (<c>embedding-plan-v1</c> §5): reconciles the generation (a changed manifest resets the
    /// cursor), then walks pending candidates after <paramref name="cursor"/> in build order, copying vectors of texts
    /// the generation already embedded and collecting at most <paramref name="size"/> unique provider inputs. Null when
    /// the fence is lost or the generation is no longer building.
    /// </summary>
    public EmbeddingRound? CaptureEmbeddingRound(long generationId, int size, EmbeddingCursor? cursor, JobFence fence, long now)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(size, 1);
        ArgumentNullException.ThrowIfNull(fence);
        EmbeddingRound round;
        long notebookId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            if (!OwnsEmbed(tx, fence, now, out var job) || job!.Draft.Target != GenerationTarget(generationId)) return null;
            var generation = GenerationSQL.Read(_conn, tx, generationId);
            if (generation is not { State: "building" }) return null;
            notebookId = generation.NotebookId;
            long before = _conn.ExecuteScalar<long>("SELECT total_changes()", transaction: tx);
            GenerationSQL.Reconcile(_conn, tx, generationId);
            bool reset = _conn.ExecuteScalar<long>("SELECT total_changes()", transaction: tx) != before;
            IngestionGenerationSQL.MarkCompleteManifest(_conn, tx, generationId);
            var position = reset ? null : cursor;
            var items = new List<FolderEmbeddingItem>();
            var inputs = new Dictionary<string, int>(StringComparer.Ordinal);
            var joined = new List<EmbeddingDuplicate>();
            int copied = 0, scanned = 0, scanLimit = EmbeddingPlan.RoundScanFactor * size;
            bool stop = false;
            for (int priorityClass = 0; priorityClass <= 1 && !stop; priorityClass++)
            {
                if (position is not null && position.PriorityClass > priorityClass) continue;
                var after = position?.PriorityClass == priorityClass ? position : null;
                while (!stop && scanned < scanLimit)
                {
                    var page = Candidates(tx, generationId, priorityClass, after, size);
                    if (page.Count == 0) break;
                    foreach (var candidate in page)
                    {
                        string text = candidate.Item.Text;
                        if (CopyExistingVector(tx, generationId, candidate.Item.ChunkId, text)) copied++;
                        else if (inputs.TryGetValue(text, out int index))
                            joined.Add(new EmbeddingDuplicate(candidate.Item.ChunkId, candidate.Item.RevisionId, items[index].ChunkId));
                        else if (items.Count < size)
                        {
                            inputs[text] = items.Count;
                            items.Add(candidate.Item);
                        }
                        else { stop = true; break; }
                        position = after = candidate.Cursor;
                        if (++scanned >= scanLimit) { stop = true; break; }
                    }
                }
            }
            if (copied > 0) IngestionGenerationSQL.MarkCompleteManifest(_conn, tx, generationId);
            tx.Commit();
            round = new EmbeddingRound(items, joined, copied, position, reset);
        }
        if (round.Copied > 0) NotifyIndexingProgress(notebookId);
        return round;
    }

    internal const string CandidatesSql = $"""
        SELECT c.id,c.revision_id,c.source_id,c.ord,c.text FROM index_generation_manifest m
        JOIN sources s ON s.id=m.source_id
        JOIN source_chunks c ON c.revision_id=m.revision_id AND c.source_id=m.source_id
        WHERE m.generation_id=$generationId AND m.source_id>=$afterSource AND m.state='pending' AND s.availability='present'
          AND s.eligible=1 AND s.published_revision_id=m.revision_id AND {EmbeddingPlan.ClassSql}=$priorityClass
          AND (m.source_id>$afterSource OR c.ord>$afterOrd) AND {EmbeddingPlan.EmbeddableSql}
          AND NOT EXISTS(SELECT 1 FROM chunk_embeddings e WHERE e.chunk_id=c.id AND e.generation_id=m.generation_id)
        ORDER BY m.source_id,c.ord LIMIT $limit
        """;

    /// <summary>
    /// Pending embeddable chunks of one priority class strictly after <paramref name="after"/>, in (source, ord)
    /// order. Keyset on the manifest primary key: finished sources before the cursor are never read again.
    /// </summary>
    private List<(FolderEmbeddingItem Item, EmbeddingCursor Cursor)> Candidates(SqliteTransaction? tx, long generationId,
        int priorityClass, EmbeddingCursor? after, int limit) =>
        _conn.Query(CandidatesSql, new { generationId, afterSource = after?.SourceId ?? 0, priorityClass, afterOrd = after?.Ord ?? -1, limit }, tx)
            .Select(row => (Item((object)row), new EmbeddingCursor(priorityClass, (long)row.source_id, (long)row.ord))).ToList();

    /// <summary>Ledger lookup by hash, verified by exact text and an existing vector.</summary>
    internal const string ExistingVectorSql = """
        SELECT d.chunk_id FROM generation_text_hashes d
        JOIN chunk_embeddings e ON e.chunk_id=d.chunk_id AND e.generation_id=d.generation_id
        JOIN source_chunks c ON c.id=d.chunk_id
        WHERE d.generation_id=$generationId AND d.text_hash=$hash AND c.text=$text LIMIT 1
        """;

    /// <summary>Dedup rule 1: the exact text already has a vector in the generation → copy it now.</summary>
    private bool CopyExistingVector(SqliteTransaction tx, long generationId, long chunkId, string text)
    {
        long? from = _conn.QuerySingleOrDefault<long?>(ExistingVectorSql,
            new { generationId, hash = EmbeddingPlan.TextHash(text), text }, tx);
        return from is long source && CopyVector(tx, generationId, source, chunkId, text);
    }

    /// <summary>Byte-for-byte copy of an existing vector of the generation; false when <paramref name="from"/> has none.</summary>
    private bool CopyVector(SqliteTransaction tx, long generationId, long from, long to, string text)
    {
        if (_conn.Execute("""
            INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding)
            SELECT $to,generation_id,embedding FROM chunk_embeddings WHERE chunk_id=$from AND generation_id=$generationId
            ON CONFLICT(chunk_id,generation_id) DO NOTHING
            """, new { generationId, from, to }, tx) != 1) return false;
        RecordHash(tx, generationId, to, text, copied: true);
        return true;
    }

    private void RecordHash(SqliteTransaction tx, long generationId, long chunkId, string text, bool copied) =>
        _conn.Execute("""
            INSERT OR REPLACE INTO generation_text_hashes(generation_id,chunk_id,text_hash,copied) VALUES($generationId,$chunkId,$hash,$copied)
            """, new { generationId, chunkId, hash = EmbeddingPlan.TextHash(text), copied = copied ? 1 : 0 }, tx);

    /// <summary>Stores a fresh member's vector and its dedup ledger row (<c>copied = 0</c>).</summary>
    private void StoreMember(SqliteTransaction tx, IndexGeneration generation, long chunkId, float[] vector)
    {
        GenerationSQL.StoreEmbedding(_conn, tx, generation, chunkId, new EmbeddingVector(vector));
        string? text = _conn.QuerySingleOrDefault<string?>("SELECT text FROM source_chunks WHERE id=$chunkId", new { chunkId }, tx);
        if (text is not null) RecordHash(tx, generation.Id, chunkId, text, copied: false);
    }

    /// <summary>Joined same-text chunks copy the committed input's vector bytes; stale members are skipped.</summary>
    private void StoreDuplicates(SqliteTransaction tx, long generationId, IReadOnlyList<EmbeddingDuplicate>? duplicates)
    {
        foreach (var duplicate in duplicates ?? [])
        {
            if (!FreshMember(tx, duplicate.ChunkId, duplicate.RevisionId, generationId)) continue;
            string? text = _conn.QuerySingleOrDefault<string?>("SELECT text FROM source_chunks WHERE id=$id", new { id = duplicate.ChunkId }, tx);
            string? original = _conn.QuerySingleOrDefault<string?>("SELECT text FROM source_chunks WHERE id=$id", new { id = duplicate.OfChunkId }, tx);
            if (text is null || !string.Equals(text, original, StringComparison.Ordinal)) continue;
            CopyVector(tx, generationId, duplicate.OfChunkId, duplicate.ChunkId, text);
        }
    }

    /// <summary>
    /// Stores one fenced batch. Stale members (revision no longer the published, manifest revision of an eligible
    /// present source) are discarded and the manifest reconciled; no vector attaches to a different revision.
    /// </summary>
    public bool CommitEmbeddingBatch(long generationId, IReadOnlyList<long> chunkIds, IReadOnlyList<long> revisionIds,
        IReadOnlyList<float[]> vectors, JobFence fence, long now, IReadOnlyList<EmbeddingDuplicate>? duplicates = null)
    {
        RequireBatchShape(chunkIds, revisionIds, vectors);
        long notebookId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            if (!OwnsEmbed(tx, fence, now, out var job) || job!.Draft.Target != GenerationTarget(generationId)) return false;
            var generation = GenerationSQL.Read(_conn, tx, generationId);
            if (generation is not { State: "building" }) return false;
            notebookId = generation.NotebookId;
            if (vectors.Any(v => v.Length != generation.Identity.Dims)) throw new StorageV19Exception("invalidVector");
            for (int i = 0; i < chunkIds.Count; i++)
                if (FreshMember(tx, chunkIds[i], revisionIds[i], generationId))
                    StoreMember(tx, generation, chunkIds[i], vectors[i]);
            StoreDuplicates(tx, generationId, duplicates);
            GenerationSQL.Reconcile(_conn, tx, generationId);
            IngestionGenerationSQL.MarkCompleteManifest(_conn, tx, generationId);
            tx.Commit();
        }
        NotifyIndexingProgress(notebookId);
        return true;
    }

    /// <summary>
    /// Bootstrap commit: derives the identity from the returned dimensions, creates/reuses a compatible building
    /// generation, stores the fresh members and retargets the same running job to it. Null when fenced out, the
    /// selection no longer matches the job, or every captured member became stale (the job keeps running).
    /// </summary>
    public long? CommitBootstrapBatch(long notebookId, EmbeddingSelection selection, int dims, IReadOnlyList<long> chunkIds,
        IReadOnlyList<long> revisionIds, IReadOnlyList<float[]> vectors, bool copyExisting, JobFence fence, long now,
        IReadOnlyList<EmbeddingDuplicate>? duplicates = null)
    {
        ArgumentNullException.ThrowIfNull(selection);
        RequireBatchShape(chunkIds, revisionIds, vectors);
        if (dims <= 0 || vectors.Any(v => v.Length != dims)) throw new StorageV19Exception("invalidVector");
        long generationId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            if (!OwnsEmbed(tx, fence, now, out var job) || job!.Draft.Target != NotebookTarget(notebookId)) return null;
            var options = IngestionGenerationSQL.ReadOptions(job.Draft.OptionsJson);
            if (options is null || !IngestionGenerationSQL.SameSpace(options.Selection, selection) ||
                selection.Dims is int known && known != dims)
                return null;
            var fresh = Enumerable.Range(0, chunkIds.Count).Where(i => FreshMember(tx, chunkIds[i], revisionIds[i], null)).ToArray();
            if (fresh.Length == 0) return null;
            var identity = IngestionGenerationSQL.Identity(selection, dims);
            var generation = IngestionGenerationSQL.EnsureBuilding(_conn, tx, notebookId, identity, copyExisting, now);
            generationId = generation.Id;
            foreach (int i in fresh)
                StoreMember(tx, generation, chunkIds[i], vectors[i]);
            StoreDuplicates(tx, generationId, duplicates);
            IngestionGenerationSQL.MarkCompleteManifest(_conn, tx, generationId);
            if (!RevisionJobSQL.RetargetEmbedJob(_conn, tx, fence, GenerationTarget(generationId), now))
                throw new StorageV19Exception("staleLease");
            tx.Commit();
        }
        NotifyFolderIngestionChanged(notebookId);
        return generationId;
    }

    /// <summary>
    /// Reconciles, then activates atomically with job completion when every eligible source is covered and the
    /// selected identity is unchanged. False (activation deferred) when new pending work appeared.
    /// </summary>
    public bool ActivateBuiltGeneration(long id, GenerationIdentity selectedIdentity, JobFence fence, long now)
    {
        ArgumentNullException.ThrowIfNull(selectedIdentity);
        long notebookId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            if (!OwnsEmbed(tx, fence, now, out var job) || job!.Draft.Target != GenerationTarget(id)) return false;
            var generation = GenerationSQL.Read(_conn, tx, id);
            if (generation is not { State: "building" } || generation.Identity != selectedIdentity) return false;
            notebookId = generation.NotebookId;
            GenerationSQL.Reconcile(_conn, tx, id);
            IngestionGenerationSQL.MarkCompleteManifest(_conn, tx, id);
            if (GenerationSQL.ReadManifest(_conn, tx, id).Any(entry => entry.State == "pending"))
            {
                tx.Commit(); // New pending work continues the same job; the active generation stays.
                return false;
            }
            GenerationSQL.Activate(_conn, tx, id, fence, now);
            tx.Commit();
        }
        NotifyFolderIngestionChanged(notebookId);
        return true;
    }

    /// <summary>Cancels a building generation's work and retires it; the active generation and pins survive.</summary>
    public void DiscardBuildingGeneration(long id, long now)
    {
        long notebookId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var generation = GenerationSQL.Read(_conn, tx, id) ?? throw new StorageV19Exception("notFound");
            if (generation.State != "building") throw new StorageV19Exception("generationNotReady");
            notebookId = generation.NotebookId;
            IngestionGenerationSQL.CancelEmbedJobs(_conn, tx, GenerationTarget(id), null);
            _conn.Execute("UPDATE index_generations SET state='retired' WHERE id=$id AND state='building'", new { id }, tx);
            tx.Commit();
        }
        NotifyFolderIngestionChanged(notebookId);
    }

    /// <summary>Discards an embed job of this notebook: a bootstrap is cancelled, a build delegates to generation discard.</summary>
    public void DiscardEmbeddingJob(long notebookId, long jobId, long now)
    {
        var job = Job(jobId) ?? throw new StorageV19Exception("notFound");
        if (job.Draft.Kind != "embed") throw new StorageV19Exception("invalidValue");
        if (job.Draft.Target == NotebookTarget(notebookId))
        {
            lock (_gate)
            {
                using var tx = _conn.BeginTransaction(deferred: false);
                IngestionGenerationSQL.CancelEmbedJobs(_conn, tx, job.Draft.Target, jobId);
                tx.Commit();
            }
            NotifyFolderIngestionChanged(notebookId);
            return;
        }
        long generationId = TargetId(job.Draft.Target);
        if (Generation(generationId)?.NotebookId != notebookId) throw new StorageV19Exception("notebookMismatch");
        DiscardBuildingGeneration(generationId, now);
    }

    /// <summary>
    /// The selection changed under a running embed job: cancel it (embeddingSelectionChanged) and fail its building
    /// generation, atomically. A stale owner or a non-building generation changes nothing.
    /// </summary>
    public bool InvalidateEmbeddingSelection(JobFence fence, long now)
    {
        long notebookId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            if (!OwnsEmbed(tx, fence, now, out var job)) return false;
            string target = job!.Draft.Target;
            if (target.StartsWith("generation:", StringComparison.Ordinal))
            {
                var generation = GenerationSQL.Read(_conn, tx, TargetId(target));
                if (generation is not { State: "building" }) return false;
                notebookId = generation.NotebookId;
                _conn.Execute("UPDATE index_generations SET state='failed' WHERE id=$id AND state='building'", new { id = generation.Id }, tx);
            }
            else notebookId = TargetId(target);
            _conn.Execute("""
                UPDATE ingest_jobs SET state='cancelled',error='embeddingSelectionChanged',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
                WHERE id=$id AND state='running' AND lease_token=$token AND lease_until>$now
                """, new { id = fence.JobId, token = fence.LeaseToken, now }, tx);
            tx.Commit();
        }
        NotifyFolderIngestionChanged(notebookId);
        return true;
    }

    /// <summary>Fenced embed failure; the terminal fifth attempt fails its building generation in the same transaction.</summary>
    public bool FailEmbeddingJob(JobFence fence, string error, long now)
    {
        long? notebookId = null;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            if (!OwnsEmbed(tx, fence, now, out var job)) return false;
            if (!RevisionJobSQL.FailJob(_conn, tx, fence, error, now)) return false;
            string target = job!.Draft.Target;
            if (target.StartsWith("generation:", StringComparison.Ordinal))
            {
                var generation = GenerationSQL.Read(_conn, tx, TargetId(target));
                notebookId = generation?.NotebookId;
                if (job.Attempts >= 5 && generation is { State: "building" })
                    _conn.Execute("UPDATE index_generations SET state='failed' WHERE id=$id", new { id = generation.Id }, tx);
            }
            else notebookId = TargetId(target);
            tx.Commit();
        }
        if (notebookId is long notebook) NotifyFolderIngestionChanged(notebook);
        return true;
    }

    /// <summary>Durable progress: the newest build (or bootstrap) for the notebook, readable before a generation exists.</summary>
    public GenerationProgress GenerationProgress(long notebookId)
    {
        lock (_gate)
        {
            RequireNotebookV19(notebookId);
            bool hasActive = _conn.ExecuteScalar<bool>(
                "SELECT EXISTS(SELECT 1 FROM index_generations WHERE notebook_id=$notebookId AND state='active')", new { notebookId });
            // The newest non-retired generation decides: once a newer build activates, an older failure is history.
            var newest = _conn.QuerySingleOrDefault("""
                SELECT id,state FROM index_generations WHERE notebook_id=$notebookId AND state IN ('building','failed','active')
                ORDER BY id DESC LIMIT 1
                """, new { notebookId });
            long? latest = newest is not null && (string)newest.state != "active" ? (long)newest.id : null;
            var bootstrap = _conn.QuerySingleOrDefault("""
                SELECT id,state,error FROM ingest_jobs WHERE kind='embed' AND target=$target ORDER BY id DESC LIMIT 1
                """, new { target = NotebookTarget(notebookId) });
            // The same job as the indexing status (indexing-status-v1 §8): a bootstrap prepares only while it is the
            // selected unfinished job and no generation of its space is building.
            var selected = StatusEmbedJobLocked(notebookId, null);
            bool preparing = selected is { Bootstrap: true, Job.State: "queued" or "running" or "paused" };
            if (preparing)
                return new GenerationProgress(null, 0, 0, 0, false, false, hasActive, selected!.Job.Id, true, null);
            if (latest is not long generationId)
            {
                if (bootstrap is null) return new GenerationProgress(null, 0, 0, 0, false, false, hasActive, null, false, null);
                return new GenerationProgress(null, 0, 0, 0, (string)bootstrap.state == "failed", false, hasActive,
                    (long)bootstrap.id, false, (string?)bootstrap.error);
            }
            var manifest = GenerationSQL.ReadManifest(_conn, null, generationId);
            var generation = GenerationSQL.Read(_conn, null, generationId)!;
            var job = _conn.QuerySingleOrDefault("""
                SELECT id,state,error FROM ingest_jobs WHERE kind='embed' AND target=$target ORDER BY id DESC LIMIT 1
                """, new { target = GenerationTarget(generationId) });
            int copied = _conn.ExecuteScalar<int>("""
                SELECT count(*) FROM generation_text_hashes d WHERE d.generation_id=$generationId AND d.copied=1
                  AND EXISTS(SELECT 1 FROM chunk_embeddings e WHERE e.chunk_id=d.chunk_id AND e.generation_id=d.generation_id)
                """, new { generationId });
            return new GenerationProgress(generationId, manifest.Count(e => e.State == "done"), manifest.Count,
                manifest.Count(e => e.State == "excluded"), generation.State == "failed" || job is not null && (string)job.state == "failed",
                false, hasActive, (long?)job?.id, false, (string?)job?.error, copied);
        }
    }

    /// <summary>Queues a durable scan; a queued normal scan is upgraded to verify-all before its claim.</summary>
    public long RequestFolderScan(long folderId, bool verifyAll, long now)
    {
        long notebookId;
        long id;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            notebookId = RequireFolderNotebook(folderId, tx);
            string target = FolderTarget(folderId);
            long? queued = _conn.QuerySingleOrDefault<long?>(
                "SELECT id FROM ingest_jobs WHERE kind='scan' AND target=$target AND state='queued' ORDER BY id LIMIT 1", new { target }, tx);
            if (queued is long existing)
            {
                if (verifyAll) RevisionJobSQL.CoalesceQueuedJobOptions(_conn, tx, existing, """{"verifyAll":true}""");
                tx.Commit();
                return existing;
            }
            // A running scan gets exactly one queued successor carrying the requested mode.
            id = RevisionJobSQL.EnqueueJob(_conn, tx, new IngestJobDraft("scan", target, null,
                verifyAll ? """{"verifyAll":true}""" : """{"verifyAll":false}"""), now);
            _conn.Execute("UPDATE ingest_jobs SET next_retry_at=NULL WHERE id=$id", new { id }, tx);
            tx.Commit();
        }
        NotifyFolderIngestionChanged(notebookId);
        return id;
    }

    /// <summary>The persisted verify-all mode of a scan job (immutable once claimed).</summary>
    public bool ScanOptions(long jobId)
    {
        var job = Job(jobId) ?? throw new StorageV19Exception("notFound");
        if (job.Draft.Kind != "scan") throw new StorageV19Exception("invalidValue");
        using var options = JsonDocument.Parse(job.Draft.OptionsJson);
        return options.RootElement.TryGetProperty("verifyAll", out var value) && value.ValueKind == JsonValueKind.True;
    }

    /// <summary>All watch-enabled folders across every notebook.</summary>
    public IReadOnlyList<FolderSource> WatchedFolders()
    {
        lock (_gate)
            return _conn.Query("SELECT * FROM folder_sources WHERE watch_enabled=1 ORDER BY id").Select(row => (FolderSource)ReadFolder(row)).ToArray();
    }

    /// <summary>Folders left 'scanning' without a live scan job become partial (never missing-marked).</summary>
    internal int RepairOrphanScans(long now)
    {
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            int repaired = _conn.Execute("""
                UPDATE folder_sources SET scan_state='partial' WHERE scan_state='scanning' AND NOT EXISTS(
                    SELECT 1 FROM ingest_jobs j WHERE j.kind='scan' AND j.target='folder:'||folder_sources.id
                        AND j.state='running' AND j.lease_until>$now)
                """, new { now }, tx);
            tx.Commit();
            return repaired;
        }
    }

    private bool OwnsEmbed(SqliteTransaction tx, JobFence fence, long now, out IngestJob? job)
    {
        job = RevisionJobSQL.ValidateFence(_conn, tx, fence, now);
        return job is { Draft.Kind: "embed" };
    }

    /// <summary>Captured member is still the published, eligible, present revision (and the manifest revision).</summary>
    private bool FreshMember(SqliteTransaction tx, long chunkId, long revisionId, long? generationId) =>
        _conn.ExecuteScalar<bool>("""
            SELECT EXISTS(SELECT 1 FROM source_chunks c JOIN sources s ON s.id=c.source_id
                WHERE c.id=$chunkId AND c.revision_id=$revisionId AND s.published_revision_id=$revisionId
                  AND s.availability='present' AND s.eligible=1
                  AND ($generationId IS NULL OR EXISTS(SELECT 1 FROM index_generation_manifest m
                    WHERE m.generation_id=$generationId AND m.source_id=s.id AND m.revision_id=$revisionId)))
            """, new { chunkId, revisionId, generationId }, tx);

    private static void RequireBatchShape(IReadOnlyList<long> chunkIds, IReadOnlyList<long> revisionIds, IReadOnlyList<float[]> vectors)
    {
        ArgumentNullException.ThrowIfNull(chunkIds);
        ArgumentNullException.ThrowIfNull(revisionIds);
        ArgumentNullException.ThrowIfNull(vectors);
        if (chunkIds.Count != revisionIds.Count || chunkIds.Count != vectors.Count) throw new StorageV19Exception("invalidVector");
    }

    private static FolderEmbeddingItem Item(dynamic row) =>
        new((long)row.id, (long)row.revision_id, (long)row.source_id, (string)row.text);

    private static string GenerationTarget(long id) => "generation:" + id.ToString(CultureInfo.InvariantCulture);
    private static string NotebookTarget(long id) => "notebook:" + id.ToString(CultureInfo.InvariantCulture);
    private static long TargetId(string target) =>
        long.Parse(target[(target.IndexOf(':') + 1)..], NumberStyles.None, CultureInfo.InvariantCulture);
}

public sealed partial class NotebookStore
{
    /// <summary>
    /// Runtime start / reconcile (<c>ingestion-build-merge-v1</c> §4): an unclaimed incremental bootstrap of a space that
    /// already has a building (or current active) generation joins that generation's job or completes as a no-op, so it
    /// never builds a second generation. Returns the bootstraps resolved.
    /// </summary>
    internal int MergeRedundantBootstraps(long now)
    {
        int count = 0;
        var notebooks = new SortedSet<long>();
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var candidates = _conn.Query<long>("""
                SELECT id FROM ingest_jobs WHERE kind='embed' AND target LIKE 'notebook:%' AND (state IN ('queued','paused')
                    OR (state='failed' AND attempts<5 AND next_retry_at IS NOT NULL)) ORDER BY id
                """, transaction: tx).ToArray();
            foreach (long id in candidates)
            {
                // An earlier merge of this pass may already have superseded it.
                var row = _conn.QuerySingleOrDefault("""
                    SELECT id,target,state,attempts,next_retry_at,error,options_json FROM ingest_jobs WHERE id=$id
                    """, new { id }, tx);
                if (row is null) continue;
                EmbedJobSnapshot job = EmbedJobSnapshotOf(row);
                long notebookId = TargetId(job.Target);
                var action = EmbedJobPlanning.Startup(job, GenerationSnapshots(_conn, tx, notebookId),
                    NotebookNeedsEmbeddingLocked(notebookId, tx));
                if (action == BootstrapStartupAction.Keep) continue;
                if (action == BootstrapStartupAction.Merge)
                    IngestionGenerationSQL.QueueEmbedding(_conn, tx, notebookId, job.IncrementalSelection!, copyExisting: true, now);
                IngestionGenerationSQL.CompleteBootstraps(_conn, tx, [job.Id]);
                count++;
                notebooks.Add(notebookId);
            }
            tx.Commit();
        }
        foreach (long notebookId in notebooks) NotifyFolderIngestionChanged(notebookId);
        return count;
    }
}

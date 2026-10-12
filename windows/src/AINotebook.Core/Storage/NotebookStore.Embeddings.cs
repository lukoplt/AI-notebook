using AINotebook.Core.Models;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

internal sealed record EmbeddingBatchItem(SourceChunk Chunk, long NotebookId, long? GenerationId);
internal sealed record EmbeddingBatch(string ModelKey, IReadOnlyList<EmbeddingBatchItem> Items);
internal sealed record EmbeddingBatchResult(int Written, bool Stale, IReadOnlyList<long> GenerationIds);

public sealed partial class NotebookStore
{
    private const string WorkGeneration = """
        SELECT g.id FROM index_generations g WHERE g.notebook_id=s.notebook_id
            AND (CASE WHEN g.provider_id='legacy' THEN g.model ELSE g.provider_id||':'||g.model END)=$model
            AND g.state IN ('building','active')
        ORDER BY CASE g.state WHEN 'building' THEN 0 ELSE 1 END,g.id DESC LIMIT 1
        """;

    private static readonly string MissingPublishedChunks = $$"""
        FROM source_chunks sc JOIN sources s ON s.id=sc.source_id
        WHERE sc.revision_id=s.published_revision_id AND s.availability='present' AND s.eligible=1
            AND NOT EXISTS(SELECT 1 FROM chunk_embeddings e
                JOIN index_generations g ON g.id=e.generation_id
                JOIN index_generation_manifest m ON m.generation_id=g.id AND m.source_id=sc.source_id
                    AND m.revision_id=sc.revision_id
                WHERE e.chunk_id=sc.id AND length(e.embedding)=g.dims*4 AND g.id=({{WorkGeneration}}))
        """;

    public IndexGeneration PrepareEmbeddingGeneration(long notebookId, string modelKey, int dims, long now, bool copyExisting)
    {
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var generation = PrepareEmbeddingGeneration(_conn, tx, notebookId, modelKey, dims, now, copyExisting, null);
            tx.Commit();
            return generation;
        }
    }

    public bool CompleteEmbeddingGeneration(long id, string selectedModelKey, long now)
    {
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            bool activated = CompleteEmbeddingGeneration(_conn, tx, id, selectedModelKey, now);
            tx.Commit();
            return activated;
        }
    }

    public void StoreEmbedding(long chunkId, string model, EmbeddingVector vector)
    {
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var chunk = _conn.QuerySingleOrDefault("""
                SELECT c.revision_id,s.notebook_id,s.published_revision_id,s.availability,s.eligible
                FROM source_chunks c JOIN sources s ON s.id=c.source_id WHERE c.id=$chunkId
                """, new { chunkId }, tx) ?? throw new StorageV19Exception("notFound");
            if ((long?)chunk.revision_id != (long?)chunk.published_revision_id ||
                (string)chunk.availability != "present" || (long)chunk.eligible != 1)
                throw new StorageV19Exception("staleRevision");
            long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var generation = PrepareEmbeddingGeneration(_conn, tx, (long)chunk.notebook_id, model, vector.Dim, now, true, chunkId);
            GenerationSQL.StoreEmbedding(_conn, tx, generation.Id, chunkId, vector);
            RefreshEmbeddingCompletion(_conn, tx, generation);
            CompleteEmbeddingGeneration(_conn, tx, generation.Id, model, now);
            tx.Commit();
        }
    }

    /// <summary>
    /// Inspects the newest work generation, including partial revisions. Retrieval must
    /// use PinnedEmbeddings, which requires completed manifest membership.
    /// </summary>
    public IReadOnlyList<StoredEmbedding> Embeddings(long notebookId, string model)
    {
        lock (_gate)
        {
            return _conn.Query("""
                SELECT e.chunk_id,c.source_id,e.embedding FROM chunk_embeddings e
                JOIN source_chunks c ON c.id=e.chunk_id JOIN sources s ON s.id=c.source_id
                JOIN index_generation_manifest m ON m.generation_id=e.generation_id
                    AND m.source_id=c.source_id AND m.revision_id=c.revision_id
                WHERE s.notebook_id=$notebookId AND s.availability='present' AND s.eligible=1
                    AND e.generation_id=(SELECT g.id FROM index_generations g WHERE g.notebook_id=$notebookId
                        AND (CASE WHEN g.provider_id='legacy' THEN g.model ELSE g.provider_id||':'||g.model END)=$model
                        AND g.state IN ('building','active')
                        ORDER BY CASE g.state WHEN 'building' THEN 0 ELSE 1 END,g.id DESC LIMIT 1)
                ORDER BY e.chunk_id
                """, new { notebookId, model })
                .Select(row => new StoredEmbedding((long)row.chunk_id, (long)row.source_id,
                    EmbeddingVector.FromBytes((byte[])row.embedding))).ToArray();
        }
    }

    public IReadOnlyList<SourceChunk> UnembeddedChunks(string model, int limit)
    {
        if (limit <= 0) return Array.Empty<SourceChunk>();
        lock (_gate)
            return _conn.Query("SELECT sc.* " + MissingPublishedChunks + " ORDER BY sc.id LIMIT $limit", new { model, limit })
                .Select(row => (SourceChunk)MapChunk(row)).ToArray();
    }

    public int UnembeddedCount(string model)
    {
        lock (_gate)
            return _conn.ExecuteScalar<int>("SELECT count(*) " + MissingPublishedChunks, new { model });
    }

    /// <summary>Requests reindexing through empty work generations; active and pinned evidence remains readable.</summary>
    public void DeleteAllEmbeddings(string model)
    {
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var known = _conn.Query("""
                SELECT id,notebook_id,dims FROM index_generations
                WHERE (CASE WHEN provider_id='legacy' THEN model ELSE provider_id||':'||model END)=$model
                ORDER BY notebook_id,CASE state WHEN 'building' THEN 0 WHEN 'active' THEN 1 ELSE 2 END,id DESC
                """, new { model }, tx).ToArray();
            foreach (var group in known.GroupBy(row => (long)row.notebook_id))
            {
                var latest = group.First();
                PrepareEmbeddingGeneration(_conn, tx, group.Key, model, (int)(long)latest.dims,
                    DateTimeOffset.UtcNow.ToUnixTimeSeconds(), false, null);
            }
            tx.Commit();
        }
    }

    internal EmbeddingBatch CaptureEmbeddingBatch(string modelKey, int limit)
    {
        if (limit <= 0) return new EmbeddingBatch(modelKey, Array.Empty<EmbeddingBatchItem>());
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: true);
            var rows = _conn.Query("SELECT sc.*,s.notebook_id " + MissingPublishedChunks + " ORDER BY sc.id LIMIT $limit",
                new { model = modelKey, limit }, tx);
            var items = new List<EmbeddingBatchItem>();
            foreach (var row in rows)
            {
                long notebookId = (long)row.notebook_id;
                long? generationId = LatestBuildingEmbeddingGeneration(_conn, tx, notebookId, modelKey);
                items.Add(new EmbeddingBatchItem((SourceChunk)MapChunk(row), notebookId, generationId));
            }
            tx.Commit();
            return new EmbeddingBatch(modelKey, items);
        }
    }

    internal EmbeddingBatchResult CommitEmbeddingBatch(EmbeddingBatch batch, IReadOnlyList<EmbeddingVector> vectors, long now)
    {
        if (vectors.Count != batch.Items.Count) throw new EmbedderException.ResponseSizeMismatch(batch.Items.Count, vectors.Count);
        if (vectors.Count == 0) return new EmbeddingBatchResult(0, false, Array.Empty<long>());
        int dims = vectors[0].Dim;
        if (dims <= 0 || vectors.Any(vector => vector.Dim != dims || vector.Values.Any(value => !float.IsFinite(value))))
            throw new StorageV19Exception("invalidVector");
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            bool stale = false;
            int written = 0;
            var generations = new HashSet<long>();
            foreach (var group in batch.Items.Select((item, index) => (Item: item, Index: index)).GroupBy(row => row.Item.NotebookId))
            {
                if (!_conn.ExecuteScalar<bool>("SELECT EXISTS(SELECT 1 FROM notebooks WHERE id=$id)", new { id = group.Key }, tx))
                {
                    stale = true;
                    continue;
                }
                long? capturedId = group.First().Item.GenerationId;
                IndexGeneration generation;
                if (capturedId is long id)
                {
                    var captured = GenerationSQL.Read(_conn, tx, id);
                    if (captured is null || captured.State != "building" ||
                        LatestBuildingEmbeddingGeneration(_conn, tx, group.Key, batch.ModelKey) != id)
                    {
                        stale = true;
                        continue;
                    }
                    if (captured.Identity.Dims != dims) throw new StorageV19Exception("invalidVector");
                    generation = captured;
                    GenerationSQL.Reconcile(_conn, tx, generation.Id);
                }
                else generation = PrepareEmbeddingGeneration(_conn, tx, group.Key, batch.ModelKey, dims, now, true, null);
                generations.Add(generation.Id);
                foreach (var entry in group)
                {
                    var chunk = entry.Item.Chunk;
                    bool current = _conn.ExecuteScalar<bool>("""
                        SELECT EXISTS(SELECT 1 FROM source_chunks c JOIN sources s ON s.id=c.source_id
                            JOIN index_generation_manifest m ON m.generation_id=$generationId
                                AND m.source_id=s.id AND m.revision_id=c.revision_id
                            WHERE c.id=$chunkId AND c.revision_id=$revisionId AND c.text=$text
                                AND s.notebook_id=$notebookId AND s.published_revision_id=c.revision_id
                                AND s.availability='present' AND s.eligible=1)
                        """, new { generationId = generation.Id, chunkId = chunk.Id, revisionId = chunk.RevisionId,
                            text = chunk.Text, notebookId = entry.Item.NotebookId }, tx);
                    if (!current) { stale = true; continue; }
                    GenerationSQL.StoreEmbedding(_conn, tx, generation.Id, chunk.Id!.Value, vectors[entry.Index]);
                    written++;
                }
                RefreshEmbeddingCompletion(_conn, tx, generation);
            }
            tx.Commit();
            return new EmbeddingBatchResult(written, stale, generations.ToArray());
        }
    }

    internal void CompleteAvailableEmbeddingWork(string modelKey, string selectedModelKey, long now)
    {
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var candidates = _conn.Query<long>("""
                SELECT id FROM index_generations WHERE state IN ('building','active')
                    AND (CASE WHEN provider_id='legacy' THEN model ELSE provider_id||':'||model END)=$modelKey
                ORDER BY notebook_id,CASE state WHEN 'building' THEN 0 ELSE 1 END,id DESC
                """, new { modelKey }, tx).Select(id => GenerationSQL.Read(_conn, tx, id)!).ToArray();
            foreach (var group in candidates.GroupBy(generation => generation.NotebookId))
            {
                var generation = group.First();
                if (generation.State == "active")
                {
                    bool changed = _conn.ExecuteScalar<bool>("""
                        SELECT EXISTS(SELECT 1 FROM sources s WHERE s.notebook_id=$notebookId
                            AND s.availability='present' AND s.eligible=1 AND s.current_revision IS NOT NULL
                            AND NOT EXISTS(SELECT 1 FROM index_generation_manifest m WHERE m.generation_id=$generationId
                                AND m.source_id=s.id AND m.revision_id=s.current_revision))
                        """, new { notebookId = generation.NotebookId, generationId = generation.Id }, tx);
                    if (!changed) continue;
                    generation = PrepareEmbeddingGeneration(_conn, tx, generation.NotebookId, modelKey,
                        generation.Identity.Dims, now, true, null);
                }
                CompleteEmbeddingGeneration(_conn, tx, generation.Id, selectedModelKey, now);
            }
            tx.Commit();
        }
    }

    private static long? LatestBuildingEmbeddingGeneration(SqliteConnection c, SqliteTransaction tx, long notebookId, string modelKey)
        => c.QuerySingleOrDefault<long?>("""
            SELECT id FROM index_generations WHERE notebook_id=$notebookId AND state='building'
                AND (CASE WHEN provider_id='legacy' THEN model ELSE provider_id||':'||model END)=$modelKey
            ORDER BY id DESC LIMIT 1
            """, new { notebookId, modelKey }, tx);

    private static IndexGeneration PrepareEmbeddingGeneration(SqliteConnection c, SqliteTransaction tx,
        long notebookId, string modelKey, int dims, long now, bool copyExisting, long? excludingChunkId)
    {
        if (string.IsNullOrWhiteSpace(modelKey) || dims <= 0) throw new StorageV19Exception("invalidValue");
        var identity = new GenerationIdentity("legacy", "legacy", modelKey, null, dims, "legacy", "legacy", "legacy", "legacy");
        long? latestId = LatestBuildingEmbeddingGeneration(c, tx, notebookId, modelKey);
        var latest = latestId is long id ? GenerationSQL.Read(c, tx, id) : null;
        if (copyExisting && latest is not null && latest.Identity == identity)
        {
            GenerationSQL.Reconcile(c, tx, latest.Id);
            return latest;
        }
        c.Execute("""
            UPDATE index_generations SET state='retired' WHERE notebook_id=$notebookId AND state='building'
                AND (CASE WHEN provider_id='legacy' THEN model ELSE provider_id||':'||model END)=$modelKey
            """, new { notebookId, modelKey }, tx);
        var generation = GenerationSQL.Create(c, tx, notebookId, identity, now);
        if (copyExisting)
        {
            var previous = c.Query<long>("""
                SELECT id FROM index_generations WHERE notebook_id=$notebookId AND id<>$id
                    AND provider_id='legacy' AND model=$modelKey AND dims=$dims ORDER BY id DESC
                """, new { notebookId, id = generation.Id, modelKey, dims }, tx)
                .Select(oldId => GenerationSQL.Read(c, tx, oldId)!).FirstOrDefault(old => old.Identity == identity);
            if (previous is not null)
                GenerationSQL.CopyUnchangedVectors(c, tx, previous.Id, generation.Id, excludingChunkId);
        }
        return generation;
    }

    private static void RefreshEmbeddingCompletion(SqliteConnection c, SqliteTransaction tx, IndexGeneration generation)
    {
        var completed = GenerationSQL.ReadManifest(c, tx, generation.Id).Where(entry => entry.State == "pending")
            .Where(entry => c.ExecuteScalar<bool>("""
                SELECT EXISTS(SELECT 1 FROM sources WHERE id=$sourceId AND published_revision_id=$revisionId)
                    AND NOT EXISTS(SELECT 1 FROM source_chunks chunk WHERE chunk.revision_id=$revisionId
                        AND NOT EXISTS(SELECT 1 FROM chunk_embeddings e WHERE e.chunk_id=chunk.id
                            AND e.generation_id=$generationId AND length(e.embedding)=$bytes))
                """, new { sourceId = entry.SourceId, revisionId = entry.RevisionId, generationId = generation.Id,
                    bytes = (long)generation.Identity.Dims * sizeof(float) }, tx))
            .Select(entry => entry with { State = "done", Reason = null }).ToArray();
        if (completed.Length > 0) GenerationSQL.SetManifest(c, tx, generation.Id, completed);
    }

    private static bool CompleteEmbeddingGeneration(SqliteConnection c, SqliteTransaction tx, long id, string selectedModelKey, long now)
    {
        var generation = GenerationSQL.Read(c, tx, id) ?? throw new StorageV19Exception("notFound");
        if (generation.State != "building") return false;
        GenerationSQL.Reconcile(c, tx, id);
        RefreshEmbeddingCompletion(c, tx, generation);
        if (!StringComparer.Ordinal.Equals(GenerationSQL.ModelKey(generation.Identity), selectedModelKey)) return false;
        try { GenerationSQL.Activate(c, tx, id, null, now); return true; }
        catch (StorageV19Exception error) when (error.Code == "generationNotReady") { return false; }
    }
}

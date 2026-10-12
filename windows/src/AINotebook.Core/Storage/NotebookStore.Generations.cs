using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    private string? _generationDatabaseIdentity;
    private string GenerationDatabaseIdentity => _generationDatabaseIdentity ??= GenerationPinRegistry.Identity(_conn);

    private T WriteGeneration<T>(Func<SqliteConnection, SqliteTransaction, T> action)
    {
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction(deferred: false);
            T result = action(_conn, transaction);
            transaction.Commit();
            return result;
        }
    }

    public IndexGeneration CreateGeneration(long notebookId, GenerationIdentity identity, long now)
        => WriteGeneration((c, tx) => GenerationSQL.Create(c, tx, notebookId, identity, now));

    public IndexGeneration? Generation(long id)
    {
        lock (_gate) return GenerationSQL.Read(_conn, null, id);
    }

    public IndexGeneration? ActiveGeneration(long notebookId)
    {
        lock (_gate)
        {
            RequireNotebookV19(notebookId);
            long? id = _conn.QuerySingleOrDefault<long?>(
                "SELECT id FROM index_generations WHERE notebook_id=$notebookId AND state='active'", new { notebookId });
            return id is long value ? GenerationSQL.Read(_conn, null, value) : null;
        }
    }

    public void SetManifest(long generationId, IReadOnlyList<ManifestEntry> entries)
        => WriteGeneration((c, tx) => { GenerationSQL.SetManifest(c, tx, generationId, entries); return true; });

    public IReadOnlyList<ManifestEntry> Manifest(long generationId)
    {
        lock (_gate)
        {
            if (GenerationSQL.Read(_conn, null, generationId) is null) throw new StorageV19Exception("notFound");
            return GenerationSQL.ReadManifest(_conn, null, generationId);
        }
    }

    public void ReconcileManifest(long generationId)
        => WriteGeneration((c, tx) => { GenerationSQL.Reconcile(c, tx, generationId); return true; });

    public void StoreGenerationEmbedding(long generationId, long chunkId, EmbeddingVector vector)
        => WriteGeneration((c, tx) => { GenerationSQL.StoreEmbedding(c, tx, generationId, chunkId, vector); return true; });

    public void ActivateGeneration(long id, long now)
        => WriteGeneration((c, tx) => { GenerationSQL.Activate(c, tx, id, null, now); return true; });

    public void RetireGeneration(long id)
        => WriteGeneration((c, tx) =>
        {
            if (GenerationSQL.Read(c, tx, id) is null) throw new StorageV19Exception("notFound");
            c.Execute("UPDATE index_generations SET state='retired' WHERE id=$id AND state IN ('active','building','failed')", new { id }, tx);
            return true;
        });

    public QueryPin PinQuery(long notebookId, string modelKey)
        => WithQueryPin(notebookId, modelKey, (_, _, _) => true).Pin;

    internal (QueryPin Pin, T Value) WithQueryPin<T>(long notebookId, string modelKey,
        Func<SqliteConnection, SqliteTransaction, QueryPin, T> read)
    {
        lock (_gate)
        {
            using var registry = GenerationPinRegistry.Acquire(GenerationDatabaseIdentity);
            using var transaction = _conn.BeginTransaction(deferred: true);
            RetrievalStatementExecuted?.Invoke("pinQuery");
            RequireNotebookV19(notebookId, transaction);
            long? activeId = _conn.QuerySingleOrDefault<long?>("""
                SELECT id FROM index_generations WHERE notebook_id=$notebookId AND state='active'
                """, new { notebookId }, transaction);
            var active = activeId is long id ? GenerationSQL.Read(_conn, transaction, id) : null;
            bool anyActive = active is not null;
            if (active is not null && (string.IsNullOrEmpty(modelKey) ||
                !StringComparer.Ordinal.Equals(GenerationSQL.ModelKey(active.Identity), modelKey)))
                active = null;
            var lexical = _conn.Query("""
                SELECT id,published_revision_id FROM sources WHERE notebook_id=$notebookId
                    AND availability='present' AND eligible=1 AND published_revision_id IS NOT NULL ORDER BY id
                """, new { notebookId }, transaction)
                .ToDictionary(row => (long)row.id, row => (long)row.published_revision_id);
            var vectors = active is null ? new Dictionary<long, long>() : _conn.Query("""
                SELECT m.source_id,m.revision_id FROM index_generation_manifest m
                JOIN sources s ON s.id=m.source_id
                WHERE m.generation_id=$generationId AND m.state='done' AND s.notebook_id=$notebookId
                    AND s.availability='present' AND s.eligible=1 ORDER BY m.source_id
                """, new { generationId = active.Id, notebookId }, transaction)
                .ToDictionary(row => (long)row.source_id, row => (long)row.revision_id);
            if (!anyActive && GenerationSQL.PartialCandidate(_conn, transaction, notebookId, modelKey) is { } building)
            {
                // retrieval-partial-index-v1 §3: only completed sources at their current published revision.
                var partial = _conn.Query("""
                    SELECT m.source_id,m.revision_id FROM index_generation_manifest m
                    JOIN sources s ON s.id=m.source_id
                    WHERE m.generation_id=$generationId AND m.state='done' AND s.notebook_id=$notebookId
                        AND s.availability='present' AND s.eligible=1 AND s.published_revision_id=m.revision_id
                    ORDER BY m.source_id
                    """, new { generationId = building.Id, notebookId }, transaction)
                    .ToDictionary(row => (long)row.source_id, row => (long)row.revision_id);
                if (partial.Count > 0)
                {
                    active = building;
                    vectors = partial;
                }
            }
            var pin = new QueryPin(Guid.NewGuid().ToString("N"), notebookId, active?.Id,
                active is null ? null : modelKey, active?.Identity.Dims, lexical, vectors);
            T value = read(_conn, transaction, pin);
            transaction.Commit();
            registry.Pins.Add(pin.Token, pin);
            return (pin, value);
        }
    }

    public void ReleaseQuery(QueryPin pin)
    {
        lock (_gate)
        {
            using var registry = GenerationPinRegistry.Acquire(GenerationDatabaseIdentity);
            registry.Pins.Remove(pin.Token);
        }
    }

    public IReadOnlyList<StoredEmbedding> PinnedEmbeddings(QueryPin pin)
    {
        lock (_gate)
        {
            using var registry = GenerationPinRegistry.Acquire(GenerationDatabaseIdentity);
            if (!registry.Pins.TryGetValue(pin.Token, out var saved) || saved.GenerationId is not long generationId)
                return Array.Empty<StoredEmbedding>();
            using var transaction = _conn.BeginTransaction(deferred: true);
            var rows = _conn.Query("""
                SELECT e.chunk_id,c.source_id,c.revision_id,e.embedding FROM chunk_embeddings e
                JOIN source_chunks c ON c.id=e.chunk_id
                JOIN sources s ON s.id=c.source_id
                JOIN index_generation_manifest m ON m.generation_id=e.generation_id
                    AND m.source_id=c.source_id AND m.revision_id=c.revision_id AND m.state='done'
                WHERE e.generation_id=$generationId AND s.notebook_id=$notebookId
                    AND s.availability='present' AND s.eligible=1 AND length(e.embedding)=$byteCount
                ORDER BY e.chunk_id
                """, new { generationId, notebookId = saved.NotebookId, byteCount = (long)saved.Dims!.Value * sizeof(float) }, transaction);
            var result = new List<StoredEmbedding>();
            foreach (var row in rows)
                if (saved.VectorRevisions.TryGetValue((long)row.source_id, out long revision) && revision == (long)row.revision_id)
                    result.Add(new StoredEmbedding((long)row.chunk_id, (long)row.source_id,
                        EmbeddingVector.FromBytes((byte[])row.embedding)));
            transaction.Commit();
            return result;
        }
    }

    public GarbageCollectionResult GarbageCollect(long notebookId)
    {
        lock (_gate)
        {
            using var registry = GenerationPinRegistry.Acquire(GenerationDatabaseIdentity);
            using var transaction = _conn.BeginTransaction(deferred: false);
            RequireNotebookV19(notebookId, transaction);
            // Temporary bound IDs avoid a parameter limit for notebooks with many pinned sources.
            _conn.Execute("""
                CREATE TEMP TABLE IF NOT EXISTS v19_gc_pin_generations(id INTEGER PRIMARY KEY);
                CREATE TEMP TABLE IF NOT EXISTS v19_gc_pin_revisions(id INTEGER PRIMARY KEY);
                DELETE FROM v19_gc_pin_generations;
                DELETE FROM v19_gc_pin_revisions;
                """, transaction: transaction);
            foreach (var saved in registry.Pins.Values.Where(value => value.NotebookId == notebookId))
            {
                if (saved.GenerationId is long generation)
                    _conn.Execute("INSERT OR IGNORE INTO v19_gc_pin_generations(id) VALUES($generation)", new { generation }, transaction);
                foreach (long revision in saved.LexicalRevisions.Values.Concat(saved.VectorRevisions.Values).Distinct())
                    _conn.Execute("INSERT OR IGNORE INTO v19_gc_pin_revisions(id) VALUES($revision)", new { revision }, transaction);
            }
            var before = GenerationCounts(_conn, transaction, notebookId);
            _conn.Execute("""
                DELETE FROM index_generations WHERE notebook_id=$notebookId AND state IN ('retired','failed')
                    AND NOT EXISTS(SELECT 1 FROM v19_gc_pin_generations p WHERE p.id=index_generations.id)
                """, new { notebookId }, transaction);
            _conn.Execute("""
                DELETE FROM source_revisions WHERE source_id IN (SELECT id FROM sources WHERE notebook_id=$notebookId)
                    AND NOT EXISTS(SELECT 1 FROM sources s WHERE s.current_revision=source_revisions.id OR s.published_revision_id=source_revisions.id)
                    AND NOT EXISTS(SELECT 1 FROM index_generation_manifest m JOIN index_generations g ON g.id=m.generation_id
                        WHERE m.revision_id=source_revisions.id AND g.state IN ('active','building'))
                    AND NOT EXISTS(SELECT 1 FROM v19_gc_pin_revisions p WHERE p.id=source_revisions.id)
                    AND NOT EXISTS(SELECT 1 FROM ingest_jobs j WHERE j.target_revision=source_revisions.id
                        AND (j.state IN ('queued','running','paused') OR (j.state='failed' AND j.next_retry_at IS NOT NULL)))
                """, new { notebookId }, transaction);
            var after = GenerationCounts(_conn, transaction, notebookId);
            _conn.Execute("DELETE FROM v19_gc_pin_generations; DELETE FROM v19_gc_pin_revisions;", transaction: transaction);
            transaction.Commit();
            return new GarbageCollectionResult(before.Generations - after.Generations, before.Revisions - after.Revisions,
                before.Chunks - after.Chunks, before.Vectors - after.Vectors);
        }
    }

    private static GarbageCollectionResult GenerationCounts(SqliteConnection c, SqliteTransaction tx, long notebookId)
    {
        var row = c.QuerySingle("""
            SELECT (SELECT count(*) FROM index_generations WHERE notebook_id=$notebookId) AS generations,
                (SELECT count(*) FROM source_revisions r JOIN sources s ON s.id=r.source_id WHERE s.notebook_id=$notebookId) AS revisions,
                (SELECT count(*) FROM source_chunks c JOIN sources s ON s.id=c.source_id WHERE s.notebook_id=$notebookId) AS chunks,
                (SELECT count(*) FROM chunk_embeddings e JOIN index_generations g ON g.id=e.generation_id WHERE g.notebook_id=$notebookId) AS vectors
            """, new { notebookId }, tx);
        return new GarbageCollectionResult((int)(long)row.generations, (int)(long)row.revisions, (int)(long)row.chunks, (int)(long)row.vectors);
    }
}

/// <summary>Generation operations using the caller's connection gate and transaction.</summary>
internal static class GenerationSQL
{
    internal static IndexGeneration? Read(SqliteConnection c, SqliteTransaction? tx, long id)
    {
        var row = c.QuerySingleOrDefault("SELECT * FROM index_generations WHERE id=$id", new { id }, tx);
        return row is null ? null : new IndexGeneration((long)row.id, (long)row.notebook_id,
            new GenerationIdentity((string)row.provider_id, (string)row.endpoint_revision, (string)row.model,
                (string?)row.model_digest, (int)(long)row.dims, (string)row.normalization,
                (string)row.query_format_version, (string)row.doc_format_version, (string)row.chunker_version),
            (string)row.state, new DateTimeOffset(SqliteDate.FromDb((string)row.created_at)).ToUnixTimeSeconds(),
            row.activated_at is null ? null : new DateTimeOffset(SqliteDate.FromDb((string)row.activated_at)).ToUnixTimeSeconds());
    }

    internal static IReadOnlyList<ManifestEntry> ReadManifest(SqliteConnection c, SqliteTransaction? tx, long generationId)
        => c.Query("SELECT source_id,revision_id,state,reason FROM index_generation_manifest WHERE generation_id=$generationId ORDER BY source_id",
            new { generationId }, tx)
            .Select(row => new ManifestEntry((long)row.source_id, (long)row.revision_id, (string)row.state, (string?)row.reason)).ToArray();

    internal static string ModelKey(GenerationIdentity identity)
        => identity.ProviderId == "legacy" ? identity.Model : identity.ProviderId + ":" + identity.Model;

    /// <summary>
    /// retrieval-partial-index-v1 §3.1: with no active generation, the newest building
    /// generation of the query's storage model key may serve its completed sources.
    /// </summary>
    internal static IndexGeneration? PartialCandidate(SqliteConnection c, SqliteTransaction? tx, long notebookId, string modelKey)
    {
        if (string.IsNullOrEmpty(modelKey)) return null;
        foreach (long id in c.Query<long>("""
            SELECT id FROM index_generations WHERE notebook_id=$notebookId AND state='building' ORDER BY id DESC
            """, new { notebookId }, tx).ToArray())
        {
            if (Read(c, tx, id) is { } generation && StringComparer.Ordinal.Equals(ModelKey(generation.Identity), modelKey))
                return generation;
        }
        return null;
    }

    internal static IndexGeneration Create(SqliteConnection c, SqliteTransaction tx, long notebookId, GenerationIdentity identity, long now)
    {
        ValidateIdentity(identity);
        if (!c.ExecuteScalar<bool>("SELECT EXISTS(SELECT 1 FROM notebooks WHERE id=$notebookId)", new { notebookId }, tx))
            throw new StorageV19Exception("notFound");
        long id = c.ExecuteScalar<long>("""
            INSERT INTO index_generations(notebook_id,provider_id,endpoint_revision,model,model_digest,dims,
                normalization,query_format_version,doc_format_version,chunker_version,state,created_at)
            VALUES($notebookId,$ProviderId,$EndpointRevision,$Model,$ModelDigest,$Dims,$Normalization,
                $QueryFormatVersion,$DocFormatVersion,$ChunkerVersion,'building',$created);
            SELECT last_insert_rowid();
            """, new
        {
            notebookId, identity.ProviderId, identity.EndpointRevision, identity.Model, identity.ModelDigest,
            identity.Dims, identity.Normalization, identity.QueryFormatVersion, identity.DocFormatVersion, identity.ChunkerVersion,
            created = SqliteDate.ToDb(DateTimeOffset.FromUnixTimeSeconds(now).UtcDateTime)
        }, tx);
        c.Execute("""
            INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state)
            SELECT $id,id,current_revision,'pending' FROM sources WHERE notebook_id=$notebookId
                AND availability='present' AND eligible=1 AND current_revision IS NOT NULL
            """, new { id, notebookId }, tx);
        return Read(c, tx, id)!;
    }

    internal static void Reconcile(SqliteConnection c, SqliteTransaction tx, long generationId)
    {
        var generation = RequireBuilding(c, tx, generationId);
        // Runs on every batch commit: only rows that actually change are written, so a settled manifest
        // is not rewritten (identical exclusions are skipped; the upsert reads sources/manifest only).
        c.Execute("""
            DELETE FROM index_generation_manifest WHERE generation_id=$generationId AND source_id IN
                (SELECT id FROM sources WHERE current_revision IS NULL);
            UPDATE index_generation_manifest SET state='excluded',reason=(
                SELECT CASE WHEN s.availability<>'present' THEN s.availability ELSE 'ineligible' END
                FROM sources s WHERE s.id=index_generation_manifest.source_id)
            WHERE generation_id=$generationId AND source_id IN
                (SELECT id FROM sources WHERE availability<>'present' OR eligible=0)
              AND NOT (state='excluded' AND reason IS (
                SELECT CASE WHEN s.availability<>'present' THEN s.availability ELSE 'ineligible' END
                FROM sources s WHERE s.id=index_generation_manifest.source_id));
            INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state)
            SELECT $generationId,s.id,s.current_revision,'pending' FROM sources s
            LEFT JOIN index_generation_manifest m ON m.generation_id=$generationId AND m.source_id=s.id
            WHERE s.notebook_id=$notebookId AND s.availability='present' AND s.eligible=1 AND s.current_revision IS NOT NULL
                AND (m.source_id IS NULL OR m.revision_id<>s.current_revision
                    OR (m.state='excluded' AND m.reason IN ('missing','unavailable','ineligible')))
            ON CONFLICT(generation_id,source_id) DO UPDATE SET revision_id=excluded.revision_id,state='pending',reason=NULL
                WHERE index_generation_manifest.revision_id<>excluded.revision_id
                    OR (index_generation_manifest.state='excluded'
                        AND index_generation_manifest.reason IN ('missing','unavailable','ineligible'))
            """, new { generationId, notebookId = generation.NotebookId }, tx);
    }

    internal static void SetManifest(SqliteConnection c, SqliteTransaction tx, long generationId, IReadOnlyList<ManifestEntry> entries)
    {
        var generation = RequireBuilding(c, tx, generationId);
        foreach (var entry in entries)
        {
            if (entry.State is not ("pending" or "done" or "excluded") ||
                entry.State == "excluded" && string.IsNullOrWhiteSpace(entry.Reason))
                throw new StorageV19Exception("invalidValue");
            var source = c.QuerySingleOrDefault("SELECT notebook_id,current_revision,published_revision_id FROM sources WHERE id=$id", new { id = entry.SourceId }, tx)
                ?? throw new StorageV19Exception("notFound");
            if ((long)source.notebook_id != generation.NotebookId) throw new StorageV19Exception("notebookMismatch");
            var revision = RevisionJobSQL.ReadRevision(c, tx, entry.RevisionId) ?? throw new StorageV19Exception("notFound");
            if (revision.SourceId != entry.SourceId) throw new StorageV19Exception("staleRevision");
            if (source.current_revision is null) throw new StorageV19Exception("staleRevision");
            if (entry.State == "done" && ((long?)source.published_revision_id != entry.RevisionId ||
                !CompleteVectors(c, tx, generationId, entry.RevisionId, generation.Identity.Dims)))
                throw new StorageV19Exception("generationNotReady");
        }
        foreach (var entry in entries)
            c.Execute("""
                INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state,reason)
                VALUES($generationId,$SourceId,$RevisionId,$State,$Reason)
                ON CONFLICT(generation_id,source_id) DO UPDATE SET revision_id=excluded.revision_id,
                    state=excluded.state,reason=excluded.reason
                """, new { generationId, entry.SourceId, entry.RevisionId, entry.State, entry.Reason }, tx);
    }

    internal static void StoreEmbedding(SqliteConnection c, SqliteTransaction tx, long generationId, long chunkId, EmbeddingVector vector)
        => StoreEmbedding(c, tx, RequireBuilding(c, tx, generationId), chunkId, vector);

    /// <summary>Kernel for a generation the caller already read as building in this transaction (batch commits).</summary>
    internal static void StoreEmbedding(SqliteConnection c, SqliteTransaction tx, IndexGeneration generation, long chunkId, EmbeddingVector vector)
    {
        if (generation.State != "building") throw new StorageV19Exception("generationNotReady");
        long generationId = generation.Id;
        if (vector.Dim != generation.Identity.Dims) throw new StorageV19Exception("invalidVector");
        var chunk = c.QuerySingleOrDefault("""
            SELECT c.source_id,c.revision_id,s.notebook_id FROM source_chunks c JOIN sources s ON s.id=c.source_id WHERE c.id=$chunkId
            """, new { chunkId }, tx) ?? throw new StorageV19Exception("notFound");
        if ((long)chunk.notebook_id != generation.NotebookId) throw new StorageV19Exception("notebookMismatch");
        if (!c.ExecuteScalar<bool>("""
            SELECT EXISTS(SELECT 1 FROM index_generation_manifest WHERE generation_id=$generationId
                AND source_id=$sourceId AND revision_id=$revisionId)
            """, new { generationId, sourceId = (long)chunk.source_id, revisionId = (long?)chunk.revision_id }, tx))
            throw new StorageV19Exception("staleRevision");
        byte[] bytes;
        if (generation.Identity.Normalization == "l2")
        {
            double squared = 0;
            foreach (float value in vector.Values)
            {
                if (!float.IsFinite(value)) throw new StorageV19Exception("invalidVector");
                squared += (double)value * value;
            }
            if (squared == 0 || !double.IsFinite(squared)) throw new StorageV19Exception("invalidVector");
            double norm = Math.Sqrt(squared);
            bytes = new EmbeddingVector(vector.Values.Select(value => (float)(value / norm)).ToArray()).ToBytes();
        }
        else bytes = vector.ToBytes();
        c.Execute("""
            INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES($chunkId,$generationId,$bytes)
            ON CONFLICT(chunk_id,generation_id) DO UPDATE SET embedding=excluded.embedding
            """, new { chunkId, generationId, bytes }, tx);
    }

    internal static void Activate(SqliteConnection c, SqliteTransaction tx, long id, JobFence? fence, long now)
    {
        var generation = RequireBuilding(c, tx, id);
        if (fence is not null)
        {
            var job = RevisionJobSQL.ValidateFence(c, tx, fence, now);
            if (job is null) throw new StorageV19Exception("staleLease");
            if (job.Draft.Kind != "embed" || job.Draft.Target != $"generation:{id}")
                throw new StorageV19Exception("invalidValue");
        }
        foreach (var entry in ReadManifest(c, tx, id))
        {
            var source = c.QuerySingleOrDefault("SELECT notebook_id,current_revision,published_revision_id,availability,eligible FROM sources WHERE id=$sourceId",
                new { sourceId = entry.SourceId }, tx);
            var revision = RevisionJobSQL.ReadRevision(c, tx, entry.RevisionId);
            if (source is null || revision is null || (long)source.notebook_id != generation.NotebookId || revision.SourceId != entry.SourceId ||
                entry.State == "pending" || entry.State == "excluded" && string.IsNullOrWhiteSpace(entry.Reason))
                throw new StorageV19Exception("generationNotReady");
            if (entry.State == "done" && (!CompleteVectors(c, tx, id, entry.RevisionId, generation.Identity.Dims) ||
                (string)source.availability == "present" && (long)source.eligible == 1 && (long?)source.published_revision_id != entry.RevisionId))
                throw new StorageV19Exception("generationNotReady");
        }
        if (c.ExecuteScalar<bool>("""
            SELECT EXISTS(SELECT 1 FROM sources s WHERE s.notebook_id=$notebookId AND s.availability='present'
                AND s.eligible=1 AND s.current_revision IS NOT NULL
                AND NOT EXISTS(SELECT 1 FROM index_generation_manifest m WHERE m.generation_id=$id
                    AND m.source_id=s.id AND m.revision_id=s.current_revision))
            """, new { id, notebookId = generation.NotebookId }, tx))
            throw new StorageV19Exception("generationNotReady");
        c.Execute("UPDATE index_generations SET state='retired' WHERE notebook_id=$notebookId AND state='active'",
            new { notebookId = generation.NotebookId }, tx);
        if (c.Execute("UPDATE index_generations SET state='active',activated_at=$created WHERE id=$id AND state='building'",
            new { id, created = SqliteDate.ToDb(DateTimeOffset.FromUnixTimeSeconds(now).UtcDateTime) }, tx) != 1)
            throw new StorageV19Exception("generationNotReady");
        if (fence is not null && !RevisionJobSQL.CompleteJob(c, tx, fence, now))
            throw new StorageV19Exception("staleLease");
    }

    internal static void CopyUnchangedVectors(SqliteConnection c, SqliteTransaction tx, long from, long to, long? excludingChunkId)
    {
        var source = Read(c, tx, from) ?? throw new StorageV19Exception("notFound");
        var target = RequireBuilding(c, tx, to);
        if (source.NotebookId != target.NotebookId) throw new StorageV19Exception("notebookMismatch");
        if (source.Identity != target.Identity) throw new StorageV19Exception("invalidVector");
        c.Execute("""
            INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding)
            SELECT old.chunk_id,$to,old.embedding FROM chunk_embeddings old
            JOIN source_chunks chunk ON chunk.id=old.chunk_id
            JOIN index_generation_manifest old_manifest ON old_manifest.generation_id=$from
                AND old_manifest.source_id=chunk.source_id AND old_manifest.revision_id=chunk.revision_id
            JOIN index_generation_manifest new_manifest ON new_manifest.generation_id=$to
                AND new_manifest.source_id=old_manifest.source_id AND new_manifest.revision_id=old_manifest.revision_id
            WHERE old.generation_id=$from AND ($excludingChunkId IS NULL OR old.chunk_id<>$excludingChunkId)
                AND length(old.embedding)=$bytes
            ON CONFLICT(chunk_id,generation_id) DO NOTHING
            """, new { from, to, excludingChunkId, bytes = (long)target.Identity.Dims * sizeof(float) }, tx);
        // Carried vectors stay dedup sources in the successor (embedding-plan-v1 §5), as provider vectors.
        c.Execute("""
            INSERT OR IGNORE INTO generation_text_hashes(generation_id,chunk_id,text_hash,copied)
            SELECT $to,d.chunk_id,d.text_hash,0 FROM generation_text_hashes d
            JOIN chunk_embeddings e ON e.chunk_id=d.chunk_id AND e.generation_id=$to
            WHERE d.generation_id=$from
            """, new { from, to }, tx);
        foreach (var entry in ReadManifest(c, tx, to).Where(entry => entry.State != "excluded"))
        {
            bool published = c.ExecuteScalar<bool>("SELECT EXISTS(SELECT 1 FROM sources WHERE id=$sourceId AND published_revision_id=$revisionId)",
                new { sourceId = entry.SourceId, revisionId = entry.RevisionId }, tx);
            string state = published && CompleteVectors(c, tx, to, entry.RevisionId, target.Identity.Dims) ? "done" : "pending";
            c.Execute("UPDATE index_generation_manifest SET state=$state,reason=NULL WHERE generation_id=$to AND source_id=$sourceId",
                new { to, sourceId = entry.SourceId, state }, tx);
        }
    }

    /// <summary>Every embeddable chunk (<c>embedding-plan-v1</c> §3) of the revision has a vector of the generation's width.</summary>
    private static bool CompleteVectors(SqliteConnection c, SqliteTransaction tx, long generationId, long revisionId, int dims)
        => !c.ExecuteScalar<bool>($"""
            SELECT EXISTS(SELECT 1 FROM source_chunks c JOIN sources s ON s.id=c.source_id WHERE c.revision_id=$revisionId
                AND {EmbeddingPlan.EmbeddableSql}
                AND NOT EXISTS(SELECT 1 FROM chunk_embeddings e WHERE e.chunk_id=c.id AND e.generation_id=$generationId AND length(e.embedding)=$bytes))
            """, new { generationId, revisionId, bytes = (long)dims * sizeof(float) }, tx);

    private static IndexGeneration RequireBuilding(SqliteConnection c, SqliteTransaction tx, long id)
    {
        var generation = Read(c, tx, id) ?? throw new StorageV19Exception("notFound");
        if (generation.State != "building") throw new StorageV19Exception("generationNotReady");
        return generation;
    }

    private static void ValidateIdentity(GenerationIdentity identity)
    {
        if (identity.Dims <= 0 || identity.Normalization is not ("legacy" or "l2") ||
            new[] { identity.ProviderId, identity.EndpointRevision, identity.Model, identity.QueryFormatVersion,
                identity.DocFormatVersion, identity.ChunkerVersion }.Any(string.IsNullOrWhiteSpace))
            throw new StorageV19Exception("invalidValue");
    }
}

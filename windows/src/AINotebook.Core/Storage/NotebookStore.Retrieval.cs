using System.Buffers.Binary;
using System.Text.Json;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    public RetrievalReadStore MakeRetrievalReader() => new(this);

    /// <summary>
    /// Keys resident matrices (retrieval-resident-v1 §2). One per opened store, so a reopened or
    /// replaced file (backup restore) never inherits rows loaded under ids its own AUTOINCREMENT
    /// sequences may hand out again.
    /// </summary>
    internal string RetrievalInstanceId { get; } = Guid.NewGuid().ToString();

    /// <summary>embedding-raw-format-v2 §3: the one-line path header of each chunk's source.</summary>
    internal IReadOnlyDictionary<long, string> EmbeddingHeaders(IReadOnlyList<long> chunkIds)
    {
        if (chunkIds.Count == 0) return new Dictionary<long, string>();
        lock (Gate)
            return Connection.Query("""
                SELECT c.id,s.rel_path,s.title FROM source_chunks c JOIN sources s ON s.id=c.source_id
                WHERE c.id IN (SELECT CAST(value AS INTEGER) FROM json_each($ids))
                """, new { ids = JsonSerializer.Serialize(chunkIds) })
                .ToDictionary(row => (long)row.id, row => AINotebook.Core.Providers.RawEmbeddingFormat.Header((string?)row.rel_path, (string)row.title));
    }
}

/// <summary>
/// Materialized retrieval reads. Every connection operation holds the store gate;
/// vector decoding is deliberately performed after the gate has been released.
/// </summary>
public sealed class RetrievalReadStore
{
    private const int MaximumPageRows = 1024;
    private const int MaximumPageBytes = 8_388_608;
    private readonly NotebookStore _store;
    private long _discardedVectorRows;
    private int _maximumVectorPagePayloadBytes;
    private int _oversizedVector;

    internal RetrievalReadStore(NotebookStore store) => _store = store;

    public long DiscardedVectorRows => Interlocked.Read(ref _discardedVectorRows);
    public int MaxVectorPagePayloadBytes => Volatile.Read(ref _maximumVectorPagePayloadBytes);
    public bool OversizedVector => Volatile.Read(ref _oversizedVector) != 0;
    internal Action? BeforeEvidenceRead { get; set; }

    private const string ScopePredicate = """
        s.notebook_id=$nb AND s.availability='present' AND s.eligible=1
        AND s.id IN (SELECT CAST(value AS INTEGER) FROM json_each($initialSourceIds))
        AND ($all=1 OR s.id IN (SELECT CAST(value AS INTEGER) FROM json_each($sourceIds))
                    OR s.folder_id IN (SELECT CAST(value AS INTEGER) FROM json_each($folderIds)))
        """;

    /// <summary>The scope predicate without initial-scope membership (checked in memory by the caller).</summary>
    private const string CurrentScopePredicate = """
        s.notebook_id=$nb AND s.availability='present' AND s.eligible=1
        AND ($all=1 OR s.id IN (SELECT CAST(value AS INTEGER) FROM json_each($sourceIds))
                    OR s.folder_id IN (SELECT CAST(value AS INTEGER) FROM json_each($folderIds)))
        """;

    private const string VectorJoins = """
        FROM chunk_embeddings ce
        JOIN source_chunks sc ON sc.id=ce.chunk_id
        JOIN index_generation_manifest m ON m.generation_id=ce.generation_id
            AND m.source_id=sc.source_id AND m.revision_id=sc.revision_id AND m.state='done'
        JOIN sources s ON s.id=sc.source_id
        WHERE ce.generation_id=$generation AND s.notebook_id=$nb
            AND s.availability='present' AND s.eligible=1
            AND (sc.source_id,sc.revision_id) IN (SELECT CAST(json_extract(value,'$.sourceId') AS INTEGER),
                CAST(json_extract(value,'$.revisionId') AS INTEGER) FROM json_each($vectorPairs))
        """;

    // A pinned (source, revision) list is an uncorrelated row-value IN operand: SQLite
    // materializes it once per statement (ephemeral index + bloom filter). A JOIN on a json_each
    // CTE with json_extract in the ON clause re-parses the whole pin per joined row instead.
    /// <summary>First bm25 window of the lexical branch; widened 8x while filters leave too few rows.</summary>
    internal static int LexicalWindow(int limit) => Math.Max(256, limit * 8);

    private static DynamicParameters Parameters(ResolvedRetrievalScope snapshot)
    {
        var parameters = new DynamicParameters();
        parameters.Add("nb", snapshot.Pin.NotebookId);
        parameters.Add("all", snapshot.IsAll);
        parameters.Add("initialSourceIds", snapshot.InitialSourceIdsJson);
        parameters.Add("sourceIds", snapshot.SourceIdsJson);
        parameters.Add("folderIds", snapshot.FolderIdsJson);
        parameters.Add("published", snapshot.PublishedPairsJson);
        parameters.Add("vectorPairs", snapshot.VectorPairsJson);
        parameters.Add("generation", snapshot.Pin.GenerationId);
        return parameters;
    }

    private ResolvedRetrievalScope Validate(RetrievalOperation operation)
    {
        operation.Validate();
        if (!StringComparer.Ordinal.Equals(operation.Snapshot.Store.RetrievalDatabaseId, _store.RetrievalDatabaseId))
            throw new RetrievalException("revisionMismatch");
        return operation.Snapshot;
    }

    private void Trace(string sql) => _store.RetrievalStatementExecuted?.Invoke(sql);

    public IReadOnlyList<ChunkReference> Lexical(ResolvedRetrievalScope snapshot, string? expression, int limit)
    {
        using var operation = snapshot.AcquireOperation();
        Validate(operation);
        if (expression is null || limit <= 0) return Array.Empty<ChunkReference>();
        return Lexical(operation, expression, limit, PermittedSourceIds(operation));
    }

    internal IReadOnlyList<ChunkReference> Lexical(RetrievalOperation operation,
        string? expression, int limit, IReadOnlySet<long> permittedSources)
    {
        var snapshot = Validate(operation);
        if (expression is null || limit <= 0 || permittedSources.Count == 0)
            return Array.Empty<ChunkReference>();
        // bm25 is computed once per FTS match inside the materialized window; only the window's
        // rows are joined and filtered. (score, rowid) is the global order and rowid = chunk id,
        // so the filtered prefix of a window holding >= limit rows, or of an exhausted window,
        // equals the filtered prefix of the full match set.
        string sql = """
            WITH hits AS MATERIALIZED (
                SELECT rowid AS id,bm25(chunks_fts) AS score FROM chunks_fts
                WHERE chunks_fts MATCH $query ORDER BY score,rowid LIMIT $window),
            picked AS (
                SELECT hits.score,sc.id,sc.source_id,sc.revision_id,sc.ord
                FROM hits JOIN source_chunks sc ON sc.id=hits.id
                JOIN sources s ON s.id=sc.source_id
                WHERE (sc.source_id,sc.revision_id) IN (SELECT CAST(json_extract(value,'$.sourceId') AS INTEGER),
                    CAST(json_extract(value,'$.revisionId') AS INTEGER) FROM json_each($published))
                AND
            """ + "\n" + ScopePredicate + "\n" + """

                AND s.id IN (SELECT CAST(value AS INTEGER) FROM json_each($permittedSources))
                ORDER BY hits.score,sc.id LIMIT $limit)
            SELECT (SELECT count(*) FROM hits) AS window_rows,picked.id,picked.source_id,picked.revision_id,picked.ord
            FROM (SELECT 1) LEFT JOIN picked ON 1 ORDER BY picked.score,picked.id
            """;
        var parameters = Parameters(snapshot);
        parameters.Add("query", expression);
        parameters.Add("limit", limit);
        parameters.Add("permittedSources", JsonSerializer.Serialize(permittedSources.Order()));
        long window = LexicalWindow(limit);
        while (true)
        {
            parameters.Add("window", window);
            List<ChunkReference> rows = new();
            long windowRows = 0;
            lock (_store.Gate)
            {
                Trace(sql);
                foreach (var row in _store.Connection.Query(sql, parameters))
                {
                    windowRows = (long)row.window_rows;
                    if (row.id is not null) rows.Add(ReadReference(row));
                }
            }
            if (rows.Count >= limit || windowRows < window || window < 0) return rows;
            window = window > long.MaxValue / 64 ? -1 : window * 8;
        }
    }

    public int VectorCount(ResolvedRetrievalScope snapshot)
    {
        using var operation = snapshot.AcquireOperation();
        return VectorCount(operation);
    }

    internal int VectorCount(RetrievalOperation operation)
    {
        var snapshot = Validate(operation);
        if (!TryVectorWidth(snapshot, out _)) return 0;
        string sql = "SELECT count(*)\n" + VectorJoins;
        lock (_store.Gate)
        {
            Trace(sql);
            return _store.Connection.ExecuteScalar<int>(sql, Parameters(snapshot));
        }
    }

    internal RawVectorPage RawVectorPage(RetrievalOperation operation, long afterChunkId, int rowLimit)
    {
        var snapshot = Validate(operation);
        if (!TryVectorWidth(snapshot, out int byteWidth))
            return new(Array.Empty<RawVectorRow>(), afterChunkId, true, 0);
        int limit = Math.Min(Math.Min(Math.Max(rowLimit, 1), MaximumPageRows), MaximumPageBytes / byteWidth);
        string sql = """
            SELECT sc.id,sc.source_id,sc.revision_id,sc.ord,
                CASE WHEN length(ce.embedding)=$byteWidth THEN ce.embedding ELSE NULL END AS embedding
            """ + "\n" + VectorJoins + "\nAND ce.chunk_id>$after ORDER BY ce.chunk_id LIMIT $limit";
        var parameters = Parameters(snapshot);
        parameters.Add("byteWidth", byteWidth);
        parameters.Add("after", afterChunkId);
        parameters.Add("limit", limit);
        RawVectorRow[] rows;
        int payloadBytes;
        lock (_store.Gate)
        {
            Trace(sql);
            rows = _store.Connection.Query(sql, parameters)
                .Select(row => new RawVectorRow(ReadReference(row), (byte[]?)row.embedding)).ToArray();
            payloadBytes = rows.Sum(row => row.Blob?.Length ?? 0);
        }
        int previous;
        do { previous = Volatile.Read(ref _maximumVectorPagePayloadBytes); }
        while (payloadBytes > previous && Interlocked.CompareExchange(
            ref _maximumVectorPagePayloadBytes, payloadBytes, previous) != previous);
        return new(rows, rows.Length == 0 ? afterChunkId : rows[^1].Reference.ChunkId,
            rows.Length < limit, payloadBytes);
    }

    /// <summary>
    /// Resident-matrix loads read a generation's rows of the given (source, revision) pairs by
    /// identity only: availability, eligibility and the manifest are the pin's business, so a pair
    /// loaded once stays valid for every later pin that names it (retrieval-resident-v1 §2). Few
    /// pairs are read through the revision index, many by one pass over the generation.
    /// </summary>
    internal const int ResidentPairDriverLimit = 64;

    private static string ResidentFrom(int pairs) => pairs <= ResidentPairDriverLimit
        ? """
          FROM source_chunks sc JOIN chunk_embeddings ce ON ce.chunk_id=sc.id AND ce.generation_id=$generation
          WHERE sc.revision_id IN (SELECT CAST(json_extract(value,'$.revisionId') AS INTEGER) FROM json_each($pairs))
            AND (sc.source_id,sc.revision_id) IN (SELECT CAST(json_extract(value,'$.sourceId') AS INTEGER),
                CAST(json_extract(value,'$.revisionId') AS INTEGER) FROM json_each($pairs))
          """
        : """
          FROM chunk_embeddings ce JOIN source_chunks sc ON sc.id=ce.chunk_id
          WHERE ce.generation_id=$generation AND (sc.source_id,sc.revision_id) IN (SELECT CAST(json_extract(value,'$.sourceId') AS INTEGER),
                CAST(json_extract(value,'$.revisionId') AS INTEGER) FROM json_each($pairs))
          """;

    /// <summary>The driving table's id column, so the page order is an index order (no sort).</summary>
    private static string ResidentOrder(int pairs) => pairs <= ResidentPairDriverLimit ? "sc.id" : "ce.chunk_id";

    internal static string PairsJson(IReadOnlyDictionary<long, long> pairs)
        => JsonSerializer.Serialize(pairs.OrderBy(p => p.Key).Select(p => new { sourceId = p.Key, revisionId = p.Value }));

    internal int ResidentCount(RetrievalOperation operation, IReadOnlyDictionary<long, long> pairs)
    {
        var snapshot = Validate(operation);
        if (snapshot.Pin.GenerationId is not long generation || pairs.Count == 0) return 0;
        string sql = "SELECT count(*) " + ResidentFrom(pairs.Count);
        lock (_store.Gate)
        {
            Trace(sql);
            return _store.Connection.ExecuteScalar<int>(sql, new { generation, pairs = PairsJson(pairs) });
        }
    }

    internal RawVectorPage ResidentPage(RetrievalOperation operation, int pairCount, string pairsJson, long afterChunkId, int rowLimit)
    {
        var snapshot = Validate(operation);
        if (snapshot.Pin.GenerationId is not long generation || pairCount == 0 || !TryVectorWidth(snapshot, out int byteWidth))
            return new(Array.Empty<RawVectorRow>(), afterChunkId, true, 0);
        int limit = Math.Min(Math.Min(Math.Max(rowLimit, 1), MaximumPageRows), MaximumPageBytes / byteWidth);
        string order = ResidentOrder(pairCount);
        string sql = """
            SELECT sc.id,sc.source_id,sc.revision_id,sc.ord,
                CASE WHEN length(ce.embedding)=$byteWidth THEN ce.embedding ELSE NULL END AS embedding
            """ + "\n" + ResidentFrom(pairCount) + $"\nAND {order}>$after ORDER BY {order} LIMIT $limit";
        RawVectorRow[] rows;
        int payloadBytes;
        lock (_store.Gate)
        {
            Trace(sql);
            rows = _store.Connection.Query(sql, new { generation, pairs = pairsJson, byteWidth, after = afterChunkId, limit })
                .Select(row => new RawVectorRow(ReadReference(row), (byte[]?)row.embedding)).ToArray();
            payloadBytes = rows.Sum(row => row.Blob?.Length ?? 0);
        }
        return new(rows, rows.Length == 0 ? afterChunkId : rows[^1].Reference.ChunkId, rows.Length < limit, payloadBytes);
    }

    private bool TryVectorWidth(ResolvedRetrievalScope snapshot, out int byteWidth)
    {
        byteWidth = 0;
        if (snapshot.Pin.GenerationId is null) return false;
        long width = (long)(snapshot.Pin.Dims ?? 0) * sizeof(float);
        if (width <= 0 || width > MaximumPageBytes)
        {
            Volatile.Write(ref _oversizedVector, 1);
            return false;
        }
        byteWidth = checked((int)width);
        return true;
    }

    /// <summary>Decodes one bounded page outside SQLite and records rejected payloads.</summary>
    internal IReadOnlyList<VectorRow> DecodeVectorPage(RawVectorPage page, int dims)
    {
        var result = new List<VectorRow>(page.Rows.Count);
        foreach (var row in page.Rows)
        {
            if (row.Blob is not byte[] bytes || dims <= 0 || bytes.LongLength != (long)dims * sizeof(float))
            {
                Interlocked.Increment(ref _discardedVectorRows);
                continue;
            }
            var values = new float[dims];
            bool valid = true;
            for (int i = 0; i < dims; i++)
            {
                float value = BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(i * sizeof(float), sizeof(float))));
                if (!float.IsFinite(value)) { valid = false; break; }
                values[i] = value;
            }
            if (valid) result.Add(new(row.Reference, values));
            else Interlocked.Increment(ref _discardedVectorRows);
        }
        return result;
    }

    public IReadOnlyList<VectorRow> VectorPage(ResolvedRetrievalScope snapshot, long afterChunkId, int limit)
    {
        using var operation = snapshot.AcquireOperation();
        Validate(operation);
        if (limit <= 0 || !TryVectorWidth(snapshot, out int byteWidth)) return Array.Empty<VectorRow>();
        int wanted = Math.Min(Math.Min(limit, MaximumPageRows), MaximumPageBytes / byteWidth);
        var permitted = PermittedSourceIds(operation).ToHashSet();
        if (permitted.Count == 0) return Array.Empty<VectorRow>();
        var result = new List<VectorRow>(wanted);
        long cursor = afterChunkId;
        bool exhausted = false;
        while (result.Count < wanted && !exhausted && permitted.Count > 0)
        {
            var page = RawVectorPage(operation, cursor, wanted - result.Count);
            foreach (var row in DecodeVectorPage(page, snapshot.Pin.Dims!.Value))
                if (permitted.Contains(row.Reference.SourceId)) result.Add(row);
            cursor = page.LastScannedChunkId;
            exhausted = page.Exhausted;
            // Revocation may free a result slot; continue from the raw cursor so
            // such a removal cannot make a nonterminal page look like EOF.
            permitted.IntersectWith(PermittedSourceIds(operation));
            result.RemoveAll(row => !permitted.Contains(row.Reference.SourceId));
        }
        return result;
    }

    public IReadOnlySet<long> PermittedSourceIds(ResolvedRetrievalScope snapshot)
    {
        using var operation = snapshot.AcquireOperation();
        return PermittedSourceIds(operation);
    }

    internal IReadOnlySet<long> PermittedSourceIds(RetrievalOperation operation)
    {
        var snapshot = Validate(operation);
        string sql = "SELECT s.id FROM sources s WHERE " + ScopePredicate + " ORDER BY s.id";
        lock (_store.Gate)
        {
            Trace(sql);
            return _store.Connection.Query<long>(sql, Parameters(snapshot)).ToHashSet();
        }
    }

    public IReadOnlyList<ChunkEvidenceRow> EvidenceRows(ResolvedRetrievalScope snapshot, IReadOnlyList<ChunkReference> references)
    {
        using var operation = snapshot.AcquireOperation();
        return EvidenceRows(operation, references);
    }

    internal IReadOnlyList<ChunkEvidenceRow> EvidenceRows(RetrievalOperation operation, IReadOnlyList<ChunkReference> references)
    {
        var snapshot = Validate(operation);
        BeforeEvidenceRead?.Invoke();
        if (references.Count == 0) return Array.Empty<ChunkEvidenceRow>();
        var parameters = Parameters(snapshot);
        parameters.Add("requests", JsonSerializer.Serialize(references.Select(reference => new
        {
            chunkId = reference.ChunkId, sourceId = reference.SourceId, revisionId = reference.RevisionId
        })));
        string sql = """
            SELECT sc.id,sc.source_id,sc.revision_id,sc.ord,sc.text,sc.char_start,sc.char_end,sc.page_hint,
                CAST(json_extract(request.value,'$.sourceId') AS INTEGER) requested_source,
                CAST(json_extract(request.value,'$.revisionId') AS INTEGER) requested_revision,
                CASE WHEN
            """ + "\n" + ScopePredicate + "\n" + """

                THEN 1 ELSE 0 END permitted
            FROM json_each($requests) request
            JOIN source_chunks sc ON sc.id=CAST(json_extract(request.value,'$.chunkId') AS INTEGER)
            JOIN sources s ON s.id=sc.source_id
            ORDER BY CAST(request.key AS INTEGER)
            """;
        lock (_store.Gate)
        {
            using var transaction = _store.Connection.BeginTransaction(deferred: true);
            Trace(sql);
            var chunks = _store.Connection.Query(sql, parameters, transaction).ToArray();
            foreach (var chunk in chunks)
                if ((long)chunk.source_id != (long)chunk.requested_source || (long?)chunk.revision_id != (long)chunk.requested_revision)
                    throw new RetrievalException("revisionMismatch");
            var allowed = chunks.Where(chunk => (long)chunk.permitted == 1 &&
                IsPinned(snapshot, (long)chunk.source_id, (long?)chunk.revision_id)).ToArray();
            if (allowed.Length == 0) { transaction.Commit(); return Array.Empty<ChunkEvidenceRow>(); }
            const string revisionSql = """
                SELECT id,canonical_text,chunker_version FROM source_revisions
                WHERE id IN (SELECT CAST(value AS INTEGER) FROM json_each($revisionIds))
                """;
            Trace(revisionSql);
            var canonical = _store.Connection.Query(revisionSql, new
            {
                revisionIds = JsonSerializer.Serialize(allowed.Select(chunk => (long)chunk.revision_id).Distinct().Order())
            }, transaction).ToDictionary(row => (long)row.id,
                row => (Text: (string)row.canonical_text, Version: (int)(long)row.chunker_version));
            var result = new List<ChunkEvidenceRow>(allowed.Length);
            foreach (var chunk in allowed)
            {
                var revision = canonical[(long)chunk.revision_id];
                result.Add(new(ReadReference(chunk), revision.Text, (string)chunk.text,
                    (int?)(long?)chunk.char_start, (int?)(long?)chunk.char_end,
                    (int?)(long?)chunk.page_hint, revision.Version));
            }
            transaction.Commit();
            return result;
        }
    }

    private static bool IsPinned(ResolvedRetrievalScope snapshot, long sourceId, long? revisionId)
        => revisionId is long revision &&
           (snapshot.Pin.LexicalRevisions.TryGetValue(sourceId, out long lexical) && lexical == revision ||
            snapshot.Pin.VectorRevisions.TryGetValue(sourceId, out long vector) && vector == revision);

    public IReadOnlyList<ChunkReference> NeighbourReferences(ResolvedRetrievalScope snapshot, ChunkReference center, int radius)
    {
        using var operation = snapshot.AcquireOperation();
        return NeighbourReferences(operation, center, radius);
    }

    internal IReadOnlyList<ChunkReference> NeighbourReferences(RetrievalOperation operation, ChunkReference center, int radius)
    {
        var snapshot = Validate(operation);
        if (radius < 0) throw new RetrievalException("invalidRadius");
        // Initial-scope membership is a set lookup here: binding the whole id list would make
        // SQLite materialize it for every one of the pack's neighbour reads.
        if (radius == 0 || !snapshot.InitialSourceIdSet.Contains(center.SourceId)
            || !snapshot.Pin.LexicalRevisions.TryGetValue(center.SourceId, out long revision))
            return Array.Empty<ChunkReference>();
        string sql = """
            SELECT sc.id,sc.source_id,sc.revision_id,sc.ord
            FROM source_chunks sc JOIN sources s ON s.id=sc.source_id
            WHERE sc.source_id=$source AND sc.revision_id=$publishedRevision
                AND sc.ord BETWEEN $firstOrd AND $lastOrd AND sc.id<>$centerChunk AND
            """ + "\n" + CurrentScopePredicate + "\nORDER BY sc.ord,sc.id";
        var parameters = Parameters(snapshot);
        parameters.Add("source", center.SourceId);
        parameters.Add("publishedRevision", revision);
        parameters.Add("firstOrd", Math.Max(0L, (long)center.Ord - radius));
        parameters.Add("lastOrd", (long)center.Ord + radius);
        parameters.Add("centerChunk", center.ChunkId);
        lock (_store.Gate)
        {
            Trace(sql);
            return _store.Connection.Query(sql, parameters).Select(ReadReference).ToArray();
        }
    }

    /// <summary>The lowest-ordinal chunk of each given (source, published revision), keyed by source.</summary>
    internal IReadOnlyDictionary<long, ChunkReference> FirstChunks(RetrievalOperation operation, IReadOnlyDictionary<long, long> revisions)
    {
        Validate(operation);
        if (revisions.Count == 0) return new Dictionary<long, ChunkReference>();
        const string sql = """
            SELECT sc.id,sc.source_id,sc.revision_id,sc.ord FROM json_each($pairs) p
            JOIN source_chunks sc ON sc.revision_id=CAST(json_extract(p.value,'$.revisionId') AS INTEGER)
              AND sc.source_id=CAST(json_extract(p.value,'$.sourceId') AS INTEGER)
            WHERE sc.ord=(SELECT min(c.ord) FROM source_chunks c WHERE c.revision_id=sc.revision_id)
            """;
        lock (_store.Gate)
        {
            Trace(sql);
            return _store.Connection.Query(sql, new { pairs = PairsJson(revisions) }).Select(ReadReference)
                .GroupBy(r => r.SourceId).ToDictionary(g => g.Key, g => g.OrderBy(r => r.ChunkId).First());
        }
    }

    public IReadOnlyList<ScopedSource> Metadata(ResolvedRetrievalScope snapshot)
    {
        using var operation = snapshot.AcquireOperation();
        return Metadata(operation);
    }

    internal IReadOnlyList<ScopedSource> Metadata(RetrievalOperation operation)
    {
        var snapshot = Validate(operation);
        string sql = """
            SELECT s.id,s.folder_id,s.rel_path,s.title FROM sources s WHERE
            """ + "\n" + ScopePredicate + "\n" + """

            AND s.id IN (SELECT CAST(json_extract(value,'$.sourceId') AS INTEGER) FROM json_each($published))
            ORDER BY s.id
            """;
        lock (_store.Gate)
        {
            Trace(sql);
            return _store.Connection.Query(sql, Parameters(snapshot)).Select(row => new ScopedSource(
                (long)row.id, (long?)row.folder_id, (string?)row.rel_path, (string)row.title,
                snapshot.Pin.LexicalRevisions[(long)row.id],
                snapshot.Pin.VectorRevisions.TryGetValue((long)row.id, out long revision) ? revision : null)).ToArray();
        }
    }

    public ulong CurrentEpoch(ResolvedRetrievalScope snapshot)
    {
        using var operation = snapshot.AcquireOperation();
        return CurrentEpoch(operation);
    }

    internal ulong CurrentEpoch(RetrievalOperation operation)
    {
        Validate(operation);
        return _store.RefreshRetrievalEpoch();
    }

    public ulong ObservedEpoch() => _store.RetrievalObservedEpoch();

    private static ChunkReference ReadReference(dynamic row)
        => new((long)row.id, (long)row.source_id, (long)row.revision_id, checked((int)(long)row.ord));
}

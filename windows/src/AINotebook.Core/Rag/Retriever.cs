using System.Buffers.Binary;
using System.Runtime.ExceptionServices;
using System.Text;
using AINotebook.Core.Eval;
using AINotebook.Core.Language;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

/// <summary>
/// One scoped, revision-pinned hybrid query: capture the model key once, resolve the
/// scope and pinned generation in one read transaction, embed exactly one question
/// through an immutable session, then select lexical and vector branches with their
/// own fetchK and fuse the complete integer-RRF union.
/// </summary>
public sealed class Retriever
{
    private const int PageRows = 1024;
    private const long MaximumVectorBytes = 8_388_608;
    private static readonly Lazy<UnicodeTables> BundledTables = new(UnicodeTables.LoadBundled);

    private readonly NotebookStore _store;
    private readonly IEmbeddingProducing _client;
    private readonly Func<string> _modelGetter;
    private readonly VectorMatrixCache _cache;
    private readonly UnicodeTables? _tables;
    private FtsQueryBuilder? _fts;
    // Value source for omitted typed fetchK (WP7 tuning); never global mutable configuration.
    private readonly Func<int> _defaultFetchK;

    public string Model => _modelGetter();
    public int RrfK { get; }

    /// <summary>Test seam: runs after each ranking pass, before the permission mask is rechecked.</summary>
    internal Action? AfterRankingPass { get; set; }

    // Backward-compatible overload: fixed model string.
    public Retriever(NotebookStore store, IEmbeddingProducing client, string model, int rrfK = 60)
        : this(store, client, () => model, rrfK) { }

    // Primary constructor: live model key via getter.
    public Retriever(NotebookStore store, IEmbeddingProducing client, Func<string> modelGetter, int rrfK = 60)
        : this(store, client, modelGetter, VectorMatrixCache.Shared, null, rrfK) { }

    /// <summary>Injects the matrix cache and Unicode tables (loaded lazily after the empty-scope guard).</summary>
    public Retriever(NotebookStore store, IEmbeddingProducing client, Func<string> modelGetter,
        VectorMatrixCache cache, UnicodeTables? tables, int rrfK = 60, Func<int>? defaultFetchK = null)
    {
        _defaultFetchK = defaultFetchK ?? (() => RagRuntimeTuning.Bundled().FetchK);
        _store = store;
        _client = client;
        _modelGetter = modelGetter;
        _cache = cache ?? throw new ArgumentNullException(nameof(cache));
        _tables = tables;
        RrfK = rrfK;
    }

    private FtsQueryBuilder Fts => _fts ??= new FtsQueryBuilder(_tables ?? BundledTables.Value);

    /// <summary>
    /// Scoped candidate pool. The caller owns the returned pool and must dispose it
    /// after copying evidence. An empty selection performs no SQL and no embedding.
    /// </summary>
    public async Task<PinnedRetrievalCandidates> SearchAsync(long notebookId, string query, RetrievalScope scope,
        int? fetchK = null, bool includeVectors = true, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentNullException.ThrowIfNull(scope);
        // An explicit value is validated before the empty-selection fast path; an omitted one is
        // resolved once, after it, so an empty selection reads no resource, SQL or provider.
        if (fetchK <= 0 || RrfK <= 0) throw new RetrievalException("invalidFetchK");
        ct.ThrowIfCancellationRequested();
        if (scope.IsEmptySelection) return PinnedRetrievalCandidates.Empty("disabled");
        int resolvedFetchK = fetchK ?? _defaultFetchK();
        if (resolvedFetchK <= 0) throw new RetrievalException("invalidFetchK");

        // The only model-settings read of this query; never re-read after a suspension.
        string modelKey = _modelGetter();
        var snapshot = ScopeResolver.Resolve(_store, notebookId, scope, modelKey)
            ?? throw new InvalidOperationException("A nonempty scope must resolve a snapshot.");
        try
        {
            var embedded = await EmbedQueryAsync(snapshot, query, includeVectors, ct).ConfigureAwait(false);
            return await SearchEmbeddedCoreAsync(snapshot, query, embedded.Vector, resolvedFetchK,
                embedded.Status, embedded.Failure, ct).ConfigureAwait(false);
        }
        catch
        {
            snapshot.Dispose();
            throw;
        }
    }

    /// <summary>
    /// WP7 timing seam: the snapshot already owns its pin and the question is already
    /// embedded. Ownership of the snapshot transfers to the returned pool on success;
    /// it is closed on failure, so callers must not close it after this call.
    /// </summary>
    public async Task<PinnedRetrievalCandidates> SearchEmbeddedAsync(ResolvedRetrievalScope snapshot, string query,
        float[]? queryVector, int? fetchK = null, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        try
        {
            ArgumentNullException.ThrowIfNull(query);
            int resolvedFetchK = fetchK ?? _defaultFetchK();
            if (resolvedFetchK <= 0 || RrfK <= 0) throw new RetrievalException("invalidFetchK");
            ct.ThrowIfCancellationRequested();
            string status;
            if (queryVector is null) status = "disabled";
            else if (snapshot.Generation is null) status = "noActiveGeneration";
            else if (Oversized(snapshot.Generation.Identity.Dims)) status = "oversizedVector";
            else if (!ValidQuery(queryVector, snapshot.Generation.Identity.Dims)) status = "invalidQueryVector";
            else status = "used";
            return await SearchEmbeddedCoreAsync(snapshot, query, status == "used" ? queryVector : null,
                resolvedFetchK, status, null, ct).ConfigureAwait(false);
        }
        catch
        {
            snapshot.Dispose();
            throw;
        }
    }

    /// <summary>
    /// Legacy chat adapter: null scope is all, an explicit empty filter is none. It
    /// copies revision-correct display snippets while the pool is pinned, then closes it.
    /// </summary>
    public async Task<IReadOnlyList<RetrievalHit>> SearchAsync(
        long notebookId, string query, int topK = 8,
        IReadOnlyCollection<long>? sourceIds = null, CancellationToken ct = default)
    {
        if (topK <= 0 || sourceIds is { Count: 0 }) return [];
        ct.ThrowIfCancellationRequested();
        using var pool = await SearchAsync(notebookId, query, LegacyScope(sourceIds), topK, true, ct).ConfigureAwait(false);
        // Historical contract: an ordinary provider failure fails the chat turn.
        if (pool.EmbeddingFailure is { } failure) ExceptionDispatchInfo.Throw(failure);
        return Hits(pool, pool.Fused.Take(topK).ToArray(), micro => micro / 1_000_000f);
    }

    /// <summary>
    /// Diagnostic per-branch fetch lists and their complete integer-RRF union from the
    /// production branches. Null scope is all, an explicit empty scope is none.
    /// Scores are the integer micro values, unchanged from WP1.
    /// </summary>
    public async Task<RetrievalCandidates> CandidatesAsync(long notebookId, string query,
        int fetchK = 32, IReadOnlyCollection<long>? sourceIds = null,
        bool includeVectors = true, CancellationToken ct = default)
    {
        if (fetchK <= 0 || RrfK <= 0) throw new EvalFailure("invalid_fetch_k");
        ct.ThrowIfCancellationRequested();
        if (sourceIds is { Count: 0 }) return new([], [], []);
        using var pool = await SearchAsync(notebookId, query, LegacyScope(sourceIds), fetchK, includeVectors, ct).ConfigureAwait(false);
        if (pool.EmbeddingFailure is { } failure) ExceptionDispatchInfo.Throw(failure);
        if (pool.Diagnostics.VectorStatus == "invalidQueryVector") throw new EvalFailure("invalid_embedding");
        if (pool.Diagnostics.VectorStatus is "used" or "legacyEndpointUnverified" && HasMalformedStoredVector(pool.Snapshot!))
            throw new EvalFailure("invalid_embedding");
        return new(Hits(pool, pool.Lexical, micro => micro), Hits(pool, pool.Vector, micro => micro),
            Hits(pool, pool.Fused, micro => micro));
    }

    // Shared pure boundary also permits testing malformed legacy vectors that v19
    // deliberately cannot activate together (notably mixed dimensions).
    internal static IReadOnlyList<RetrievalHit> RankEvalVectors(float[][] embedded,
        IReadOnlyList<StoredEmbedding> eligible, int? expectedDimensions, int fetchK)
    {
        if (embedded.Length != 1 || embedded[0].Length == 0 ||
            embedded[0].Any(v => !float.IsFinite(v)) || embedded[0].All(v => v == 0) ||
            expectedDimensions is int dims && dims != embedded[0].Length)
            throw new EvalFailure("invalid_embedding");
        var query = embedded[0];
        if (eligible.Any(e => e.Vector.Dim != query.Length ||
            e.Vector.Values.Any(v => !float.IsFinite(v)) || e.Vector.Values.All(v => v == 0)))
            throw new EvalFailure("invalid_embedding");
        return eligible.Select(e => new RetrievalHit(e.ChunkId, e.SourceId,
                Cosine.Similarity(query, e.Vector.Values), ""))
            .OrderByDescending(h => h.Score).ThenBy(h => h.ChunkId).Take(fetchK).ToArray();
    }

    private static RetrievalScope LegacyScope(IReadOnlyCollection<long>? sourceIds) => sourceIds is null
        ? new RetrievalScope.All()
        : new RetrievalScope.Selection(sourceIds.ToHashSet(), new HashSet<long>());

    private async Task<(float[]? Vector, string Status, Exception? Failure)> EmbedQueryAsync(
        ResolvedRetrievalScope snapshot, string query, bool includeVectors, CancellationToken ct)
    {
        if (!includeVectors) return (null, "disabled", null);
        if (snapshot.Generation is not { } generation) return (null, "noActiveGeneration", null);
        var identity = generation.Identity;
        // Decided before any session or provider request; no BLOB is ever read.
        if (Oversized(identity.Dims)) return (null, "oversizedVector", null);
        try
        {
            float[][] vectors;
            string status;
            if (_client is IEmbeddingSessionPreparing preparing)
            {
                var session = await preparing.PrepareEmbeddingAsync(identity, ct).ConfigureAwait(false);
                vectors = await session.EmbedAsync([query], ct).ConfigureAwait(false);
                status = session.Status ?? "used";
            }
            else if (EmbeddingQueryFormat.IsLegacyIdentity(identity))
            {
                // A direct client is supported only for legacy identities, with the whole stored key.
                vectors = await _client.EmbedAsync(identity.Model, [query], ct).ConfigureAwait(false);
                status = ProviderEmbeddingSession.LegacyEndpointUnverified;
            }
            else return (null, "embeddingSessionRequired", null);
            ct.ThrowIfCancellationRequested();
            return vectors is { Length: 1 } && ValidQuery(vectors[0], identity.Dims)
                ? (vectors[0], status, null) : (null, "invalidQueryVector", null);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (RetrievalException error) when (error.Code is "endpointRevisionMismatch" or "unsupportedQueryFormat"
            or "legacyProviderUnresolved" or "embeddingSessionRequired")
        {
            return (null, error.Code, null);
        }
        catch (Exception error)
        {
            // The lexical branch remains available; the legacy adapters may rethrow.
            return (null, "embeddingFailed", error);
        }
    }

    private async Task<PinnedRetrievalCandidates> SearchEmbeddedCoreAsync(ResolvedRetrievalScope snapshot,
        string query, float[]? queryVector, int fetchK, string status, Exception? failure, CancellationToken ct)
    {
        string? expression = string.IsNullOrWhiteSpace(query) ? null : Fts.MatchExpression(query);
        var reader = _store.MakeRetrievalReader();
        using var operation = snapshot.AcquireOperation();
        int dims = snapshot.Pin.Dims ?? 0;
        // The pinned generation is served from its resident, revision-checked binary16 matrix
        // (retrieval-resident-v1): loaded per pinned (source, revision) pair, kept across
        // queries, writes and builds; a matrix over budget streams bounded pages.
        bool vectors = queryVector is not null && snapshot.Generation is not null && snapshot.Pin.VectorRevisions.Count > 0;
        ResidentMatrixKey? key = vectors && snapshot.Pin.GenerationId is long generationKey
            ? new ResidentMatrixKey(_store.RetrievalDatabaseId, _store.RetrievalInstanceId, snapshot.Pin.NotebookId, generationKey, dims)
            : null;
        var ranked = await Task.Run(() => Rank(reader, operation, snapshot, query, expression,
            vectors ? queryVector : null, dims, key, fetchK, ct), ct).ConfigureAwait(false);
        long? generationId = snapshot.Pin.GenerationId;
        PinnedRetrievalCandidate[] Branch(IReadOnlyList<ChunkReference> branch) => branch
            .Select((reference, i) => new PinnedRetrievalCandidate(reference, generationId, 1_000_000L / ((long)RrfK + i + 1)))
            .ToArray();
        var fused = RetrievalRanking.Fuse(ranked.Lexical, ranked.Vector, ranked.Path, RrfK)
            .Select(row => new PinnedRetrievalCandidate(row.Reference, generationId, row.RrfMicro)).ToArray();
        var diagnostics = new RetrievalDiagnostics(status, ranked.InvalidVectors, vectors && ranked.Streamed,
            Math.Max(reader.MaxVectorPagePayloadBytes, ranked.PeakPageBytes));
        // Success transfers the revision lease into the pool.
        return new PinnedRetrievalCandidates(Branch(ranked.Lexical), Branch(ranked.Vector), fused, snapshot, diagnostics, failure,
            Branch(ranked.Path), ranked.PathMatches, ranked.PathInventory);
    }

    /// <summary>Fills one resident block from bounded pages; false when the pairs hold more rows than counted.</summary>
    private static bool FillResident(RetrievalReadStore reader, ResolvedRetrievalScope snapshot,
        IReadOnlyDictionary<long, long> pairs, ResidentBlock block, CancellationToken ct)
    {
        using var operation = snapshot.AcquireOperation();
        string json = RetrievalReadStore.PairsJson(pairs);
        long cursor = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var page = reader.ResidentPage(operation, pairs.Count, json, cursor, PageRows);
            if (!block.Append(page)) return false;
            cursor = page.LastScannedChunkId;
            if (page.Exhausted) return true;
        }
    }

    private (IReadOnlyList<ChunkReference> Lexical, IReadOnlyList<ChunkReference> Vector, IReadOnlyList<ChunkReference> Path,
        IReadOnlyList<PathMatch> PathMatches, bool PathInventory, int InvalidVectors, bool Streamed, long PeakPageBytes) Rank(
        RetrievalReadStore reader, RetrievalOperation operation, ResolvedRetrievalScope snapshot, string query, string? expression,
        float[]? queryVector, int dims, ResidentMatrixKey? key, int fetchK, CancellationToken ct)
    {
        var mask = reader.PermittedSourceIds(operation).ToHashSet();
        int? invalid = null;
        bool streamed = false;
        long peak = 0;
        // retrieval-paths-v1: rank the scope's published files by path/title/date matches once;
        // each pass keeps the still-permitted ones. Their first chunks form the path branch.
        var pathRanking = new PathMatcher(_tables ?? BundledTables.Value).Ranking(query, snapshot.Sources
            .Where(s => s.PublishedRevisionId is not null)
            .Select(s => new PathMatchFile(s.SourceId, s.RelPath, s.DisplayName, s.Mtime)).ToList());
        var pathMatches = pathRanking.Matches;
        IReadOnlyDictionary<long, ChunkReference> heads = pathMatches.Count == 0 ? new Dictionary<long, ChunkReference>()
            : reader.FirstChunks(operation, pathMatches.Take(fetchK)
                .Where(m => snapshot.Pin.LexicalRevisions.ContainsKey(m.SourceId))
                .ToDictionary(m => m.SourceId, m => snapshot.Pin.LexicalRevisions[m.SourceId]));
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var lexical = expression is null ? Array.Empty<ChunkReference>() : reader.Lexical(operation, expression, fetchK, mask);
            var path = pathMatches.Where(m => mask.Contains(m.SourceId) && heads.ContainsKey(m.SourceId))
                .Select(m => heads[m.SourceId]).Take(fetchK).ToArray();
            IReadOnlyList<ChunkReference> vector = Array.Empty<ChunkReference>();
            if (queryVector is not null)
            {
                ResidentScan? resident = null;
                if (key is not null && !streamed)
                {
                    var pins = snapshot.Pin.VectorRevisions;
                    var allowed = pins.Where(p => mask.Contains(p.Key)).ToDictionary(p => p.Key, p => p.Value);
                    resident = _cache.ResidentTopK(key, pins, allowed, queryVector, fetchK,
                        pairs =>
                        {
                            using var countOperation = snapshot.AcquireOperation();
                            return reader.ResidentCount(countOperation, pairs);
                        },
                        (pairs, block) => FillResident(reader, snapshot, pairs, block, ct), ct);
                }
                if (resident is not null)
                {
                    vector = resident.Scored.Select(row => row.Reference).ToArray();
                    invalid = resident.InvalidVectorCount;
                    peak = Math.Max(peak, resident.PeakPageBytes);
                }
                else
                {
                    streamed = true;
                    vector = Stream(reader, operation, queryVector, dims, mask, fetchK, out int streamedInvalid, ct);
                    invalid ??= streamedInvalid;
                }
            }
            AfterRankingPass?.Invoke();
            // Masks only shrink: revocations rerun both branches against the smaller mask;
            // newly admitted sources never join this turn.
            var current = reader.PermittedSourceIds(operation).Where(mask.Contains).ToHashSet();
            if (current.Count == mask.Count)
                return (lexical, vector, path, pathMatches.Where(m => mask.Contains(m.SourceId)).ToList(), pathRanking.Inventory,
                    invalid ?? 0, streamed, peak);
            mask = current;
        }
    }

    /// <summary>Bounded-page scan with one accumulator over the whole pinned generation.</summary>
    private static IReadOnlyList<ChunkReference> Stream(RetrievalReadStore reader, RetrievalOperation operation,
        float[] queryVector, int dims, IReadOnlySet<long> mask, int fetchK, out int invalid, CancellationToken ct)
    {
        invalid = 0;
        if (mask.Count == 0) return Array.Empty<ChunkReference>();
        var heap = MaskedVectorTopK.Create(queryVector, dims, mask, fetchK);
        if (heap is null) return Array.Empty<ChunkReference>();
        var scratch = new float[dims];
        long cursor = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var page = reader.RawVectorPage(operation, cursor, PageRows);
            foreach (var row in page.Rows)
            {
                // Mask before decoding, dot product or heap insertion.
                if (!mask.Contains(row.Reference.SourceId)) continue;
                if (!HalfPrecision.DecodeNormalized(row.Blob, scratch)) { invalid++; continue; }
                // Same binary16-rounded values as the resident matrix (retrieval-resident-v1 §3).
                HalfPrecision.Round(scratch);
                heap.Offer(row.Reference, scratch);
            }
            cursor = page.LastScannedChunkId;
            if (page.Exhausted) break;
        }
        return heap.Sorted().Select(row => row.Reference).ToArray();
    }

    /// <summary>Eval strictness: any malformed, nonfinite or zero stored vector in scope fails the case.</summary>
    private bool HasMalformedStoredVector(ResolvedRetrievalScope snapshot)
    {
        var reader = _store.MakeRetrievalReader();
        using var operation = snapshot.AcquireOperation();
        int dims = snapshot.Pin.Dims ?? 0;
        var permitted = reader.PermittedSourceIds(operation);
        long cursor = 0;
        while (true)
        {
            var page = reader.RawVectorPage(operation, cursor, PageRows);
            foreach (var row in page.Rows)
            {
                if (!permitted.Contains(row.Reference.SourceId)) continue;
                if (row.Blob is not byte[] blob || blob.Length != dims * sizeof(float)) return true;
                bool nonzero = false;
                for (int i = 0; i < dims; i++)
                {
                    float value = BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(blob.AsSpan(i * sizeof(float))));
                    if (!float.IsFinite(value)) return true;
                    nonzero |= value != 0;
                }
                if (!nonzero) return true;
            }
            cursor = page.LastScannedChunkId;
            if (page.Exhausted) return false;
        }
    }

    /// <summary>Copies display snippets from each candidate's explicit revision while the pool is pinned.</summary>
    private IReadOnlyList<RetrievalHit> Hits(PinnedRetrievalCandidates pool,
        IReadOnlyList<PinnedRetrievalCandidate> candidates, Func<long, float> score)
    {
        if (candidates.Count == 0 || pool.Snapshot is null) return [];
        var reader = _store.MakeRetrievalReader();
        using var operation = pool.Snapshot.AcquireOperation();
        var rows = reader.EvidenceRows(operation, candidates.Select(c => c.Reference).ToArray())
            .ToDictionary(row => row.Reference.ChunkId);
        // A source revoked since ranking yields no evidence and no hit.
        return candidates.Where(c => rows.ContainsKey(c.Reference.ChunkId))
            .Select(c => new RetrievalHit(c.Reference.ChunkId, c.Reference.SourceId, score(c.RrfMicro),
                Snippet(rows[c.Reference.ChunkId].ChunkText)))
            .ToArray();
    }

    private static string Snippet(string text)
    {
        int index = 0, scalars = 0;
        while (index < text.Length && scalars < 240)
        {
            Rune.DecodeFromUtf16(text.AsSpan(index), out _, out int consumed);
            index += Math.Max(consumed, 1);
            scalars++;
        }
        return index == text.Length ? text : text[..index];
    }

    private static bool Oversized(int dims) => dims <= 0 || (long)dims * sizeof(float) > MaximumVectorBytes;

    private static bool ValidQuery(float[] vector, int dims) =>
        MaskedVectorTopK.Create(vector, dims, new HashSet<long>(), 1) is not null;
}

using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

/// <summary>A branch or fused candidate with its own explicit revision and the query's generation.</summary>
public sealed record PinnedRetrievalCandidate(ChunkReference Reference, long? GenerationId, long RrfMicro);

/// <summary>
/// Vector-branch outcome. VectorStatus is one of: used, disabled, noActiveGeneration,
/// invalidQueryVector, embeddingFailed, endpointRevisionMismatch, unsupportedQueryFormat,
/// embeddingSessionRequired, legacyEndpointUnverified, legacyProviderUnresolved, oversizedVector.
/// Never carries secrets or raw endpoint strings.
/// </summary>
public sealed record RetrievalDiagnostics(string VectorStatus, int InvalidVectorCount, bool Streamed, long PeakPageBytes);

/// <summary>
/// The complete scoped candidate pool of one query. It owns the query's revision
/// lease: dispose it once evidence has been copied. Disposal is idempotent.
/// </summary>
public sealed class PinnedRetrievalCandidates : IDisposable
{
    public IReadOnlyList<PinnedRetrievalCandidate> Lexical { get; }
    public IReadOnlyList<PinnedRetrievalCandidate> Vector { get; }
    /// <summary>First chunks of the best path-matching files (retrieval-paths-v1 §4).</summary>
    public IReadOnlyList<PinnedRetrievalCandidate> Path { get; }
    /// <summary>The full best-tier path ranking over the permitted published files.</summary>
    public IReadOnlyList<PathMatch> PathMatches { get; }
    /// <summary>retrieval-paths v2 (§6): a year or document-type term matched the best tier.</summary>
    public bool PathInventory { get; }
    public IReadOnlyList<PinnedRetrievalCandidate> Fused { get; }
    public ResolvedRetrievalScope? Snapshot { get; }
    public RetrievalDiagnostics Diagnostics { get; }
    /// <summary>The provider failure behind an embeddingFailed status, for legacy adapters that rethrow it.</summary>
    internal Exception? EmbeddingFailure { get; }

    internal PinnedRetrievalCandidates(IReadOnlyList<PinnedRetrievalCandidate> lexical,
        IReadOnlyList<PinnedRetrievalCandidate> vector, IReadOnlyList<PinnedRetrievalCandidate> fused,
        ResolvedRetrievalScope? snapshot, RetrievalDiagnostics diagnostics, Exception? embeddingFailure = null,
        IReadOnlyList<PinnedRetrievalCandidate>? path = null, IReadOnlyList<PathMatch>? pathMatches = null,
        bool pathInventory = false)
    {
        Lexical = Array.AsReadOnly(lexical.ToArray());
        Vector = Array.AsReadOnly(vector.ToArray());
        Path = Array.AsReadOnly((path ?? []).ToArray());
        PathMatches = Array.AsReadOnly((pathMatches ?? []).ToArray());
        PathInventory = pathInventory;
        Fused = Array.AsReadOnly(fused.ToArray());
        Snapshot = snapshot;
        Diagnostics = diagnostics;
        EmbeddingFailure = embeddingFailure;
    }

    internal static PinnedRetrievalCandidates Empty(string vectorStatus) =>
        new([], [], [], null, new(vectorStatus, 0, false, 0));

    public void Dispose() => Snapshot?.Dispose();
}

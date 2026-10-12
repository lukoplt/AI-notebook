using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;

namespace AINotebook.Core.Storage;

public sealed record ChunkReference(long ChunkId, long SourceId, long RevisionId, int Ord);
/// <summary>Mtime: file modification time (UTC seconds), for the path matcher's date signals.</summary>
public sealed record ScopedSource(long SourceId, long? FolderId, string? RelPath, string DisplayName,
    long? PublishedRevisionId, long? VectorRevisionId, long? Mtime = null);
public sealed record VectorRow(ChunkReference Reference, float[] Values);
public sealed record ScoredChunk(ChunkReference Reference, float Score);
public sealed record RankedChunk(ChunkReference Reference, long RrfMicro);
public sealed record RetrievalCacheKey(string DatabaseId, long NotebookId, long GenerationId, ulong Epoch);
public sealed record ChunkEvidenceRow(ChunkReference Reference, string CanonicalText, string ChunkText,
    int? CharStart, int? CharEnd, int? PageHint, int ChunkerVersion);
public sealed record EvidencePassage(ChunkReference Reference, string Text, string DisplaySnippet,
    IReadOnlyList<CitationSpan> Spans, bool IsNeighbour);
internal sealed record RawVectorRow(ChunkReference Reference, byte[]? Blob);
internal sealed record RawVectorPage(IReadOnlyList<RawVectorRow> Rows,
    long LastScannedChunkId, bool Exhausted, int PayloadBytes);

public sealed class RetrievalException(string code) : Exception(code)
{
    public string Code { get; } = code;
}

/// <summary>A captured turn owns one WP3 pin until its owner and all operations finish.</summary>
public sealed class ResolvedRetrievalScope : IDisposable
{
    private readonly RetrievalLeaseState _state = new();
    internal NotebookStore Store { get; }
    public QueryPin Pin { get; }
    public RetrievalScope Scope { get; }
    public IReadOnlyList<ScopedSource> Sources { get; }
    public int FilesInScope => Sources.Count;
    public IndexGeneration? Generation { get; }
    public RetrievalCacheKey? CacheKey { get; }
    internal string InitialSourceIdsJson { get; }
    internal IReadOnlySet<long> InitialSourceIdSet { get; }
    internal string SourceIdsJson { get; }
    internal string FolderIdsJson { get; }
    internal string PublishedPairsJson { get; }
    internal string VectorPairsJson { get; }
    internal int IsAll => Scope is RetrievalScope.All ? 1 : 0;

    internal ResolvedRetrievalScope(NotebookStore store, QueryPin pin, RetrievalScope scope,
        IReadOnlyList<ScopedSource> sources, IndexGeneration? generation, RetrievalCacheKey? cacheKey)
    {
        Store = store; Pin = pin; Scope = scope;
        Sources = Array.AsReadOnly(sources.ToArray());
        Generation = generation; CacheKey = cacheKey;
        InitialSourceIdsJson = JsonSerializer.Serialize(Sources.Select(s => s.SourceId).Order());
        InitialSourceIdSet = Sources.Select(s => s.SourceId).ToHashSet();
        SourceIdsJson = JsonSerializer.Serialize(scope is RetrievalScope.Selection s ? s.SourceIds.Order().ToArray() : Array.Empty<long>());
        FolderIdsJson = JsonSerializer.Serialize(scope is RetrievalScope.Selection f ? f.FolderIds.Order().ToArray() : Array.Empty<long>());
        PublishedPairsJson = Pairs(pin.LexicalRevisions);
        VectorPairsJson = Pairs(pin.VectorRevisions);
    }

    private static string Pairs(IReadOnlyDictionary<long, long> pairs) =>
        JsonSerializer.Serialize(pairs.OrderBy(p => p.Key).Select(p => new { sourceId = p.Key, revisionId = p.Value }));

    public RetrievalOperation AcquireOperation()
    {
        _state.Begin();
        return new RetrievalOperation(this);
    }

    public void Dispose()
    {
        if (_state.RequestClose()) Store.ReleaseQuery(Pin);
    }

    internal void EndOperation()
    {
        if (_state.End()) Store.ReleaseQuery(Pin);
    }
}

public sealed class RetrievalOperation : IDisposable
{
    private int _closed;
    public ResolvedRetrievalScope Snapshot { get; }
    internal RetrievalOperation(ResolvedRetrievalScope snapshot) => Snapshot = snapshot;
    internal void Validate()
    {
        if (Volatile.Read(ref _closed) != 0) throw new RetrievalException("closedSnapshot");
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref _closed, 1) == 0) Snapshot.EndOperation();
    }
}

internal sealed class RetrievalLeaseState
{
    private readonly object _leaseGate = new();
    private bool _closing, _released;
    private int _borrowers;
    internal void Begin()
    {
        lock (_leaseGate)
        {
            if (_closing) throw new RetrievalException("closedSnapshot");
            _borrowers++;
        }
    }
    internal bool RequestClose()
    {
        lock (_leaseGate) { _closing = true; return TakeRelease(); }
    }
    internal bool End()
    {
        lock (_leaseGate)
        {
            if (_borrowers <= 0) throw new InvalidOperationException("Unbalanced retrieval borrow");
            _borrowers--; return TakeRelease();
        }
    }
    private bool TakeRelease()
    {
        if (!_closing || _borrowers != 0 || _released) return false;
        _released = true; return true;
    }
}

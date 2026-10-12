using System.Numerics.Tensors;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

public static class RetrievalRanking
{
    /// <summary>Fuses the complete branch union using deduplicated, one-based integer ranks.</summary>
    public static IReadOnlyList<RankedChunk> Fuse(IReadOnlyList<ChunkReference> lexical,
        IReadOnlyList<ChunkReference> vector, int rrfK = 60) => Fuse(lexical, vector, [], rrfK);

    /// <summary>Integer RRF over the branches; path (retrieval-paths-v1 §4) is empty unless the
    /// question's terms match file paths.</summary>
    public static IReadOnlyList<RankedChunk> Fuse(IReadOnlyList<ChunkReference> lexical,
        IReadOnlyList<ChunkReference> vector, IReadOnlyList<ChunkReference> path, int rrfK = 60)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(rrfK);
        var scores = new Dictionary<long, long>();
        var references = new Dictionary<long, ChunkReference>();
        foreach (var branch in new[] { lexical, vector, path })
        {
            var seen = new HashSet<long>();
            long rank = 0;
            foreach (var reference in branch)
            {
                if (references.TryGetValue(reference.ChunkId, out var previous) && previous != reference)
                    throw new RetrievalException("revisionMismatch");
                if (!seen.Add(reference.ChunkId)) continue;
                rank++;
                references[reference.ChunkId] = reference;
                // Widen before addition: the configurable denominator may exceed Int32.
                scores[reference.ChunkId] = scores.GetValueOrDefault(reference.ChunkId) + 1_000_000L / ((long)rrfK + rank);
            }
        }
        return scores.Select(pair => new RankedChunk(references[pair.Key], pair.Value))
            .OrderByDescending(row => row.RrfMicro).ThenBy(row => row.Reference.ChunkId).ToArray();
    }

    /// <summary>
    /// Bounded-heap facade for supplied rows. Production cache/stream scans use the
    /// same accumulator with the pinned generation's explicit dimensions.
    /// </summary>
    public static IReadOnlyList<ScoredChunk> TopK(IReadOnlyList<VectorRow> rows,
        float[] query, IReadOnlySet<long> permittedSources, int k)
        => TopK(rows, query, permittedSources, k, out _);

    internal static IReadOnlyList<ScoredChunk> TopK(IReadOnlyList<VectorRow> rows,
        float[] query, IReadOnlySet<long> permittedSources, int k, out int invalidVectorCount)
    {
        invalidVectorCount = 0;
        // This convenience facade takes shape from the first nonempty row, even
        // when its values are nonfinite. Shape cannot be inferred reliably from
        // malformed input; production always supplies the generation's dimensions.
        int dims = rows.FirstOrDefault(row => row.Values.Length != 0)?.Values.Length ?? 0;
        var heap = MaskedVectorTopK.Create(query, dims, permittedSources, k);
        if (heap is null) return Array.Empty<ScoredChunk>();
        foreach (var row in rows)
        {
            if (row.Values.Length != dims)
            {
                invalidVectorCount++;
                continue;
            }
            // Own only one row copy at a time; never mutate the caller's vectors.
            float[] normalized = (float[])row.Values.Clone();
            if (!MaskedVectorTopK.Normalize(normalized, allowZero: true))
            {
                invalidVectorCount++;
                continue;
            }
            heap.Offer(row.Reference, normalized);
        }
        return heap.Sorted();
    }
}

/// <summary>One source-masked, worst-first heap shared by cached and streamed scans.</summary>
internal sealed class MaskedVectorTopK
{
    private readonly float[] _query;
    private readonly HashSet<long> _permitted;
    private readonly int _k;
    private readonly PriorityQueue<ScoredChunk, (float Score, long ReverseId)> _heap = new();

    private MaskedVectorTopK(float[] query, IReadOnlySet<long> permitted, int k)
    {
        _query = query;
        _permitted = permitted.ToHashSet();
        _k = k;
    }

    internal static bool Normalize(Span<float> row, bool allowZero)
    {
        if (row.IsEmpty) return false;
        double squared = 0;
        foreach (float value in row)
        {
            if (!float.IsFinite(value)) return false;
            squared += (double)value * value;
        }
        if (!double.IsFinite(squared)) return false;
        if (squared == 0) return allowZero;
        double norm = Math.Sqrt(squared);
        for (int i = 0; i < row.Length; i++) row[i] = (float)(row[i] / norm);
        return true;
    }

    internal static MaskedVectorTopK? Create(float[] query, int dims, IReadOnlySet<long> permittedSources, int k)
    {
        if (k <= 0 || dims <= 0 || query.Length != dims) return null;
        float[] normalized = (float[])query.Clone();
        return Normalize(normalized, allowZero: false) ? new(normalized, permittedSources, k) : null;
    }

    private static bool Better(ScoredChunk candidate, ScoredChunk previous)
        => candidate.Score > previous.Score ||
           candidate.Score == previous.Score && candidate.Reference.ChunkId < previous.Reference.ChunkId;

    internal void Offer(ChunkReference reference, ReadOnlySpan<float> normalizedRow)
    {
        // Mask before SIMD and heap selection so excluded rows cannot consume K.
        if (!_permitted.Contains(reference.SourceId) || normalizedRow.Length != _query.Length) return;
        float score = Score(_query, normalizedRow);
        if (!float.IsFinite(score)) return;
        Insert(new ScoredChunk(reference, score));
    }

    /// <summary>The one scoring kernel of every vector path (fp32 dot product of normalized rows).</summary>
    internal static float Score(float[] query, ReadOnlySpan<float> row) => TensorPrimitives.Dot<float>(row, query);

    internal float[] NormalizedQuery => _query;

    /// <summary>True when a finite score would enter the heap (for already masked rows).</summary>
    internal bool Admits(float score, long chunkId)
    {
        if (!float.IsFinite(score)) return false;
        if (_heap.Count < _k) return true;
        var worst = _heap.Peek();
        return score > worst.Score || score == worst.Score && chunkId < worst.Reference.ChunkId;
    }

    /// <summary>Inserts an already masked, finite candidate.</summary>
    internal void Insert(ScoredChunk candidate)
    {
        var priority = (candidate.Score, -candidate.Reference.ChunkId);
        if (_heap.Count < _k) _heap.Enqueue(candidate, priority);
        else if (Better(candidate, _heap.Peek()))
        {
            _heap.Dequeue();
            _heap.Enqueue(candidate, priority);
        }
    }

    internal IReadOnlyList<ScoredChunk> Sorted() => _heap.UnorderedItems.Select(item => item.Element)
        .OrderByDescending(row => row.Score).ThenBy(row => row.Reference.ChunkId).ToArray();
}

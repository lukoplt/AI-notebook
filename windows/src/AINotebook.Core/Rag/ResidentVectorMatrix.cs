using System.Numerics.Tensors;
using System.Runtime.InteropServices;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

/// <summary>
/// Identity of one generation's resident matrix (retrieval-resident-v1): the database identity,
/// the store instance that opened it (renewed on every open, so a reopened or restored file never
/// inherits rows), notebook, generation and dims.
/// </summary>
public sealed record ResidentMatrixKey(string DatabaseId, string DatabaseInstance, long NotebookId, long GenerationId, int Dims);

/// <summary>Result of one resident scoring call; a null result from the cache means "stream instead".</summary>
internal sealed record ResidentScan(IReadOnlyList<ScoredChunk> Scored, int InvalidVectorCount, long PeakPageBytes);

/// <summary>
/// Binary16 storage shared by the resident matrix and the streamed scan, so both score the
/// identical fp32 values: a row is L2-normalized (fp64 sum, fp32 result), rounded to IEEE
/// binary16 (round-to-nearest-even) and widened back to fp32 before the fp32 dot product.
/// </summary>
internal static class HalfPrecision
{
    internal static void Round(Span<float> row)
    {
        Span<Half> halves = row.Length <= 4096 ? stackalloc Half[row.Length] : new Half[row.Length];
        TensorPrimitives.ConvertToHalf(row, halves);
        TensorPrimitives.ConvertToSingle(halves, row);
    }

    /// <summary>Decodes one little-endian fp32 BLOB into <paramref name="row"/> and normalizes it.</summary>
    internal static bool DecodeNormalized(byte[]? blob, Span<float> row)
    {
        if (blob is null || blob.Length != row.Length * sizeof(float)) return false;
        if (BitConverter.IsLittleEndian) MemoryMarshal.Cast<byte, float>(blob).CopyTo(row);
        else
            for (int i = 0; i < row.Length; i++)
                row[i] = BitConverter.Int32BitsToSingle(System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(blob.AsSpan(i * 4)));
        return MaskedVectorTopK.Normalize(row, allowZero: true);
    }
}

/// <summary>One batch of rows loaded for a set of pinned pairs; owned by its load until committed, immutable after.</summary>
internal sealed class ResidentBlock(int capacity, int dims)
{
    internal int Dims { get; } = dims;
    internal int Capacity { get; } = capacity;
    internal Half[] Halves { get; } = new Half[(long)Math.Max(capacity, 0) * dims];
    internal List<long> ChunkIds { get; } = new(capacity);
    internal List<long> SourceIds { get; } = new(capacity);
    internal List<long> RevisionIds { get; } = new(capacity);
    internal List<int> Ords { get; } = new(capacity);
    internal Dictionary<long, int> InvalidBySource { get; } = new();
    internal long PeakPageBytes { get; private set; }
    internal int Count => ChunkIds.Count;

    internal static long? Charge(long rows, int dims)
    {
        if (rows < 0 || dims <= 0) return null;
        try { return checked(rows * (checked((long)dims * 2) + 32)); }
        catch (OverflowException) { return null; }
    }

    /// <summary>Appends one SQL page; false when it would exceed the reserved capacity.</summary>
    internal bool Append(RawVectorPage page)
    {
        PeakPageBytes = Math.Max(PeakPageBytes, page.PayloadBytes);
        var row = new float[Dims];
        foreach (var raw in page.Rows)
        {
            if (!HalfPrecision.DecodeNormalized(raw.Blob, row))
            {
                InvalidBySource[raw.Reference.SourceId] = InvalidBySource.GetValueOrDefault(raw.Reference.SourceId) + 1;
                continue;
            }
            if (Count >= Capacity) return false;
            TensorPrimitives.ConvertToHalf(row, Halves.AsSpan(Count * Dims, Dims));
            Add(raw.Reference.ChunkId, raw.Reference.SourceId, raw.Reference.RevisionId, raw.Reference.Ord);
        }
        return true;
    }

    internal void Add(long chunkId, long sourceId, long revisionId, int ord)
    {
        ChunkIds.Add(chunkId);
        SourceIds.Add(sourceId);
        RevisionIds.Add(revisionId);
        Ords.Add(ord);
    }
}

/// <summary>
/// The resident, revision-checked matrix of one generation: rows are loaded per pinned
/// (source, revision) pair and kept across queries and writes; a query uses a row only when the
/// row's revision is the allowed (pinned and permitted) revision of its source. Mutated only
/// under the owning cache's per-key lock.
/// </summary>
internal sealed class ResidentVectorMatrix(int dims)
{
    private readonly List<ResidentBlock> _blocks = new();
    private readonly Dictionary<long, long> _loaded = new();
    private readonly Dictionary<long, int> _rowsBySource = new();
    private readonly Dictionary<long, int> _invalidBySource = new();
    internal int Dims { get; } = dims;
    internal int Rows { get; private set; }
    internal int GarbageRows { get; private set; }
    internal long PeakPageBytes { get; private set; }
    internal int InvalidVectorCount => _invalidBySource.Values.Sum();
    internal long Bytes => ResidentBlock.Charge(_blocks.Sum(b => (long)b.Count), Dims) ?? long.MaxValue;

    internal Dictionary<long, long> Missing(IReadOnlyDictionary<long, long> pins)
        => pins.Where(p => !_loaded.TryGetValue(p.Key, out long loaded) || loaded != p.Value).ToDictionary(p => p.Key, p => p.Value);

    internal void Commit(ResidentBlock block, IReadOnlyDictionary<long, long> pairs)
    {
        foreach (var (source, revision) in pairs)
        {
            if (_loaded.TryGetValue(source, out long old) && old != revision) GarbageRows += _rowsBySource.GetValueOrDefault(source);
            _loaded[source] = revision;
            _rowsBySource[source] = 0;
            if (block.InvalidBySource.TryGetValue(source, out int invalid)) _invalidBySource[source] = invalid;
            else _invalidBySource.Remove(source);
        }
        for (int i = 0; i < block.Count; i++)
            if (pairs.TryGetValue(block.SourceIds[i], out long revision) && revision == block.RevisionIds[i])
                _rowsBySource[block.SourceIds[i]] = _rowsBySource.GetValueOrDefault(block.SourceIds[i]) + 1;
        Rows += block.Count;
        PeakPageBytes = Math.Max(PeakPageBytes, block.PeakPageBytes);
        if (block.Count > 0) _blocks.Add(block);
    }

    /// <summary>Copies the live rows (loaded revision of each source) into one block.</summary>
    internal ResidentVectorMatrix Compacted()
    {
        var block = new ResidentBlock(Rows - GarbageRows, Dims);
        foreach (var source in _blocks)
            for (int i = 0; i < source.Count; i++)
            {
                if (!_loaded.TryGetValue(source.SourceIds[i], out long revision) || revision != source.RevisionIds[i]) continue;
                source.Halves.AsSpan(i * Dims, Dims).CopyTo(block.Halves.AsSpan(block.Count * Dims, Dims));
                block.Add(source.ChunkIds[i], source.SourceIds[i], source.RevisionIds[i], source.Ords[i]);
            }
        var target = new ResidentVectorMatrix(Dims) { Rows = block.Count, PeakPageBytes = PeakPageBytes };
        foreach (var p in _loaded) target._loaded[p.Key] = p.Value;
        foreach (var p in _rowsBySource) target._rowsBySource[p.Key] = p.Value;
        foreach (var p in _invalidBySource) target._invalidBySource[p.Key] = p.Value;
        if (block.Count > 0) target._blocks.Add(block);
        return target;
    }

    /// <summary>Masked top-K over binary16 rows widened to fp32; ties by smaller chunk id.</summary>
    internal IReadOnlyList<ScoredChunk> TopK(float[] query, IReadOnlyDictionary<long, long> allowed, int k)
    {
        var heap = MaskedVectorTopK.Create(query, Dims, allowed.Keys.ToHashSet(), k);
        if (heap is null) return Array.Empty<ScoredChunk>();
        const int Stripe = 256;
        var widened = new float[Stripe * Dims];
        var flags = new bool[Stripe];
        foreach (var block in _blocks)
        {
            long lastSource = long.MinValue;
            long? lastRevision = null;
            for (int start = 0; start < block.Count; start += Stripe)
            {
                int end = Math.Min(block.Count, start + Stripe);
                bool any = false;
                for (int i = start; i < end; i++)
                {
                    long source = block.SourceIds[i];
                    if (source != lastSource)
                    {
                        lastSource = source;
                        lastRevision = allowed.TryGetValue(source, out long r) ? r : null;
                    }
                    flags[i - start] = lastRevision == block.RevisionIds[i];
                    any |= flags[i - start];
                }
                if (!any) continue;
                TensorPrimitives.ConvertToSingle(block.Halves.AsSpan(start * Dims, (end - start) * Dims), widened);
                for (int offset = 0; offset < end - start; offset++)
                {
                    if (!flags[offset]) continue;
                    int i = start + offset;
                    float score = MaskedVectorTopK.Score(heap.NormalizedQuery, widened.AsSpan(offset * Dims, Dims));
                    if (!heap.Admits(score, block.ChunkIds[i])) continue;
                    heap.Insert(new ScoredChunk(new ChunkReference(block.ChunkIds[i], block.SourceIds[i], block.RevisionIds[i], block.Ords[i]), score));
                }
            }
        }
        return heap.Sorted();
    }
}

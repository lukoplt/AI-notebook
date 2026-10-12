using System.Buffers.Binary;
using System.Text.Json;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public sealed class RetrievalRankingTests
{
    private static JsonElement[] Cases() => SharedFixtures.Json("contracts/retrieval-rank-v1.json")
        .GetProperty("cases").EnumerateArray().ToArray();

    [Fact]
    public void IntegerRrfSharedCases()
    {
        foreach (var c in Cases())
        {
            if (!c.TryGetProperty("lexical", out _)) continue;
            ChunkReference[] Refs(string key) => c.GetProperty(key).EnumerateArray()
                .Select(x => new ChunkReference(x.GetInt64(), 1, 1, 0)).ToArray();
            var actual = RetrievalRanking.Fuse(Refs("lexical"), Refs("vector"));
            var expected = c.GetProperty("expected").EnumerateArray().ToArray();
            Assert.Equal(expected.Select(x => x.GetProperty("chunkId").GetInt64()), actual.Select(x => x.Reference.ChunkId));
            Assert.Equal(expected.Select(x => x.GetProperty("rrfMicro").GetInt64()), actual.Select(x => x.RrfMicro));
        }

        var reference = new ChunkReference(1, 2, 3, 0);
        foreach (var conflict in new[] { reference with { SourceId = 4 }, reference with { RevisionId = 4 }, reference with { Ord = 1 } })
        {
            Assert.Equal("revisionMismatch", Assert.Throws<RetrievalException>(() =>
                RetrievalRanking.Fuse([reference, conflict], [])).Code);
            Assert.Equal("revisionMismatch", Assert.Throws<RetrievalException>(() =>
                RetrievalRanking.Fuse([reference], [conflict])).Code);
        }
        Assert.Throws<ArgumentOutOfRangeException>(() => RetrievalRanking.Fuse([], [], 0));
        var wideDenominator = RetrievalRanking.Fuse([reference, reference with { ChunkId = 2 }], [], int.MaxValue);
        Assert.Equal(new long[] { 1, 2 }, wideDenominator.Select(x => x.Reference.ChunkId));
        Assert.All(wideDenominator, row => Assert.Equal(0, row.RrfMicro));
    }

    [Fact]
    public void VectorRankingSharedCases()
    {
        foreach (var c in Cases().Where(c => c.TryGetProperty("rows", out _)))
        {
            var (rows, query, permitted) = Vectors(c);
            var actual = RetrievalRanking.TopK(rows, query, permitted, c.GetProperty("k").GetInt32());
            Assert.Equal(c.GetProperty("expectedIds").EnumerateArray().Select(x => x.GetInt64()),
                actual.Select(x => x.Reference.ChunkId));
        }
    }

    [Fact]
    public void HeapFixtureCases()
    {
        foreach (var c in Cases().Where(c => c.TryGetProperty("rows", out _)))
        {
            var (rows, query, permitted) = Vectors(c);
            int k = c.GetProperty("k").GetInt32();
            var actual = RetrievalRanking.TopK(rows, query, permitted, k, out int invalidRows);
            Assert.Equal(c.TryGetProperty("invalidVectorCount", out var invalid) ? invalid.GetInt32() : 0, invalidRows);
            Assert.Equal(c.GetProperty("expectedIds").EnumerateArray().Select(x => x.GetInt64()),
                actual.Select(x => x.Reference.ChunkId));
            float[] expectedScores = c.GetProperty("expectedScoreMicros").EnumerateArray().Select(x => x.GetInt64() / 1_000_000f).ToArray();
            for (int i = 0; i < expectedScores.Length; i++)
                Assert.InRange(Math.Abs(actual[i].Score - expectedScores[i]), 0, 0.000001f);

            // A known generation dimension permits arbitrary page and row order,
            // including a malformed first row. One heap spans every page.
            var heap = MaskedVectorTopK.Create(query, c.GetProperty("dims").GetInt32(), permitted, k);
            if (heap is null) { Assert.Empty(actual); continue; }
            foreach (var row in rows.Reverse())
            {
                float[] normalized = (float[])row.Values.Clone();
                if (normalized.Length == c.GetProperty("dims").GetInt32() && MaskedVectorTopK.Normalize(normalized, true))
                    heap.Offer(row.Reference, normalized);
            }
            Assert.Equal(actual.Select(x => x.Reference.ChunkId), heap.Sorted().Select(x => x.Reference.ChunkId));
        }
        Assert.Empty(RetrievalRanking.TopK([], [1, 0], new HashSet<long> { 1 }, 2));
    }

    [Fact]
    public void SimdDotWithinTolerance()
    {
        var c = Cases().Single(c => c.GetProperty("name").GetString() == "normalized-dot");
        var (rows, query, permitted) = Vectors(c);
        float expected = c.GetProperty("expectedScoreMicros")[0].GetInt64() / 1_000_000f;
        foreach (int dims in new[] { 2, 3, 16, 257 })
        {
            float[] paddedQuery = new float[dims], paddedRow = new float[dims + 2];
            query.CopyTo(paddedQuery, 0);
            rows[0].Values.CopyTo(paddedRow, 1);
            // Offer a slice of the slab; adjacent values are not part of this row.
            paddedRow[0] = float.NaN; paddedRow[^1] = float.PositiveInfinity;
            var values = paddedRow.AsSpan(1, dims);
            Assert.True(MaskedVectorTopK.Normalize(values, true));
            var heap = Assert.IsType<MaskedVectorTopK>(MaskedVectorTopK.Create(paddedQuery, dims, permitted, 1));
            heap.Offer(rows[0].Reference, values);
            Assert.InRange(Math.Abs(Assert.Single(heap.Sorted()).Score - expected), 0, 0.000001f);
            Assert.Equal(query, paddedQuery.Take(query.Length));
        }
        Assert.Null(MaskedVectorTopK.Create(query, query.Length + 1, permitted, 1));
        Assert.False(MaskedVectorTopK.Normalize([], true));
        Assert.True(MaskedVectorTopK.Normalize(new float[] { 0, 0 }, true));
        Assert.False(MaskedVectorTopK.Normalize(new float[] { 0, 0 }, false));
        var extremes = new[] { float.MaxValue, float.MaxValue };
        Assert.True(MaskedVectorTopK.Normalize(extremes, false));
        Assert.All(extremes, value => Assert.InRange(Math.Abs(value - Math.Sqrt(0.5)), 0, 0.000001));
    }

    private static (VectorRow[] Rows, float[] Query, HashSet<long> Permitted) Vectors(JsonElement c)
    {
        var rows = c.GetProperty("rows").EnumerateArray().ToArray();
        var result = rows.Select(row => new VectorRow(new(row.GetProperty("chunkId").GetInt64(),
            row.GetProperty("sourceId").GetInt64(), row.GetProperty("revisionId").GetInt64(),
            row.GetProperty("ord").GetInt32()), Values(row, "vector", "float32Bits"))).ToArray();
        return (result, Values(c, "query", "queryFloat32Bits"), rows.Where(row => row.GetProperty("eligible").GetInt32() == 1)
            .Select(row => row.GetProperty("sourceId").GetInt64()).ToHashSet());
    }

    private static float[] Values(JsonElement row, string valuesName, string bitsName)
    {
        if (row.TryGetProperty(valuesName, out var values))
            return values.EnumerateArray().Select(value => value.GetSingle()).ToArray();
        if (row.TryGetProperty(bitsName, out var bits))
            return bits.EnumerateArray().Select(value => BitConverter.Int32BitsToSingle(unchecked((int)value.GetUInt32()))).ToArray();
        byte[] blob = Convert.FromHexString(row.GetProperty("blobHex").GetString()!);
        Assert.Equal(0, blob.Length % sizeof(float));
        return Enumerable.Range(0, blob.Length / sizeof(float)).Select(i =>
            BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(blob.AsSpan(i * sizeof(float), sizeof(float))))).ToArray();
    }
}

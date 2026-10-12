using System.Buffers.Binary;
using System.Security.Cryptography;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public sealed class RetrievalPerformanceTests
{
    private sealed class Embedder : IEmbeddingProducing
    {
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
            => Task.FromResult(new[] { new float[] { 1, 0 } });
    }

    [Fact]
    public void SharedSyntheticRows()
    {
        var c = Case("small");
        int i = 0;
        var bytes = new List<byte>();
        foreach (var r in c.GetProperty("rows").EnumerateArray())
        {
            var row = SyntheticRetrievalCorpus.Row(i, c.GetProperty("dims").GetInt32(), c.GetProperty("seed").GetInt32());
            Assert.Equal(r.GetProperty("text").GetString(), row.Text);
            Assert.Equal(r.GetProperty("vector").EnumerateArray().Select(x => x.GetSingle()), row.Vector);
            Assert.Equal(i + 1, row.ChunkId); Assert.Equal(i % 100, row.Ord);
            Assert.Equal(r.GetProperty("sourceId").GetInt64(), row.SourceId);
            foreach (float value in row.Vector)
            {
                var buffer = new byte[4];
                BinaryPrimitives.WriteSingleLittleEndian(buffer, value);
                bytes.AddRange(buffer);
            }
            i++;
        }
        Assert.Equal(8, i);
        Assert.Equal(c.GetProperty("count").GetInt32(), i);
        Assert.Equal(c.GetProperty("expectedVectorBytesSha256").GetString(), Convert.ToHexStringLower(SHA256.HashData(bytes.ToArray())));
    }

    [Fact]
    public async Task TimingExcludesEmbeddingFromWarmRetrieval()
    {
        var timing = Case("timing");
        using var store = RetrievalFixtureStore.Create("no-active");
        var snapshot = ScopeResolver.Resolve(store, 1, new RetrievalScope.All(), "m")!;
        var retriever = new Retriever(store, new Embedder(), "m");
        var times = new Queue<long>(timing.GetProperty("clockTicks").EnumerateArray().Select(x => x.GetInt64()));
        var sample = await RetrievalPerformance.MeasureAsync(snapshot, () => Task.FromResult(new float[] { 1, 0 }),
            vector => retriever.SearchEmbeddedAsync(snapshot, "needle", vector),
            pool => { _ = new EvidenceHydrator(store.MakeRetrievalReader()).Hydrate(pool.Snapshot!, pool.Fused.Select(x => x.Reference).ToArray(), 0); return Task.CompletedTask; },
            timing.GetProperty("frequency").GetInt64(), () => times.Dequeue());
        Assert.Equal(timing.GetProperty("queryEmbeddingMs").GetDouble(), sample.QueryEmbeddingMs);
        Assert.Equal(timing.GetProperty("warmRetrievalMs").GetDouble(), sample.WarmRetrievalMs);
        Assert.Equal(timing.GetProperty("hydrationMs").GetDouble(), sample.HydrationMs);
        Assert.Equal(130, sample.EndToEndMs);
        Assert.Empty(times);
        // Measurement owned and released the snapshot: nothing pins retired generation 90.
        AssertNoPinRetained(store);

        using var other = RetrievalFixtureStore.Create("no-active");
        var decreasing = new Queue<long>([100, 90, 120, 130]);
        Assert.Equal("invalidMeasurementInput", (await Assert.ThrowsAsync<RetrievalException>(() => RetrievalPerformance.MeasureAsync(
            ScopeResolver.Resolve(other, 1, new RetrievalScope.All(), "m")!, () => Task.FromResult(new float[] { 1, 0 }),
            vector => new Retriever(other, new Embedder(), "m").SearchEmbeddedAsync(ScopeResolver.Resolve(other, 1, new RetrievalScope.All(), "m")!, "needle", vector),
            _ => Task.CompletedTask, 1000, () => decreasing.Dequeue()))).Code);
        Assert.Equal("invalidMeasurementInput", (await Assert.ThrowsAsync<RetrievalException>(() => RetrievalPerformance.MeasureAsync(
            ScopeResolver.Resolve(other, 1, new RetrievalScope.All(), "m")!, () => Task.FromResult(new float[] { 1, 0 }),
            _ => throw new InvalidOperationException("not reached"), _ => Task.CompletedTask, 0, () => 0))).Code);
        AssertNoPinRetained(other);
    }

    [Fact]
    public async Task GeneratedStoreTraversesProductionRetrieval()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        // Unrelated prior rows: the corpus returns actual database IDs, not logical row IDs.
        store.CreateNotebook("unrelated");
        const int count = 1000, dims = 16;
        var handle = SyntheticRetrievalCorpus.Populate(store, count, dims);
        Assert.Equal(count, handle.ChunkCount);
        Assert.Equal(dims, handle.Dims);
        Assert.Equal(handle.GenerationId, store.ActiveGeneration(handle.NotebookId)!.Id);
        lock (store.Gate)
        {
            Assert.Equal(count, store.Connection.ExecuteScalar<int>(
                "SELECT count(*) FROM chunk_embeddings WHERE generation_id=$g", new { g = handle.GenerationId }));
            Assert.Equal(count / 100, store.Connection.ExecuteScalar<int>(
                "SELECT count(*) FROM index_generation_manifest WHERE generation_id=$g AND state='done'", new { g = handle.GenerationId }));
            // Scalar spans address the LF-joined canonical text of each version-2 revision.
            var spans = store.Connection.Query("""
                SELECT sc.text,sc.char_start,sc.char_end,r.canonical_text,r.chunker_version FROM source_chunks sc
                JOIN source_revisions r ON r.id=sc.revision_id JOIN sources s ON s.id=sc.source_id
                WHERE s.notebook_id=$nb ORDER BY sc.id LIMIT 3
                """, new { nb = handle.NotebookId }).ToArray();
            foreach (var row in spans)
            {
                Assert.Equal(2, (int)(long)row.chunker_version);
                Assert.Equal((string)row.text, ((string)row.canonical_text).Substring((int)(long)row.char_start, (int)((long)row.char_end - (long)row.char_start)));
            }
        }
        var query = new float[dims];
        query[5] = 1;
        var orders = new List<long[]>();
        foreach (long budget in new[] { 1L << 20, 0L })
        {
            var retriever = new Retriever(store, new Embedder(), () => "synthetic", new VectorMatrixCache(budget), null);
            for (int run = 0; run < 2; run++)
            {
                var snapshot = ScopeResolver.Resolve(store, handle.NotebookId, new RetrievalScope.All(), "synthetic")!;
                using var pool = await retriever.SearchEmbeddedAsync(snapshot, "needle7", query, 8);
                Assert.Equal("used", pool.Diagnostics.VectorStatus);
                Assert.Equal(budget == 0, pool.Diagnostics.Streamed);
                Assert.InRange(pool.Diagnostics.PeakPageBytes, 0, 8_388_608);
                Assert.Equal(8, pool.Vector.Count);
                Assert.Equal(8, pool.Lexical.Count);
                orders.Add(pool.Vector.Select(x => x.Reference.ChunkId).ToArray());
            }
        }
        Assert.All(orders, order => Assert.Equal(orders[0], order));
        // Ties on the one-hot score break by ascending chunk ID; every hit carries position 5.
        Assert.Equal(orders[0].Order(), orders[0]);

        // Query-scoped current eligibility: a source revoked before ranking cannot contribute.
        long revoked;
        lock (store.Gate)
        {
            revoked = store.Connection.ExecuteScalar<long>("SELECT source_id FROM source_chunks WHERE id=$id", new { id = orders[0][0] });
            store.Connection.Execute("UPDATE sources SET eligible=0 WHERE id=$id", new { id = revoked });
        }
        var after = ScopeResolver.Resolve(store, handle.NotebookId, new RetrievalScope.All(), "synthetic")!;
        using var revokedPool = await new Retriever(store, new Embedder(), "synthetic").SearchEmbeddedAsync(after, "needle7", query, 8);
        Assert.DoesNotContain(revokedPool.Fused, x => x.Reference.SourceId == revoked);
        Assert.Equal(8, revokedPool.Vector.Count);

        Assert.Throws<ArgumentOutOfRangeException>(() => SyntheticRetrievalCorpus.Populate(store, 0, dims));
        Assert.Throws<ArgumentOutOfRangeException>(() => SyntheticRetrievalCorpus.Populate(store, 1, 2_097_153));
    }

    [Fact]
    public async Task PercentileAndFailureDisposesPool()
    {
        Assert.Equal(190, RetrievalPerformance.Percentile95(Enumerable.Range(1, 200).Select(x => (double)x).Reverse().ToArray()));
        Assert.Equal(7, RetrievalPerformance.Percentile95([7]));
        Assert.Throws<ArgumentException>(() => RetrievalPerformance.Percentile95([]));

        using (var store = RetrievalFixtureStore.Create())
        {
            var snapshot = ScopeResolver.Resolve(store, 1, new RetrievalScope.All(), "m")!;
            long tick = 0;
            await Assert.ThrowsAsync<InvalidOperationException>(() => RetrievalPerformance.MeasureAsync(snapshot,
                () => throw new InvalidOperationException("embedding failed"),
                _ => throw new InvalidOperationException("not reached"), _ => Task.CompletedTask, 1000, () => tick++));
            AssertNoPinRetained(store);
        }
        using (var store = RetrievalFixtureStore.Create())
        {
            var snapshot = ScopeResolver.Resolve(store, 1, new RetrievalScope.All(), "m")!;
            var retriever = new Retriever(store, new Embedder(), "m");
            PinnedRetrievalCandidates? retained = null;
            long tick = 0;
            await Assert.ThrowsAsync<InvalidOperationException>(() => RetrievalPerformance.MeasureAsync(snapshot,
                () => Task.FromResult(new float[] { 1, 0 }),
                async vector => retained = await retriever.SearchEmbeddedAsync(snapshot, "needle", vector),
                _ => throw new InvalidOperationException("hydration failed"), 1000, () => tick++));
            Assert.NotNull(retained);
            Assert.Throws<RetrievalException>(() => retained!.Snapshot!.AcquireOperation());
            AssertNoPinRetained(store);
        }
    }

    [Fact]
    public void LargeCorpusSpecification()
    {
        foreach (var (name, count) in new[] { ("large100k", 100_000), ("large200k", 200_000) })
        {
            var c = Case(name);
            Assert.Equal(count, c.GetProperty("count").GetInt32());
            int dims = c.GetProperty("dims").GetInt32(), seed = c.GetProperty("seed").GetInt32();
            Assert.Equal(256, dims);
            int last = count - 1;
            var row = SyntheticRetrievalCorpus.Row(last, dims, seed);
            Assert.Equal(count, row.ChunkId);
            Assert.Equal(1 + last / 100, row.SourceId);
            Assert.Equal(99, row.Ord);
            Assert.Equal($"synthetic {last} needle{last % 97}", row.Text);
            Assert.Equal(dims, row.Vector.Length);
            Assert.Equal(1, row.Vector.Sum());
            Assert.Equal(1, row.Vector[(last % dims + seed % dims) % dims]);
        }
        Assert.Equal(new[] { "concurrent-ingestion", "streaming-budget", "warm-cache" },
            SharedFixtures.Json("contracts/retrieval-perf-v1.json").GetProperty("scenarios").EnumerateArray().Select(x => x.GetString()));
    }

    private static System.Text.Json.JsonElement Case(string name) => SharedFixtures.Json("contracts/retrieval-perf-v1.json")
        .GetProperty("cases").EnumerateArray().Single(x => x.GetProperty("name").GetString() == name);

    // A leaked pin would retain retired generation 90 and its revision 101.
    private static void AssertNoPinRetained(NotebookStore store)
    {
        if (store.Generation(90) is { State: not "retired" }) store.RetireGeneration(90);
        store.GarbageCollect(1);
        lock (store.Gate)
        {
            Assert.Equal(0, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM index_generations WHERE id=90"));
            Assert.Equal(0, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM source_revisions WHERE id=101"));
        }
    }
}

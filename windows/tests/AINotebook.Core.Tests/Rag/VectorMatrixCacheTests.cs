using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;
using System.Buffers.Binary;
using System.Text.Json;

namespace AINotebook.Core.Tests.Rag;

public sealed class VectorMatrixCacheTests
{
    [Fact]
    public async Task LeasedBytesRemainCharged()
    {
        var f = SharedFixtures.Json("contracts/retrieval-cache-v1.json");
        var cache = new VectorMatrixCache(f.GetProperty("budgetBytes").GetInt64());
        IReadOnlyList<VectorRow> rows = new[] { new VectorRow(new(1,1,1,0),[1,0]), new VectorRow(new(2,1,1,1),[1,0]) };
        RetrievalCacheKey Key(long n) => new("db", n, 90, 0);
        var first = await cache.AcquireAsync(Key(1),2,2,()=>0,_=>Task.FromResult(rows));
        var second = await cache.AcquireAsync(Key(2),2,2,()=>0,_=>Task.FromResult(rows));
        Assert.NotNull(first); Assert.NotNull(second);
        cache.Invalidate("db");
        using var blocked = await cache.AcquireAsync(Key(3),2,2,()=>0,_=>Task.FromResult(rows));
        Assert.Null(blocked);
        Assert.Equal(160,cache.Statistics().ResidentBytes);
        first.Dispose(); second.Dispose();
        Assert.Equal(0,cache.Statistics().ResidentBytes);
    }

    [Fact]
    public async Task CacheCaseTable()
    {
        var fixture = SharedFixtures.Json("contracts/retrieval-cache-v1.json");
        var keys = fixture.GetProperty("keys").EnumerateObject().ToDictionary(p => p.Name, p => Key(p.Value));
        int dims = fixture.GetProperty("dims").GetInt32();
        int executed = 0;
        foreach (var c in fixture.GetProperty("cases").EnumerateArray())
        {
            executed++;
            var cache = new VectorMatrixCache(fixture.GetProperty("budgetBytes").GetInt64());
            var leases = new Dictionary<string, VectorMatrixLease?>();
            var pending = new Dictionary<string, (string Barrier, Task<VectorMatrixLease?> Task)>();
            var barriers = new Dictionary<string, FillBarrier>();
            try
            {
                foreach (var action in c.GetProperty("actions").EnumerateArray())
                {
                    string operation = action.GetProperty("op").GetString()!;
                    switch (operation)
                    {
                        case "acquire":
                        {
                            var key = keys[action.GetProperty("key").GetString()!];
                            int count = action.GetProperty("rows").GetInt32();
                            var lease = await cache.AcquireAsync(key, count, dims, () => key.Epoch,
                                (builder, _) => { builder.Append(Rows(count, dims)); return Task.CompletedTask; });
                            AssertMode(action, lease);
                            leases.Add(action.GetProperty("lease").GetString()!, lease);
                            break;
                        }
                        case "startAcquire":
                        {
                            string name = action.GetProperty("barrier").GetString()!;
                            if (!barriers.TryGetValue(name, out var barrier))
                                barriers.Add(name, barrier = new FillBarrier());
                            var key = keys[action.GetProperty("key").GetString()!];
                            int count = action.GetProperty("rows").GetInt32();
                            var acquisition = cache.AcquireAsync(key, count, dims, () => key.Epoch, async (builder, ct) =>
                            {
                                barrier.Started.TrySetResult();
                                await barrier.Resume.Task.WaitAsync(ct);
                                builder.Append(Rows(count, dims));
                            });
                            pending.Add(action.GetProperty("lease").GetString()!, (name, acquisition));
                            await barrier.Started.Task.WaitAsync(TimeSpan.FromSeconds(15));
                            Assert.False(acquisition.IsCompleted);
                            break;
                        }
                        case "completeFill":
                        case "failFill":
                        {
                            string name = action.GetProperty("barrier").GetString()!;
                            var barrier = barriers[name];
                            if (operation == "failFill")
                                barrier.Resume.SetException(new InvalidOperationException(action.GetProperty("expectedError").GetString()));
                            else barrier.Resume.SetResult();
                            foreach (var pair in pending.Where(p => p.Value.Barrier == name).ToArray())
                            {
                                if (action.TryGetProperty("expectedError", out var error))
                                {
                                    var failure = await Assert.ThrowsAsync<InvalidOperationException>(async () =>
                                        await pair.Value.Task.WaitAsync(TimeSpan.FromSeconds(15)));
                                    Assert.Equal(error.GetString(), failure.Message);
                                }
                                else
                                {
                                    var lease = await pair.Value.Task.WaitAsync(TimeSpan.FromSeconds(15));
                                    AssertMode(action, lease);
                                    leases.Add(pair.Key, lease);
                                }
                                pending.Remove(pair.Key);
                            }
                            break;
                        }
                        case "release":
                            leases[action.GetProperty("lease").GetString()!]?.Dispose();
                            break;
                        case "invalidate":
                            cache.Invalidate(keys[action.GetProperty("key").GetString()!].DatabaseId);
                            break;
                        default: throw new InvalidOperationException($"Unhandled fixture action: {operation}");
                    }
                    var expected = action.GetProperty("expected");
                    var actual = cache.Statistics();
                    Assert.Equal(expected.GetProperty("residentBytes").GetInt64(), actual.ResidentBytes);
                    Assert.Equal(expected.GetProperty("reservedBytes").GetInt64(), actual.ReservedBytes);
                    Assert.Equal(expected.GetProperty("entryCount").GetInt32(), actual.EntryCount);
                    Assert.Equal(expected.GetProperty("loadCount").GetInt32(), actual.LoadCount);
                    Assert.Equal(expected.GetProperty("residentKeys").EnumerateArray().Select(x => keys[x.GetString()!]), cache.ResidentKeys());
                }
                Assert.Empty(pending);
            }
            finally
            {
                foreach (var lease in leases.Values) lease?.Dispose();
                foreach (var key in keys.Values) cache.Invalidate(key.DatabaseId);
            }
            Assert.Equal(0, cache.Statistics().ResidentBytes);
            Assert.Equal(0, cache.Statistics().ReservedBytes);
        }
        Assert.Equal(7, executed);
    }

    [Fact]
    public async Task FillCancellationAndSingleFlight()
    {
        var fixture = SharedFixtures.Json("contracts/retrieval-cache-v1.json");
        var key = Key(fixture.GetProperty("keys").GetProperty("A"));
        int rowCount = fixture.GetProperty("rowsPerMatrix").GetInt32(), dims = fixture.GetProperty("dims").GetInt32();
        long charge = fixture.GetProperty("chargedBytesPerMatrix").GetInt64();
        var cache = new VectorMatrixCache(fixture.GetProperty("budgetBytes").GetInt64());
        var barrier = new FillBarrier();
        int fills = 0;
        async Task Fill(VectorMatrixBuilder builder, CancellationToken ct)
        {
            Interlocked.Increment(ref fills);
            barrier.Started.TrySetResult();
            await barrier.Resume.Task.WaitAsync(ct);
            builder.Append(Rows(rowCount, dims));
        }
        using var cancelled = new CancellationTokenSource();
        var first = cache.AcquireAsync(key, rowCount, dims, () => 0, Fill, cancelled.Token);
        await barrier.Started.Task.WaitAsync(TimeSpan.FromSeconds(15));
        var second = cache.AcquireAsync(key, rowCount, dims, () => 0, Fill);
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await first.WaitAsync(TimeSpan.FromSeconds(15)));
        Assert.False(second.IsCompleted);
        Assert.Equal(1, Volatile.Read(ref fills));
        Assert.Equal(charge, cache.Statistics().ReservedBytes);
        barrier.Resume.SetResult();
        using var survivor = await second.WaitAsync(TimeSpan.FromSeconds(15));
        Assert.NotNull(survivor);
        Assert.Equal(1, cache.Statistics().LoadCount);
        Assert.Equal(0, cache.Statistics().ReservedBytes);
        Assert.Equal(charge, cache.Statistics().ResidentBytes);
        cache.Invalidate(key.DatabaseId);
        Assert.Equal(charge, cache.Statistics().ResidentBytes);
        survivor.Dispose(); survivor.Dispose();
        Assert.Equal(0, cache.Statistics().ResidentBytes);
        Assert.Throws<ObjectDisposedException>(() => survivor.TopK([1, 0], new HashSet<long> { 1 }, 1));

        // The final waiter cancels the fill; await its explicit completion/refund
        // diagnostic because waiter cancellation can precede the fill's finally.
        var lastBarrier = new FillBarrier();
        using var lastCancellation = new CancellationTokenSource();
        var abandoned = cache.AcquireAsync(key, rowCount, dims, () => 0, async (builder, ct) =>
        {
            lastBarrier.Started.TrySetResult();
            await lastBarrier.Resume.Task.WaitAsync(ct);
            builder.Append(Rows(rowCount, dims));
        }, lastCancellation.Token);
        await lastBarrier.Started.Task.WaitAsync(TimeSpan.FromSeconds(15));
        Assert.Equal(charge, cache.Statistics().ReservedBytes);
        lastCancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await abandoned.WaitAsync(TimeSpan.FromSeconds(15)));
        await cache.WhenIdleAsync().WaitAsync(TimeSpan.FromSeconds(15));
        Assert.Equal(0, cache.Statistics().ReservedBytes);
        Assert.Equal(0, cache.Statistics().ResidentBytes);
        Assert.Empty(cache.ResidentKeys());

        // Failed builders cannot grow beyond their reservation or retain it.
        await Assert.ThrowsAsync<InvalidOperationException>(() => cache.AcquireAsync(key, rowCount, dims, () => 0,
            (builder, _) => { builder.Append(Rows(rowCount + 1, dims)); return Task.CompletedTask; }));
        Assert.Equal(0, cache.Statistics().ReservedBytes);
        Assert.Equal(0, cache.Statistics().ResidentBytes);

        bool completedFill = false;
        var epochFailure = new InvalidOperationException("epochFailed");
        var actualFailure = await Assert.ThrowsAsync<InvalidOperationException>(() => cache.AcquireAsync(key, rowCount, dims,
            () => completedFill ? throw epochFailure : 0UL,
            (builder, _) => { builder.Append(Rows(rowCount, dims)); completedFill = true; return Task.CompletedTask; }));
        Assert.Same(epochFailure, actualFailure);
        Assert.Equal(0, cache.Statistics().ReservedBytes);
        Assert.Equal(0, cache.Statistics().ResidentBytes);
        Assert.Empty(cache.ResidentKeys());

        VectorMatrixBuilder? escapedBuilder = null;
        using var recovered = await cache.AcquireAsync(key, rowCount, dims, () => 0,
            (builder, _) => { escapedBuilder = builder; builder.Append(Rows(rowCount, dims)); return Task.CompletedTask; });
        Assert.NotNull(recovered);
        Assert.Throws<InvalidOperationException>(() => escapedBuilder!.Append([]));
        recovered.Dispose();
        cache.Invalidate(key.DatabaseId);
        Assert.Equal(0, cache.Statistics().ResidentBytes);
    }

    [Fact]
    public async Task StreamingAndCachedRankingAgree()
    {
        var cacheFixture = SharedFixtures.Json("contracts/retrieval-cache-v1.json");
        var rankCases = SharedFixtures.Json("contracts/retrieval-rank-v1.json").GetProperty("cases").EnumerateArray()
            .Where(c => c.TryGetProperty("rows", out _)).ToArray();
        foreach (var c in rankCases)
        {
            var input = c.GetProperty("rows").EnumerateArray().ToArray();
            var rows = input.Select(r => new VectorRow(new(r.GetProperty("chunkId").GetInt64(),
                r.GetProperty("sourceId").GetInt64(), r.GetProperty("revisionId").GetInt64(), r.GetProperty("ord").GetInt32()),
                Values(r, "vector", "float32Bits"))).ToArray();
            float[] query = Values(c, "query", "queryFloat32Bits");
            var permitted = input.Where(r => r.GetProperty("eligible").GetInt32() == 1).Select(r => r.GetProperty("sourceId").GetInt64()).ToHashSet();
            int dims = c.GetProperty("dims").GetInt32(), k = c.GetProperty("k").GetInt32();
            var key = new RetrievalCacheKey(c.GetProperty("name").GetString()!, 1, 90, 0);
            var modes = new List<IReadOnlyList<ScoredChunk>>();
            foreach (long budget in new[] { 0L, cacheFixture.GetProperty("budgetBytes").GetInt64() })
            {
                var cache = new VectorMatrixCache(budget);
                int fillCalls = 0;
                using var lease = await cache.AcquireAsync(key, rows.Length, dims, () => 0, (builder, _) =>
                {
                    fillCalls++;
                    // Feed bounded pages, never a second whole-matrix copy.
                    foreach (var row in rows) builder.Append([row]);
                    return Task.CompletedTask;
                });
                IReadOnlyList<ScoredChunk> found;
                if (budget == 0)
                {
                    Assert.Null(lease);
                    Assert.Equal(0, fillCalls);
                    var heap = MaskedVectorTopK.Create(query, dims, permitted, k);
                    if (heap is not null)
                        foreach (var row in rows)
                        {
                            var normalized = (float[])row.Values.Clone();
                            if (normalized.Length == dims && MaskedVectorTopK.Normalize(normalized, true))
                                heap.Offer(row.Reference, normalized);
                        }
                    found = heap?.Sorted() ?? [];
                }
                else
                {
                    Assert.NotNull(lease);
                    Assert.Equal(1, fillCalls);
                    found = lease.TopK(query, permitted, k);
                    Assert.Equal(c.TryGetProperty("invalidVectorCount", out var invalid) ? invalid.GetInt32() : 0, lease.InvalidVectorCount);
                }
                Assert.Equal(c.GetProperty("expectedIds").EnumerateArray().Select(x => x.GetInt64()), found.Select(x => x.Reference.ChunkId));
                var expectedScores = c.GetProperty("expectedScoreMicros").EnumerateArray().Select(x => x.GetInt64() / 1_000_000f).ToArray();
                for (int i = 0; i < expectedScores.Length; i++)
                    Assert.InRange(Math.Abs(found[i].Score - expectedScores[i]), 0, 0.000001f);
                modes.Add(found);
                cache.Invalidate(key.DatabaseId);
                lease?.Dispose();
                Assert.Equal(0, cache.Statistics().ResidentBytes);
                Assert.Equal(0, cache.Statistics().ReservedBytes);
            }
            Assert.Equal(modes[0].Select(r => r.Reference), modes[1].Select(r => r.Reference));
            for (int i = 0; i < modes[0].Count; i++)
                Assert.InRange(Math.Abs(modes[0][i].Score - modes[1][i].Score), 0, 0.000001f);
        }
        Assert.NotEmpty(rankCases);
    }

    private sealed class FillBarrier
    {
        internal TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource Resume { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private static RetrievalCacheKey Key(JsonElement key) => new(key.GetProperty("databaseId").GetString()!,
        key.GetProperty("notebookId").GetInt64(), key.GetProperty("generationId").GetInt64(), key.GetProperty("epoch").GetUInt64());

    private static IReadOnlyList<VectorRow> Rows(int count, int dims) => Enumerable.Range(0, count).Select(i =>
    {
        var vector = new float[dims]; vector[i % dims] = 1;
        return new VectorRow(new(i + 1, 1, 101, i), vector);
    }).ToArray();

    private static void AssertMode(JsonElement action, VectorMatrixLease? lease)
    {
        if (action.GetProperty("expectedMode").GetString() == "cached") Assert.NotNull(lease);
        else { Assert.Equal("stream", action.GetProperty("expectedMode").GetString()); Assert.Null(lease); }
    }

    private static float[] Values(JsonElement row, string valuesName, string bitsName)
    {
        if (row.TryGetProperty(valuesName, out var values)) return values.EnumerateArray().Select(v => v.GetSingle()).ToArray();
        if (row.TryGetProperty(bitsName, out var bits))
            return bits.EnumerateArray().Select(v => BitConverter.Int32BitsToSingle(unchecked((int)v.GetUInt32()))).ToArray();
        byte[] blob = Convert.FromHexString(row.GetProperty("blobHex").GetString()!);
        Assert.Equal(0, blob.Length % sizeof(float));
        return Enumerable.Range(0, blob.Length / sizeof(float)).Select(i =>
            BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(blob.AsSpan(i * sizeof(float), sizeof(float))))).ToArray();
    }
}

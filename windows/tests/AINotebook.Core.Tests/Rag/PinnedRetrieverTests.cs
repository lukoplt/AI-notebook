using System.Text.Json;
using AINotebook.Core.Eval;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public sealed class PinnedRetrieverTests
{
    private sealed class CountingEmbedder(Func<float[][]>? vectors = null) : IEmbeddingProducing
    {
        public int Calls;
        public string? Model;
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
        {
            Interlocked.Increment(ref Calls);
            Model = model;
            return Task.FromResult(vectors?.Invoke() ?? new[] { new float[] { 1, 0 } });
        }
    }

    private sealed class BarrierEmbedder : IEmbeddingProducing
    {
        public readonly TaskCompletionSource Started = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly TaskCompletionSource<float[][]> Result = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int Calls;
        public async Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
        {
            Interlocked.Increment(ref Calls);
            Started.TrySetResult();
            return await Result.Task.WaitAsync(ct);
        }
    }

    [Fact]
    public async Task NoActiveGenerationIsLexicalOnly()
    {
        using var store = RetrievalFixtureStore.Create("no-active");
        var client = new CountingEmbedder();
        var retriever = new Retriever(store, client, "m");
        using var pool = await retriever.SearchAsync(1, "needle", new RetrievalScope.All(), 2);
        Assert.Equal(new long[] { 1020, 4010 }, pool.Fused.Select(x => x.Reference.ChunkId).Order());
        Assert.Empty(pool.Vector);
        Assert.Equal("noActiveGeneration", pool.Diagnostics.VectorStatus);
        Assert.Equal(0, client.Calls);
        Assert.All(pool.Fused, x => Assert.Null(x.GenerationId));
    }

    [Fact]
    public async Task EmptyScopeDoesNothing()
    {
        using var store = RetrievalFixtureStore.Create();
        var client = new CountingEmbedder();
        var retriever = new Retriever(store, client, () => throw new InvalidOperationException("empty scope read model"));
        using var pool = await retriever.SearchAsync(1, "needle", new RetrievalScope.Selection(new HashSet<long>(), new HashSet<long>()), 32);
        Assert.Empty(pool.Fused); Assert.Null(pool.Snapshot);
        Assert.Equal(0, RetrievalFixtureStore.SqlStatementCount(store));
        Assert.Equal(0, client.Calls);
    }

    [Fact]
    public async Task PerBranchFetchKAndIntegerPool()
    {
        foreach (var c in RetrievalFixtureStore.Cases().Where(c => !c.TryGetProperty("events", out _) &&
            c.GetProperty("scope").GetProperty("kind").GetString() == "all"))
        {
            using var store = RetrievalFixtureStore.Create(c.GetProperty("name").GetString()!);
            var client = new CountingEmbedder();
            var retriever = new Retriever(store, client, "m");
            long notebook = c.GetProperty("notebookId").GetInt64();
            var published = Ids(c, "publishedChunkIds");
            var vectors = Ids(c, "vectorChunkIds");
            foreach (int fetchK in new[] { 1, 2, 32 })
            {
                using var pool = await retriever.SearchAsync(notebook, "needle", new RetrievalScope.All(), fetchK);
                Assert.Equal(Math.Min(fetchK, published.Length), pool.Lexical.Count);
                Assert.Equal(Math.Min(fetchK, vectors.Length), pool.Vector.Count);
                Assert.Subset(published.ToHashSet(), pool.Lexical.Select(x => x.Reference.ChunkId).ToHashSet());
                Assert.Subset(vectors.ToHashSet(), pool.Vector.Select(x => x.Reference.ChunkId).ToHashSet());
                foreach (var branch in new[] { pool.Lexical, pool.Vector })
                    Assert.Equal(branch.Select((_, i) => 1_000_000L / (60 + i + 1)), branch.Select(x => x.RrfMicro));
                // The complete integer union, no final truncation, from the same branch lists.
                var expected = RetrievalRanking.Fuse(pool.Lexical.Select(x => x.Reference).ToArray(), pool.Vector.Select(x => x.Reference).ToArray());
                Assert.Equal(expected.Select(x => (x.Reference, x.RrfMicro)), pool.Fused.Select(x => (x.Reference, x.RrfMicro)));
                Assert.True(pool.Fused.Count <= 2 * fetchK);
                long? generation = c.GetProperty("active").ValueKind == JsonValueKind.Null ? null : c.GetProperty("active").GetInt64();
                Assert.All(pool.Fused, x => Assert.Equal(generation, x.GenerationId));
                Assert.Equal(generation is null ? "noActiveGeneration" : "legacyEndpointUnverified", pool.Diagnostics.VectorStatus);
            }
            if (c.GetProperty("name").GetString() == "all")
            {
                using var pool = await retriever.SearchAsync(1, "needle", new RetrievalScope.All(), 32);
                // Ties: the vector branch orders equal scores by chunk ID; 4010 is in both branches.
                Assert.Equal(new long[] { 1010, 4010 }, pool.Vector.Select(x => x.Reference.ChunkId));
                Assert.Equal(4010, pool.Fused[0].Reference.ChunkId);
                // 4010 is second in both tied branches (lexical bm25 tie and vector score tie break by chunk ID).
                Assert.Equal(2 * (1_000_000L / 62), pool.Fused[0].RrfMicro);
                Assert.Equal(101, pool.Vector[0].Reference.RevisionId);
                Assert.Equal(102, pool.Lexical.Single(x => x.Reference.SourceId == 1).Reference.RevisionId);
            }
        }
    }

    [Fact]
    public async Task OneGenerationAndModelReadAcrossAwait()
    {
        foreach (string name in new[] { "switch-during-query", "publish-during-query" })
        {
            var c = RetrievalFixtureStore.Cases().Single(x => x.GetProperty("name").GetString() == name);
            using var store = RetrievalFixtureStore.Create(name);
            var client = new BarrierEmbedder();
            int reads = 0;
            string model = "m";
            var retriever = new Retriever(store, client, () => { Interlocked.Increment(ref reads); return model; });
            var run = retriever.SearchAsync(1, "needle", new RetrievalScope.All(), 32);
            await client.Started.Task.WaitAsync(TimeSpan.FromSeconds(15));
            model = "changed";
            RetrievalFixtureStore.ApplyEvent(name, store);
            client.Result.SetResult([[1, 0]]);
            using var pool = await run.WaitAsync(TimeSpan.FromSeconds(15));
            Assert.Equal(1, reads);
            Assert.Equal(1, client.Calls);
            Assert.Equal(Ids(c, "afterPublishedChunkIds"), pool.Lexical.Select(x => x.Reference.ChunkId).Order());
            Assert.Equal(Ids(c, "afterVectorChunkIds"), pool.Vector.Select(x => x.Reference.ChunkId).Order());
            Assert.All(pool.Fused, x => Assert.Equal(90, x.GenerationId));
            Assert.Equal(102, pool.Lexical.Single(x => x.Reference.ChunkId == 1020).Reference.RevisionId);
            Assert.Equal(101, pool.Vector.Single(x => x.Reference.ChunkId == 1010).Reference.RevisionId);
        }
    }

    [Fact]
    public async Task RevocationBeforeReturnRemovesStaleHits()
    {
        foreach (string name in new[] { "revoke-availability", "revoke-eligible", "revoke-membership", "join-membership" })
        {
            var c = RetrievalFixtureStore.Cases().Single(x => x.GetProperty("name").GetString() == name);
            var scope = RetrievalScopeJson.Deserialize(c.GetProperty("scope").GetRawText());
            foreach (int fetchK in new[] { 1, 32 })
            {
                using var store = RetrievalFixtureStore.Create(name);
                var retriever = new Retriever(store, new CountingEmbedder(), "m");
                int passes = 0;
                // Revoke after the first complete ranking pass, before the final mask check.
                retriever.AfterRankingPass = () => { if (Interlocked.Increment(ref passes) == 1) RetrievalFixtureStore.ApplyEvent(name, store); };
                using var pool = await retriever.SearchAsync(1, "needle", scope, fetchK);
                var after = Ids(c, "afterPublishedChunkIds").Concat(Ids(c, "afterVectorChunkIds")).ToHashSet();
                var before = Ids(c, "publishedChunkIds").Concat(Ids(c, "vectorChunkIds")).ToHashSet();
                // Masks only shrink: a newly joined source never enters a running turn.
                var allowed = after.Intersect(before).ToHashSet();
                Assert.Subset(allowed, pool.Fused.Select(x => x.Reference.ChunkId).ToHashSet());
                if (fetchK == 32) Assert.Equal(allowed, pool.Fused.Select(x => x.Reference.ChunkId).ToHashSet());
                else if (allowed.Count > 0)
                    // The next eligible row reaches topK in place of the revoked one.
                    Assert.Equal(new[] { allowed.Min() }, pool.Vector.Select(x => x.Reference.ChunkId));
                Assert.Equal(name == "join-membership" ? 1 : 2, passes);
            }
        }
    }

    [Fact]
    public async Task EmbeddingFailureFallsBackButCancellationThrows()
    {
        using (var store = RetrievalFixtureStore.Create())
        {
            var failing = new BarrierEmbedder();
            failing.Result.SetException(new InvalidOperationException("provider failed"));
            var pool = await new Retriever(store, failing, "m").SearchAsync(1, "needle", new RetrievalScope.All());
            Assert.Equal("embeddingFailed", pool.Diagnostics.VectorStatus);
            Assert.Empty(pool.Vector);
            Assert.Equal(new long[] { 1020, 4010 }, pool.Lexical.Select(x => x.Reference.ChunkId).Order());
            pool.Dispose(); pool.Dispose();
            // The legacy chat adapter keeps its historical contract and surfaces the provider failure.
            await Assert.ThrowsAsync<InvalidOperationException>(() => new Retriever(store, failing, "m").SearchAsync(1, "needle"));
            AssertNoPinRetained(store);
        }
        using (var store = RetrievalFixtureStore.Create())
        {
            var paused = new BarrierEmbedder();
            using var cancellation = new CancellationTokenSource();
            var run = new Retriever(store, paused, "m").SearchAsync(1, "needle", new RetrievalScope.All(), ct: cancellation.Token);
            await paused.Started.Task.WaitAsync(TimeSpan.FromSeconds(15));
            cancellation.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => run.WaitAsync(TimeSpan.FromSeconds(15)));
            AssertNoPinRetained(store);
        }
    }

    [Fact]
    public async Task LegacyAndEvalAdapters()
    {
        using (var store = RetrievalFixtureStore.Create())
        {
            var client = new CountingEmbedder();
            var retriever = new Retriever(store, client, "m");
            var all = await retriever.SearchAsync(1, "needle", topK: 8);
            Assert.Equal(new long[] { 1010, 1020, 4010 }, all.Select(x => x.ChunkId).Order());
            Assert.Equal(4010, all[0].ChunkId);
            Assert.Equal(2 * (1_000_000L / 62) / 1_000_000f, all[0].Score);
            Assert.Equal("needle revision 101", all.Single(x => x.ChunkId == 1010).Snippet);
            Assert.Single(await retriever.SearchAsync(1, "needle", topK: 1));
            Assert.Equal(new long[] { 1010, 1020 }, (await retriever.SearchAsync(1, "needle", 8, new long[] { 1 })).Select(x => x.ChunkId).Order());
            int statements = RetrievalFixtureStore.SqlStatementCount(store), calls = client.Calls;
            // Historical C# legacy contract: an explicit empty filter includes nothing and queries nothing.
            Assert.Empty(await retriever.SearchAsync(1, "needle", sourceIds: Array.Empty<long>()));
            Assert.Empty(await retriever.SearchAsync(1, "needle", topK: 0));
            var none = await retriever.CandidatesAsync(1, "needle", sourceIds: Array.Empty<long>());
            Assert.Empty(none.Lexical); Assert.Empty(none.Vector); Assert.Empty(none.Fused);
            Assert.Equal(statements, RetrievalFixtureStore.SqlStatementCount(store));
            Assert.Equal(calls, client.Calls);

            var candidates = await retriever.CandidatesAsync(1, "needle", fetchK: 1);
            Assert.Equal(new long[] { 1020 }, candidates.Lexical.Select(x => x.ChunkId));
            Assert.Equal(new long[] { 1010 }, candidates.Vector.Select(x => x.ChunkId));
            Assert.Equal(new long[] { 1010, 1020 }, candidates.Fused.Select(x => x.ChunkId));
            Assert.All(candidates.Fused, x => Assert.Equal(1_000_000 / 61, x.Score));
            var nullScope = await retriever.CandidatesAsync(1, "needle");
            Assert.Equal(3, nullScope.Fused.Count);
            Assert.Equal("invalid_fetch_k", (await Assert.ThrowsAsync<EvalFailure>(() => retriever.CandidatesAsync(1, "needle", 0))).Code);
            AssertNoPinRetained(store);
        }

        using (var store = new NotebookStore(StorePath.InMemory))
        {
            var nb = store.CreateNotebook("N", "").Id!.Value;
            var src = store.CreateSource(nb, SourceType.Text, "S", null, null).Id!.Value;
            string text = "needle " + string.Concat(Enumerable.Repeat("😀", 300));
            store.ReplaceChunks(src, [new(text, 1)]);
            var hit = Assert.Single(await new Retriever(store, new CountingEmbedder(), "m").SearchAsync(nb, "needle"));
            Assert.Equal(240, hit.Snippet.EnumerateRunes().Count());
            Assert.StartsWith("needle 😀", hit.Snippet);
        }
    }

    [Fact]
    public async Task InvalidLimitsAndMalformedQueryVector()
    {
        using (var store = RetrievalFixtureStore.Create())
        {
            var client = new CountingEmbedder();
            var retriever = new Retriever(store, client, "m");
            foreach (int fetchK in new[] { 0, -1 })
                Assert.Equal("invalidFetchK", (await Assert.ThrowsAsync<RetrievalException>(() =>
                    retriever.SearchAsync(1, "needle", new RetrievalScope.All(), fetchK))).Code);
            Assert.Equal(0, RetrievalFixtureStore.SqlStatementCount(store));
            Assert.Equal(0, client.Calls);
        }
        foreach (var vector in new[] { new float[] { 1, 0, 0 }, new float[] { 0, 0 }, new[] { float.NaN, 1 }, Array.Empty<float>() })
        {
            using var store = RetrievalFixtureStore.Create();
            var client = new CountingEmbedder(() => [vector]);
            using var pool = await new Retriever(store, client, "m").SearchAsync(1, "needle", new RetrievalScope.All());
            Assert.Equal("invalidQueryVector", pool.Diagnostics.VectorStatus);
            Assert.Empty(pool.Vector);
            Assert.Equal(new long[] { 1020, 4010 }, pool.Fused.Select(x => x.Reference.ChunkId).Order());
            Assert.Equal(1, client.Calls);
            Assert.Equal("invalid_embedding", (await Assert.ThrowsAsync<EvalFailure>(() =>
                new Retriever(store, client, "m").CandidatesAsync(1, "needle"))).Code);
        }

        var oversized = SharedFixtures.Json("contracts/retrieval-rank-v1.json").GetProperty("cases").EnumerateArray()
            .Single(x => x.GetProperty("name").GetString() == "oversized-generation");
        using (var store = RetrievalFixtureStore.Create())
        {
            lock (store.Gate)
            {
                using var tx = store.Connection.BeginTransaction();
                store.Connection.Execute("UPDATE index_generations SET state='retired' WHERE id=90", transaction: tx);
                store.Connection.Execute("""
                    INSERT INTO index_generations(id,notebook_id,provider_id,endpoint_revision,model,model_digest,dims,
                        normalization,query_format_version,doc_format_version,chunker_version,state,created_at)
                    VALUES(92,1,'legacy','legacy','m',NULL,$dims,'legacy','legacy','legacy','legacy','active','2026-01-01 00:00:00.000')
                    """, new { dims = oversized.GetProperty("dims").GetInt32() }, tx);
                store.Connection.Execute("INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state) VALUES(92,1,101,'done')", transaction: tx);
                tx.Commit();
            }
            var statements = new List<string>();
            var previous = store.RetrievalStatementExecuted;
            store.RetrievalStatementExecuted = sql => { lock (statements) statements.Add(sql); previous?.Invoke(sql); };
            var client = new CountingEmbedder();
            using var pool = await new Retriever(store, client, "m").SearchAsync(1, "needle", new RetrievalScope.All());
            Assert.Equal(oversized.GetProperty("expectedStatus").GetString(), pool.Diagnostics.VectorStatus);
            Assert.Equal(oversized.GetProperty("expectedEmbeddingCalls").GetInt32(), client.Calls);
            Assert.Equal(oversized.GetProperty("expectedBlobReads").GetInt32(), statements.Count(s => s.Contains("ce.embedding", StringComparison.Ordinal)));
            Assert.Empty(pool.Vector);
            Assert.NotEmpty(pool.Lexical);
        }

        // A modern identity cannot be embedded through a direct, non-session client.
        using (var store = RetrievalFixtureStore.Create())
        {
            lock (store.Gate)
            {
                using var tx = store.Connection.BeginTransaction();
                store.Connection.Execute("UPDATE index_generations SET state='retired' WHERE id=90", transaction: tx);
                store.Connection.Execute("""
                    INSERT INTO index_generations(id,notebook_id,provider_id,endpoint_revision,model,model_digest,dims,
                        normalization,query_format_version,doc_format_version,chunker_version,state,created_at)
                    VALUES(93,1,'p','abc','m',NULL,2,'l2','1','1','2','active','2026-01-01 00:00:00.000')
                    """, transaction: tx);
                store.Connection.Execute("INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state) VALUES(93,1,101,'done')", transaction: tx);
                tx.Commit();
            }
            var client = new CountingEmbedder();
            using var pool = await new Retriever(store, client, "p:m").SearchAsync(1, "needle", new RetrievalScope.All());
            Assert.Equal("embeddingSessionRequired", pool.Diagnostics.VectorStatus);
            Assert.Equal(0, client.Calls);
            Assert.All(pool.Fused, x => Assert.Equal(93, x.GenerationId));
            Assert.NotEmpty(pool.Lexical);
        }
    }

    [Fact]
    public async Task CachedAndStreamedScansAgreeAndReleaseMatrixLeases()
    {
        foreach (long budget in new[] { 0L, 1_000_000L })
        {
            using var store = RetrievalFixtureStore.Create();
            var cache = new VectorMatrixCache(budget);
            var retriever = new Retriever(store, new CountingEmbedder(), () => "m", cache, null);
            for (int run = 0; run < 2; run++)
            {
                using var pool = await retriever.SearchAsync(1, "needle", new RetrievalScope.All(), 32);
                Assert.Equal(new long[] { 1010, 4010 }, pool.Vector.Select(x => x.Reference.ChunkId));
                Assert.Equal(budget == 0, pool.Diagnostics.Streamed);
                Assert.True(pool.Diagnostics.PeakPageBytes > 0 || run == 1);
            }
            Assert.Equal(budget == 0 ? 0 : 1, cache.Statistics().LoadCount);
            Assert.Equal(budget == 0 ? 0 : 1, cache.Statistics().EntryCount);
            // Every matrix lease was released after scoring, independently of the pool.
            cache.Invalidate(store.RetrievalDatabaseId);
            Assert.Equal(0, cache.Statistics().ResidentBytes);
            Assert.Equal(0, cache.Statistics().ReservedBytes);
        }
    }

    private static long[] Ids(JsonElement c, string key) => c.GetProperty(key).EnumerateArray().Select(x => x.GetInt64()).Order().ToArray();

    // A leaked pin would retain retired generation 90 and its revision 101.
    private static void AssertNoPinRetained(NotebookStore store)
    {
        store.RetireGeneration(90);
        store.GarbageCollect(1);
        lock (store.Gate)
        {
            Assert.Equal(0, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM index_generations WHERE id=90"));
            Assert.Equal(0, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM source_revisions WHERE id=101"));
        }
    }
}

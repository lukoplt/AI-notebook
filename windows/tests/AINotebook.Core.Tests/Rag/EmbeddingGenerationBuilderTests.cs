using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using AINotebook.Core.Tests.Providers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public sealed class EmbeddingGenerationBuilderTests
{
    private static readonly JsonElement Root = SharedFixtures.Json("contracts/benchmark-run-v1.json");

    private static IEnumerable<JsonElement> Cases(string kind) =>
        Root.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("kind").GetString() == kind);

    private static int Requests;

    [Fact]
    public async Task StagingDoesNotActivateAndFailurePreservesActive()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebookId = store.CreateNotebook("benchmark").Id!.Value;
        long sourceId = store.CreateSource(notebookId, SourceType.Text, "one", null, null).Id!.Value;
        store.CommitForegroundRevision(sourceId, new RevisionDraft("hash", "needle", 1, 2), ScalarChunker.Chunk("needle"), 0, "fixture-extract");
        var identity = new GenerationIdentity("fixture", "fixture", "m", null, 2, "l2", "1", "1", "2");
        var first = await EmbeddingGenerationBuilder.StageAsync(store, notebookId, identity, () => 1,
            (inputs, ct) => { Assert.Equal(new[] { "needle" }, inputs); return Task.FromResult(new[] { new float[] { 1, 0 } }); });
        Assert.Null(store.ActiveGeneration(notebookId));
        Assert.Equal(new[] { "done" }, store.Manifest(first.Id).Select(x => x.State));
        store.ActivateGeneration(first.Id, 2);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => EmbeddingGenerationBuilder.StageAsync(
            store, notebookId, identity, () => 3, (inputs, ct) => throw new OperationCanceledException()));
        Assert.Equal(first.Id, store.ActiveGeneration(notebookId)!.Id);
        Assert.Equal(new[] { "needle" }, store.Chunks(sourceId).Select(x => x.Text));
    }

    private static string Hash(string text) => Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(text)));

    private static void Publish(NotebookStore store, long sourceId, string text, long now) =>
        store.CommitForegroundRevision(sourceId, new RevisionDraft(Hash(text), text, 1, 2), ScalarChunker.Chunk(text), now, "fixture-" + now);

    private static int VectorCount(NotebookStore store, long generationId)
    {
        lock (store.Gate)
            return store.Connection.ExecuteScalar<int>("SELECT count(*) FROM chunk_embeddings WHERE generation_id=$generationId", new { generationId });
    }

    [Fact]
    public async Task SharedStageCases()
    {
        int n = 0;
        foreach (var c in Cases("stage"))
        {
            string name = c.GetProperty("name").GetString()!;
            var expected = c.GetProperty("expected");
            var identity = OllamaBenchmarkClientTests.Identity(c.GetProperty("identity"));
            using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
            long notebookId = store.CreateNotebook("benchmark").Id!.Value;
            // The pre-existing active generation (fixture generation 1) on an empty corpus.
            var activeBefore = c.GetProperty("activeBefore");
            var active = store.CreateGeneration(notebookId, OllamaBenchmarkClientTests.Identity(activeBefore.GetProperty("identity")), 0);
            store.ActivateGeneration(active.Id, 0);
            Assert.Equal(activeBefore.GetProperty("generationId").GetInt64(), active.Id);
            var sourceIds = new Dictionary<long, long>();
            foreach (var s in c.GetProperty("sources").EnumerateArray())
            {
                // Fixture source IDs are ordinal; sources without a revision keep their slot.
                while (sourceIds.Count < s.GetProperty("sourceId").GetInt64())
                    sourceIds[sourceIds.Count + 1] = store.CreateSource(notebookId, SourceType.Text, "s", null, null).Id!.Value;
                long id = sourceIds[s.GetProperty("sourceId").GetInt64()];
                for (int r = 1; r <= s.GetProperty("publishedRevision").GetInt32(); r++) Publish(store, id, s.GetProperty("text").GetString()!, r);
                if (s.TryGetProperty("currentRevision", out var current) && current.GetInt32() > s.GetProperty("publishedRevision").GetInt32())
                    store.InsertRevision(id, new RevisionDraft(Hash("refresh"), "refresh", 1, 2), 5);
            }
            var publishedBefore = sourceIds.Values.ToDictionary(id => id, id => store.Source(id)!.PublishedRevisionId);
            var script = c.GetProperty("embedScript").EnumerateArray().ToArray();
            var events = c.GetProperty("events").EnumerateArray().ToArray();
            int requests = 0;
            Task<float[][]> Embed(IReadOnlyList<string> inputs, CancellationToken ct)
            {
                Assert.True(requests < script.Length, $"{name}: unscripted request");
                var step = script[requests++];
                Assert.Equal(step.GetProperty("inputs").EnumerateArray().Select(x => x.GetString()), inputs);
                foreach (var e in events.Where(e => e.GetProperty("kind").GetString() == "publishRevision"
                    && e.GetProperty("afterRequest").GetInt32() == requests))
                    Publish(store, sourceIds[e.GetProperty("sourceId").GetInt64()], e.GetProperty("text").GetString()!, 10 + requests);
                return step.GetProperty("outcome").GetString() switch
                {
                    "ok" => Task.FromResult(step.GetProperty("vectors").EnumerateArray().Select(EmbeddingProfileTests.Vector).ToArray()),
                    "cancel" => throw new OperationCanceledException(),
                    var o => throw new InvalidOperationException(o),
                };
            }
            string? error = null;
            IndexGeneration? staged = null;
            try
            {
                var sessionEvent = events.FirstOrDefault(e => e.GetProperty("kind").GetString() == "sessionIdentity");
                if (sessionEvent.ValueKind == JsonValueKind.Object)
                {
                    var session = new ProviderEmbeddingSession(new CountingClient(), identity.Model, "fixture:m", identity.EndpointRevision,
                        identity: OllamaBenchmarkClientTests.Identity(sessionEvent.GetProperty("identity")));
                    staged = await EmbeddingGenerationBuilder.StageAsync(store, notebookId, identity, session, () => 7);
                }
                else staged = await EmbeddingGenerationBuilder.StageAsync(store, notebookId, identity, () => 7, Embed);
            }
            catch (EmbeddingGenerationException e) { error = e.Code; }
            catch (OperationCanceledException) { error = "cancelled"; }
            Assert.True(expected.GetProperty("error").ValueKind == JsonValueKind.Null ? error is null
                : expected.GetProperty("error").GetString() == error, $"{name}: {error}");
            Assert.Equal(expected.GetProperty("embeddingRequests").GetInt32(), requests);
            Assert.Equal(expected.GetProperty("activeAfter").GetInt64(), store.ActiveGeneration(notebookId)!.Id);
            // The staged generation is the one created after the active fixture generation.
            var stagedRow = store.Generation(active.Id + 1);
            var stagedState = expected.GetProperty("stagedState");
            if (stagedState.ValueKind == JsonValueKind.Null) Assert.Null(stagedRow);
            else Assert.Equal(stagedState.GetString(), stagedRow!.State);
            if (staged is not null) Assert.Equal(stagedRow!.Id, staged.Id);
            Assert.Equal(expected.GetProperty("vectorsWritten").GetInt32(), stagedRow is null ? 0 : VectorCount(store, stagedRow.Id));
            if (expected.TryGetProperty("manifest", out var manifest))
                Assert.Equal(manifest.EnumerateArray().Select(m => (sourceIds[m.GetProperty("sourceId").GetInt64()], m.GetProperty("state").GetString())),
                    store.Manifest(staged!.Id).OrderBy(m => m.SourceId).Select(m => (m.SourceId, (string?)m.State)));
            bool unchanged = publishedBefore.All(kv => store.Source(kv.Key)!.PublishedRevisionId == kv.Value);
            Assert.Equal(expected.GetProperty("publishedRevisionsUnchanged").GetBoolean(), unchanged);
            n++;
        }
        Assert.Equal(7, n);
    }

    private sealed class CountingClient : IEmbeddingProducing
    {
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
        {
            Interlocked.Increment(ref Requests);
            return Task.FromResult(inputs.Select(_ => new float[] { 1, 0 }).ToArray());
        }
    }

    [Fact]
    public async Task PublicOverloadRequiresTheCapturedSessionIdentity()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebookId = store.CreateNotebook("benchmark").Id!.Value;
        long sourceId = store.CreateSource(notebookId, SourceType.Text, "one", null, null).Id!.Value;
        Publish(store, sourceId, "needle", 1);
        var identity = new GenerationIdentity("fixture", "fixture", "m", null, 2, "l2", "1", "1", "2");
        var legacy = new ProviderEmbeddingSession(new CountingClient(), "m", "m", "legacy", ProviderEmbeddingSession.LegacyEndpointUnverified);
        int before = Requests;
        var e = await Assert.ThrowsAsync<EmbeddingGenerationException>(() =>
            EmbeddingGenerationBuilder.StageAsync(store, notebookId, identity, legacy, () => 1));
        Assert.Equal("profileIdentityMismatch", e.Code);
        foreach (var other in new[] { identity with { ModelDigest = "sha256:" + new string('a', 64) }, identity with { Dims = 3 },
                     identity with { EndpointRevision = "other" } })
        {
            var session = new ProviderEmbeddingSession(new CountingClient(), "m", "fixture:m", other.EndpointRevision, identity: other);
            e = await Assert.ThrowsAsync<EmbeddingGenerationException>(() =>
                EmbeddingGenerationBuilder.StageAsync(store, notebookId, identity, session, () => 1));
            Assert.Equal("profileIdentityMismatch", e.Code);
        }
        Assert.Equal(before, Requests);
        Assert.Null(store.Generation(1));
        var matching = new ProviderEmbeddingSession(new CountingClient(), "m", "fixture:m", "fixture", identity: identity);
        var staged = await EmbeddingGenerationBuilder.StageAsync(store, notebookId, identity, matching, () => 1);
        Assert.Equal("building", staged.State);
        Assert.Equal(new[] { "done" }, store.Manifest(staged.Id).Select(x => x.State));
    }

    [Fact]
    public async Task ReuseActiveCopiesOnlyExactIdentityUnchangedSources()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebookId = store.CreateNotebook("benchmark").Id!.Value;
        long a = store.CreateSource(notebookId, SourceType.Text, "a", null, null).Id!.Value;
        long b = store.CreateSource(notebookId, SourceType.Text, "b", null, null).Id!.Value;
        Publish(store, a, "alpha", 1);
        Publish(store, b, "beta", 1);
        var identity = new GenerationIdentity("fixture", "fixture", "m", null, 2, "l2", "1", "1", "2");
        var inputs = new List<string>();
        Task<float[][]> Embed(IReadOnlyList<string> x, CancellationToken ct)
        {
            inputs.AddRange(x);
            return Task.FromResult(x.Select(_ => new float[] { 3, 4 }).ToArray());
        }
        var first = await EmbeddingGenerationBuilder.StageAsync(store, notebookId, identity, () => 1, Embed);
        store.ActivateGeneration(first.Id, 2);
        Assert.Equal(["alpha", "beta"], inputs);
        byte[] Bytes(long generationId, long sourceId)
        {
            lock (store.Gate)
                return store.Connection.QuerySingle<byte[]>("""
                    SELECT e.embedding FROM chunk_embeddings e JOIN source_chunks c ON c.id=e.chunk_id
                    WHERE e.generation_id=$generationId AND c.source_id=$sourceId
                    """, new { generationId, sourceId });
        }
        var unchangedBytes = Bytes(first.Id, a);

        Publish(store, b, "beta two", 3);
        inputs.Clear();
        var second = await EmbeddingGenerationBuilder.StageAsync(store, notebookId, identity, () => 4, Embed, reuseActive: true);
        Assert.Equal(["beta two"], inputs);
        Assert.Equal(unchangedBytes, Bytes(second.Id, a));
        Assert.All(store.Manifest(second.Id), m => Assert.Equal("done", m.State));
        store.ActivateGeneration(second.Id, 5);

        inputs.Clear();
        var other = identity with { DocFormatVersion = "wp7-other" };
        await EmbeddingGenerationBuilder.StageAsync(store, notebookId, other, () => 6, Embed, reuseActive: true);
        Assert.Equal(["alpha", "beta two"], inputs);
    }

    [Fact]
    public async Task ExistingGenerationMustMatchAndIsNeverRetiredByTheBuilder()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebookId = store.CreateNotebook("benchmark").Id!.Value;
        long sourceId = store.CreateSource(notebookId, SourceType.Text, "one", null, null).Id!.Value;
        Publish(store, sourceId, "needle", 1);
        var identity = new GenerationIdentity("fixture", "fixture", "m", null, 2, "l2", "1", "1", "2");
        var owned = store.CreateGeneration(notebookId, identity, 1);
        var wrong = store.CreateGeneration(notebookId, identity with { Dims = 3 }, 1);
        var e = await Assert.ThrowsAsync<EmbeddingGenerationException>(() => EmbeddingGenerationBuilder.StageAsync(store, notebookId, identity,
            () => 2, (x, ct) => Task.FromResult(new[] { new float[] { 1, 0 } }), existingGeneration: wrong));
        Assert.Equal("invalidGeneration", e.Code);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => EmbeddingGenerationBuilder.StageAsync(store, notebookId, identity,
            () => 2, (x, ct) => throw new OperationCanceledException(), existingGeneration: owned));
        Assert.Equal("building", store.Generation(owned.Id)!.State);
    }
}

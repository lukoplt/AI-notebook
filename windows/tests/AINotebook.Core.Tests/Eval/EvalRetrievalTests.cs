using System.Text.Json;
using AINotebook.Core.Eval;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Eval;

public sealed class EvalRetrievalTests
{
    [Fact]
    public async Task FetchKRetainsUnionAndLexicalMakesNoEmbeddingCall()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("eval").Id!.Value;
        var src = store.CreateSource(nb, SourceType.Text, "doc", null, null).Id!.Value;
        store.ReplaceChunks(src, [new("fox on shelf", 3), new("vector target", 2)]);
        var chunks = store.Chunks(src);
        store.StoreEmbedding(chunks[0].Id!.Value, "m", new([0, 1]));
        store.StoreEmbedding(chunks[1].Id!.Value, "m", new([1, 0]));
        var client = new MockEmbeddingClient(_ => [1, 0]);
        var retriever = new Retriever(store, client, "m");
        var hybrid = await retriever.CandidatesAsync(nb, "fox", fetchK: 1);
        Assert.Equal(chunks[0].Id!.Value, Assert.Single(hybrid.Lexical).ChunkId);
        Assert.Equal(chunks[1].Id!.Value, Assert.Single(hybrid.Vector).ChunkId);
        Assert.Equal(chunks.Select(c => c.Id!.Value), hybrid.Fused.Select(h => h.ChunkId));
        Assert.All(hybrid.Fused, h => Assert.Equal(1_000_000 / 61, h.Score));
        var calls = client.Calls.Count;
        var lexical = await retriever.CandidatesAsync(nb, "fox", fetchK: 1, includeVectors: false);
        Assert.Empty(lexical.Vector);
        Assert.Single(lexical.Fused);
        var empty = await retriever.CandidatesAsync(nb, "fox", sourceIds: []);
        Assert.Empty(empty.Lexical);
        Assert.Empty(empty.Vector);
        Assert.Empty(empty.Fused);
        Assert.Equal(calls, client.Calls.Count);
    }

    [Fact]
    public async Task SharedRetrievalCases()
    {
        var all = Cases().ToArray();
        Assert.Equal(28, all.Length);
        Assert.Equal(12, SharedFixtures.Json("contracts/eval-retrieval-v1.json").GetProperty("cases").GetArrayLength());
        Assert.Equal(10, all.Count(c => c.GetProperty("kind").GetString() == "metrics"));
        var visited = new HashSet<string>(StringComparer.Ordinal);
        foreach (var c in all.Where(c => c.GetProperty("kind").GetString() == "retrieval"))
        {
            Assert.True(visited.Add(c.GetProperty("name").GetString()!));
            await CheckRetrieval(c);
        }
        Assert.Equal(18, visited.Count);
    }

    // Every descendant is dispatched by its own kind, including metric children of retrieval cases.
    internal static IEnumerable<JsonElement> Cases()
    {
        static IEnumerable<JsonElement> Descendants(JsonElement c)
        {
            yield return c;
            if (c.TryGetProperty("subcases", out var subs))
                foreach (var sub in subs.EnumerateArray())
                    foreach (var value in Descendants(sub)) yield return value;
        }
        return SharedFixtures.Json("contracts/eval-retrieval-v1.json").GetProperty("cases")
            .EnumerateArray().SelectMany(Descendants);
    }

    private static float[] Vector(JsonElement v) => v.EnumerateArray()
        .Select(x => x.ValueKind == JsonValueKind.String && x.GetString() == "nan" ? float.NaN : x.GetSingle()).ToArray();

    private static async Task CheckRetrieval(JsonElement c)
    {
        var input = c.GetProperty("input");
        var expected = c.GetProperty("expected");
        var docs = input.GetProperty("documents").EnumerateArray().ToArray();
        var client = new FixtureEmbedder(input.TryGetProperty("query_vectors", out var batch)
            ? batch.EnumerateArray().Select(Vector).ToArray() : [Vector(input.GetProperty("query_vector"))]);
        using var store = new NotebookStore(StorePath.InMemory);
        var notebooks = docs.Select(d => d.GetProperty("notebook_id").GetInt64()).Distinct().Order()
            .ToDictionary(id => id, id => store.CreateNotebook($"nb-{id}").Id!.Value);
        var sources = new Dictionary<long, long>();
        var identities = new Dictionary<long, (string Document, int Ordinal)>();
        var vectors = new List<StoredEmbedding>();
        foreach (var d in docs)
        {
            var source = store.CreateSource(notebooks[d.GetProperty("notebook_id").GetInt64()], SourceType.Text,
                d.GetProperty("document_id").GetString()!, null, null).Id!.Value;
            sources.Add(d.GetProperty("source_id").GetInt64(), source);
            var chunks = d.GetProperty("chunks").EnumerateArray().ToArray();
            store.ReplaceChunks(source, chunks.Select(x => new ChunkDraft(x.GetProperty("text").GetString()!, 1)).ToArray());
            var persisted = store.Chunks(source);
            for (var i = 0; i < persisted.Count; i++)
            {
                var id = persisted[i].Id!.Value;
                identities.Add(id, (d.GetProperty("document_id").GetString()!, i));
                vectors.Add(new(id, source, new(Vector(chunks[i].GetProperty("vector")))));
            }
        }
        if (c.GetProperty("name").GetString() == "mismatched-stored-dimension")
        {
            // WP3 cannot activate mixed dimensions. Exercise the same diagnostic validation
            // boundary directly, retaining every frozen vector and the expected provider call.
            var embedded = await client.EmbedAsync("m", [input.GetProperty("query").GetString()!]);
            var error = Assert.Throws<EvalFailure>(() => Retriever.RankEvalVectors(embedded, vectors, null, 1));
            Assert.Equal(expected.GetProperty("error").GetString(), error.Code);
        }
        else
        {
            // Finish all chunk creation before vectors so the complete legacy generation can activate.
            foreach (var v in vectors) store.StoreEmbedding(v.ChunkId, "m", v.Vector);
            var scope = RetrievalScopeJson.Deserialize(input.GetProperty("scope").GetRawText());
            long[]? ids = scope is RetrievalScope.Selection selection
                ? docs.Where(d => selection.SourceIds.Contains(d.GetProperty("source_id").GetInt64()) ||
                    d.GetProperty("folder_id").ValueKind != JsonValueKind.Null && selection.FolderIds.Contains(d.GetProperty("folder_id").GetInt64()))
                    .Select(d => sources[d.GetProperty("source_id").GetInt64()]).ToArray() : null;
            var retriever = new Retriever(store, client, "m", input.GetProperty("rrf_k").GetInt32());
            var error = await Record.ExceptionAsync(async () =>
            {
                var actual = await retriever.CandidatesAsync(notebooks[input.GetProperty("notebook_id").GetInt64()],
                    input.GetProperty("query").GetString()!, input.GetProperty("fetch_k").GetInt32(), ids,
                    input.GetProperty("include_vectors").GetBoolean());
                foreach (var (key, hits) in new[] { ("lexical", actual.Lexical), ("vector", actual.Vector), ("fused", actual.Fused) })
                    Assert.Equal(expected.GetProperty(key).EnumerateArray().Select(x =>
                        (x.GetProperty("document_id").GetString()!, x.GetProperty("ordinal").GetInt32())), hits.Select(h => identities[h.ChunkId]));
            });
            if (expected.TryGetProperty("error", out var code)) Assert.Equal(code.GetString(), Assert.IsType<EvalFailure>(error).Code);
            else Assert.Null(error);
        }
        Assert.Equal(expected.GetProperty("embedding_calls").GetInt32(), client.Calls);
    }

    [Fact]
    public async Task NoActiveGenerationKeepsPublishedLexicalAndMakesNoProviderCall()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("eval").Id!.Value;
        var src = store.CreateSource(nb, SourceType.Text, "doc", null, null).Id!.Value;
        store.ReplaceChunks(src, [new("fox", 1), new("pending", 1)]);
        var chunks = store.Chunks(src);
        store.StoreEmbedding(chunks[0].Id!.Value, "m", new([1, 0]));
        Assert.Null(store.ActiveGeneration(nb));
        var client = new FixtureEmbedder([[1, 0]]);
        var hits = await new Retriever(store, client, "m").CandidatesAsync(nb, "fox");
        Assert.Equal(chunks[0].Id!.Value, Assert.Single(hits.Lexical).ChunkId);
        Assert.Empty(hits.Vector);
        Assert.Equal(0, client.Calls);
    }

    [Fact]
    public async Task QueryPinsModelAndRevisionAcrossEmbeddingAwait()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("eval").Id!.Value;
        var src = store.CreateSource(nb, SourceType.Text, "doc", null, null).Id!.Value;
        store.ReplaceChunks(src, [new("fox old", 2)]);
        var oldChunk = Assert.Single(store.Chunks(src)).Id!.Value;
        store.StoreEmbedding(oldChunk, "m", new([1, 0]));
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var model = "m";
        var reads = 0;
        var client = new PausedEmbedder(started, resume);
        var retriever = new Retriever(store, client, () => { reads++; return model; });
        var run = retriever.CandidatesAsync(nb, "fox", fetchK: 1);
        await started.Task;
        model = "next";
        store.ReplaceChunks(src, [new("fox new", 2)]);
        store.StoreEmbedding(Assert.Single(store.Chunks(src)).Id!.Value, "next", new([1, 0]));
        store.GarbageCollect(nb);
        resume.SetResult();
        var hits = await run;
        Assert.Equal(oldChunk, Assert.Single(hits.Lexical).ChunkId);
        Assert.Equal(oldChunk, Assert.Single(hits.Vector).ChunkId);
        Assert.Equal("m", client.Model);
        Assert.Equal(1, reads);
        Assert.True(store.GarbageCollect(nb).Chunks > 0);
    }

    private sealed class FixtureEmbedder(float[][] values) : IEmbeddingProducing
    {
        public int Calls { get; private set; }
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
        { Calls++; return Task.FromResult(values); }
    }

    private sealed class PausedEmbedder(TaskCompletionSource started, TaskCompletionSource resume) : IEmbeddingProducing
    {
        public string? Model { get; private set; }
        public async Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
        { Model = model; started.SetResult(); await resume.Task; return [[1, 0]]; }
    }
}

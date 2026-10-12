using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class RetrieverTests
{
    private static long AddChunk(NotebookStore store, long sourceId, string text)
    {
        // append a single chunk by re-reading existing chunks then replacing.
        var existing = store.Chunks(sourceId).Select(c => new ChunkDraft(c.Text, c.TokenCount, c.PageHint)).ToList();
        existing.Add(new ChunkDraft(text, 1, null));
        store.ReplaceChunks(sourceId, existing);
        return store.Chunks(sourceId).Last().Id!.Value;
    }

    // RetrieverTests.testReturnsTopKByCosineSimilarity
    [Fact]
    public async Task ReturnsTopKByCosineSimilarity()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "S", null, null);
        store.ReplaceChunks(src.Id!.Value, new[]
        {
            new ChunkDraft("alpha", 1, null),
            new ChunkDraft("beta", 1, null),
            new ChunkDraft("gamma", 1, null),
        });
        var chunks = store.Chunks(src.Id!.Value);
        store.StoreEmbedding(chunks[0].Id!.Value, "m", new EmbeddingVector(new[] { 1f, 0f }));
        store.StoreEmbedding(chunks[1].Id!.Value, "m", new EmbeddingVector(new[] { 0f, 1f }));
        store.StoreEmbedding(chunks[2].Id!.Value, "m", new EmbeddingVector(new[] { -1f, 0f }));

        var client = new MockEmbeddingClient(_ => new[] { 1f, 0f }); // query vector [1,0]
        var retriever = new Retriever(store, client, "m");
        var hits = await retriever.SearchAsync(nb.Id!.Value, "anything", topK: 2);

        Assert.Equal(2, hits.Count);
        Assert.Equal(chunks[0].Id!.Value, hits[0].ChunkId);
    }

    // RetrieverTests.testFTSAloneSurfacesTextMatchWhenNoEmbedding
    [Fact]
    public async Task FtsAloneSurfacesTextMatchWhenNoEmbedding()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "S", null, null);
        store.ReplaceChunks(src.Id!.Value, new[]
        {
            new ChunkDraft("the quick brown fox", 1, null),
            new ChunkDraft("unrelated content", 1, null),
        });
        // No embeddings stored.
        var client = new MockEmbeddingClient(_ => new[] { 0f, 0f });
        var retriever = new Retriever(store, client, "m");
        var hits = await retriever.SearchAsync(nb.Id!.Value, "fox", topK: 5);

        var foxId = store.Chunks(src.Id!.Value)[0].Id!.Value;
        Assert.Contains(hits, h => h.ChunkId == foxId);
    }

    // RetrieverTests.testRRFRanksFusedAboveSingleSourceMatch
    [Fact]
    public async Task RrfRanksFusedAboveSingleSourceMatch()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var a = store.CreateSource(nb.Id!.Value, SourceType.Text, "A", null, null);
        var b = store.CreateSource(nb.Id!.Value, SourceType.Text, "B", null, null);
        var c = store.CreateSource(nb.Id!.Value, SourceType.Text, "C", null, null);
        store.ReplaceChunks(a.Id!.Value, [new("the quick brown fox", 1)]);
        store.ReplaceChunks(b.Id!.Value, [new("a fox in the henhouse", 1)]);
        store.ReplaceChunks(c.Id!.Value, [new("unrelated text", 1)]);
        var aChunk = Assert.Single(store.Chunks(a.Id!.Value));
        var bChunk = Assert.Single(store.Chunks(b.Id!.Value));
        var cChunk = Assert.Single(store.Chunks(c.Id!.Value));
        var aId = aChunk.Id!.Value;
        var generation = store.CreateGeneration(nb.Id!.Value, new("legacy", "legacy", "m", null, 2, "legacy", "legacy", "legacy", "legacy"), 0);
        store.StoreGenerationEmbedding(generation.Id, aId, new([1f, 0f]));
        store.StoreGenerationEmbedding(generation.Id, cChunk.Id!.Value, new([0.9f, 0.1f]));
        store.SetManifest(generation.Id, [new(a.Id.Value, aChunk.RevisionId!.Value, "done", null),
            new(b.Id.Value, bChunk.RevisionId!.Value, "excluded", "test-lexical-only"), new(c.Id.Value, cChunk.RevisionId!.Value, "done", null)]);
        store.ActivateGeneration(generation.Id, 1);

        var client = new MockEmbeddingClient(_ => new[] { 1f, 0f });
        var retriever = new Retriever(store, client, "m");
        var hits = await retriever.SearchAsync(nb.Id!.Value, "fox", topK: 3);

        Assert.Equal(aId, hits[0].ChunkId);
        Assert.Contains(hits, hit => hit.ChunkId == cChunk.Id);
        Assert.Single(client.Calls);
    }

    // RetrieverTests.testSourceIdsFilterRestrictsToSelectedSources
    [Fact]
    public async Task SourceIdsFilterRestrictsToSelectedSources()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("NB", "");
        var a = store.CreateSource(nb.Id!.Value, SourceType.Text, "A", null, null);
        var b = store.CreateSource(nb.Id!.Value, SourceType.Text, "B", null, null);
        store.ReplaceChunks(a.Id!.Value, new[] { new ChunkDraft("fox in source A", 4, null) });
        store.ReplaceChunks(b.Id!.Value, new[] { new ChunkDraft("fox in source B", 4, null) });
        var aChunk = store.Chunks(a.Id!.Value)[0].Id!.Value;
        var bChunk = store.Chunks(b.Id!.Value)[0].Id!.Value;
        store.StoreEmbedding(aChunk, "m", new EmbeddingVector(new[] { 1f, 0f }));
        store.StoreEmbedding(bChunk, "m", new EmbeddingVector(new[] { 1f, 0f }));

        var client = new MockEmbeddingClient(_ => new[] { 1f, 0f });
        var retriever = new Retriever(store, client, "m");

        // No filter → both sources surface.
        var allHits = await retriever.SearchAsync(nb.Id!.Value, "fox", topK: 5);
        var allSources = allHits.Select(h => h.SourceId).ToHashSet();
        Assert.Contains(a.Id!.Value, allSources);
        Assert.Contains(b.Id!.Value, allSources);

        // Filter to A → only A's chunk.
        var filtered = await retriever.SearchAsync(nb.Id!.Value, "fox", topK: 5, sourceIds: new[] { a.Id!.Value });
        Assert.Equal(new[] { a.Id!.Value }, filtered.Select(h => h.SourceId).Distinct().ToArray());
        Assert.Equal(new[] { aChunk }, filtered.Select(h => h.ChunkId).Distinct().ToArray());
    }
}

using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class EmbedderTests
{
    // EmbedderTests.testEmbedAllInsertsRowsForEveryChunk
    [Fact]
    public async Task EmbedAllInsertsRowsForEveryChunkInBatches()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "S", null, null);
        store.ReplaceChunks(src.Id!.Value, new[]
        {
            new ChunkDraft("c0", 1, null), new ChunkDraft("c1", 1, null),
            new ChunkDraft("c2", 1, null), new ChunkDraft("c3", 1, null),
            new ChunkDraft("c4", 1, null),
        });

        var client = new MockEmbeddingClient();
        var embedder = new Embedder(store, client, "m", batchSize: 2);
        var written = await embedder.EmbedAllPendingAsync();

        Assert.Equal(5, written);
        Assert.Equal(0, store.UnembeddedChunks("m", 100).Count);
        Assert.Equal(3, client.Calls.Count);
        Assert.Equal(new[] { 2, 2, 1 }, client.Calls.Select(c => c.Length).ToArray());
    }

    // EmbedderTests.testEmbedAllSkipsAlreadyEmbedded
    [Fact]
    public async Task EmbedAllSkipsAlreadyEmbedded()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "S", null, null);
        store.ReplaceChunks(src.Id!.Value, new[]
        {
            new ChunkDraft("a", 1, null),
            new ChunkDraft("b", 1, null),
        });
        // Pre-embed the first chunk ('a') for model 'm'.
        var first = store.UnembeddedChunks("m", 1)[0];
        store.StoreEmbedding(first.Id!.Value, "m", new EmbeddingVector(new[] { 0.1f, 0.2f, 0.3f, 0.4f }));

        var client = new MockEmbeddingClient();
        var embedder = new Embedder(store, client, "m", batchSize: 10);
        var written = await embedder.EmbedAllPendingAsync();

        Assert.Equal(1, written);
        Assert.Single(client.Calls);
        Assert.Equal(new[] { "b" }, client.Calls[0]);
    }
}

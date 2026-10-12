using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
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
    [Fact]
    public async Task ExplicitProfileDrainSkipsRawLegacyTransport()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var raw = new RawCounter();
        var embedder = new Embedder(store, raw, () => "legacy-key",
            profileDrain: ct => Task.FromResult<int?>(7));
        Assert.Equal(7, await embedder.EmbedAllPendingAsync());
        Assert.Equal(0, raw.Calls);
    }

    [Fact]
    public async Task NullProfileDrainFallsThroughToUnchangedLegacyDrain()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "S", null, null);
        store.ReplaceChunks(src.Id!.Value, new[] { new ChunkDraft("a", 1, null) });
        var raw = new RawCounter();
        var embedder = new Embedder(store, raw, () => "legacy-key", profileDrain: ct => Task.FromResult<int?>(null));
        Assert.Equal(1, await embedder.EmbedAllPendingAsync());
        Assert.Equal(1, raw.Calls);
    }

    private sealed class RawCounter : IEmbeddingProducing
    {
        public int Calls;
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
        {
            Calls++;
            return Task.FromResult(inputs.Select(_ => new[] { 1f, 0f }).ToArray());
        }
    }
}

using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class NotebookStoreEmbeddingsTests
{
    private static (NotebookStore store, long nb, long src) Seed(int chunkCount)
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N").Id!.Value;
        var src = store.CreateSource(nb, SourceType.Text, "t", null, null).Id!.Value;
        var drafts = Enumerable.Range(0, chunkCount)
            .Select(i => new ChunkDraft($"chunk {i}", 1, null)).ToList();
        store.ReplaceChunks(src, drafts);
        return (store, nb, src);
    }

    [Fact]
    public void StoreAndLoadEmbedding()
    {
        var (store, nb, src) = Seed(2);
        using (store)
        {
            var chunks = store.Chunks(src);
            store.StoreEmbedding(chunks[0].Id!.Value, "m", new EmbeddingVector(new[] { 0.1f, -0.2f }));
            store.StoreEmbedding(chunks[1].Id!.Value, "m", new EmbeddingVector(new[] { 3.14f, -42.0f }));
            var loaded = store.Embeddings(nb, "m").OrderBy(e => e.ChunkId).ToList();
            Assert.Equal(2, loaded.Count);
            Assert.Equal(src, loaded[0].SourceId);
            Assert.Equal(new[] { 0.1f, -0.2f }, loaded[0].Vector.Values);
            Assert.Equal(new[] { 3.14f, -42.0f }, loaded[1].Vector.Values);
        }
    }

    [Fact]
    public void UnembeddedChunksReturnsOnlyMissingForModel()
    {
        var (store, _, src) = Seed(3);
        using (store)
        {
            var chunks = store.Chunks(src);
            store.StoreEmbedding(chunks[0].Id!.Value, "m", new EmbeddingVector(new[] { 1f }));
            var unembedded = store.UnembeddedChunks("m", 100);
            Assert.Equal(2, unembedded.Count);
            Assert.Equal(new[] { chunks[1].Id!.Value, chunks[2].Id!.Value },
                unembedded.Select(c => c.Id!.Value).ToArray());
            Assert.Equal(2, store.UnembeddedCount("m"));
        }
    }

    [Fact]
    public void ReplaceEmbeddingOverwrites()
    {
        var (store, nb, src) = Seed(1);
        using (store)
        {
            var chunkId = store.Chunks(src)[0].Id!.Value;
            store.StoreEmbedding(chunkId, "m", new EmbeddingVector(new[] { 9f, 9f }));
            store.StoreEmbedding(chunkId, "m", new EmbeddingVector(new[] { 0f, 1f }));
            var loaded = store.Embeddings(nb, "m");
            Assert.Single(loaded);
            Assert.Equal(new[] { 0f, 1f }, loaded[0].Vector.Values);
        }
    }

    [Fact]
    public void DeleteAllEmbeddingsForModelClearsOnlyThatModel()
    {
        var (store, nb, src) = Seed(1);
        using (store)
        {
            var chunkId = store.Chunks(src)[0].Id!.Value;
            store.StoreEmbedding(chunkId, "m1", new EmbeddingVector(new[] { 1f }));
            store.DeleteAllEmbeddings("m1");
            Assert.Empty(store.Embeddings(nb, "m1"));
        }
    }
}

using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Dapper;
using Xunit;
namespace AINotebook.Core.Tests.Rag;

/// <summary>retrieval-resident-v1: one resident binary16 matrix per generation, loaded per pinned
/// (source, revision) pair, kept across unrelated writes, extended incrementally.</summary>
public sealed class ResidentVectorMatrixTests
{
    private sealed class NoQueryEmbedding : IEmbeddingProducing
    {
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
            => throw new OperationCanceledException();
    }

    private static async Task<(long[] Ids, bool Streamed)> VectorIds(NotebookStore store, Retriever retriever, long notebookId, float[] query, int k = 4)
    {
        var snapshot = ScopeResolver.Resolve(store, notebookId, new RetrievalScope.All(), "synthetic")!;
        using var pool = await retriever.SearchEmbeddedAsync(snapshot, "", query, k);
        Assert.Equal("used", pool.Diagnostics.VectorStatus);
        return (pool.Vector.Select(x => x.Reference.ChunkId).ToArray(), pool.Diagnostics.Streamed);
    }

    [Fact]
    public async Task IncrementalLoadsSurviveUnrelatedWritesAndRevisionChanges()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var handle = SyntheticRetrievalCorpus.Populate(store, 300, 16);
        var cache = new VectorMatrixCache();
        var retriever = new Retriever(store, new NoQueryEmbedding(), () => "synthetic", cache, null);
        var probe = SyntheticRetrievalCorpus.Row(5, 16).Vector;
        // Off-axis query: one-hot corpus rows tie below it, rows stored along it score highest.
        var tilted = (float[])probe.Clone();
        tilted[(Array.IndexOf(probe, 1f) + 1) % 16] = 0.5f;
        var key = new ResidentMatrixKey(store.RetrievalDatabaseId, store.RetrievalInstanceId, handle.NotebookId, handle.GenerationId, 16);

        var first = await VectorIds(store, retriever, handle.NotebookId, probe);
        Assert.False(first.Streamed);
        Assert.Equal(4, first.Ids.Length);
        Assert.Equal(1, cache.Statistics().LoadCount);
        Assert.Equal(300 * (16 * 2 + 32), cache.Statistics().ResidentBytes);
        Assert.Equal(300, cache.ResidentRowCount(key));

        // Writes that do not change any pinned pair keep the matrix: no reload.
        store.CreateNotebook("unrelated", "");
        lock (store.Gate) store.Connection.Execute("UPDATE notebooks SET name='renamed' WHERE id=$id", new { id = handle.NotebookId });
        var second = await VectorIds(store, retriever, handle.NotebookId, probe);
        Assert.Equal(first.Ids, second.Ids);
        Assert.Equal(1, cache.Statistics().LoadCount);

        // A new published revision of the first source: only that pair loads; its old rows
        // become garbage and are never returned again.
        long firstSource;
        long[] oldIds;
        lock (store.Gate)
        {
            firstSource = store.Connection.ExecuteScalar<long>("SELECT min(id) FROM sources WHERE notebook_id=$nb", new { nb = handle.NotebookId });
            oldIds = store.Connection.Query<long>("SELECT id FROM source_chunks WHERE source_id=$s", new { s = firstSource }).ToArray();
        }
        string[] texts = ["fresh one", "fresh two", "fresh 333"];
        var revision = store.CommitForegroundRevision(firstSource,
            new RevisionDraft("fresh", string.Join("\n", texts), 1, 2),
            texts.Select((t, i) => new RevisionChunkDraft(t, 2, null, i * 10, i * 10 + 9, null, false)).ToArray(), 1, "resident-test");
        long[] newIds;
        lock (store.Gate)
        {
            newIds = store.Connection.Query<long>("SELECT id FROM source_chunks WHERE revision_id=$r ORDER BY ord", new { r = revision.Id }).ToArray();
            // An active generation's incremental update, written directly as the shared fixtures do.
            foreach (long id in newIds)
                store.Connection.Execute("INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES ($c,$g,$e)",
                    new { c = id, g = handle.GenerationId, e = new EmbeddingVector(tilted).ToBytes() });
            store.Connection.Execute("UPDATE index_generation_manifest SET revision_id=$r,state='done' WHERE generation_id=$g AND source_id=$s",
                new { r = revision.Id, g = handle.GenerationId, s = firstSource });
        }
        var third = await VectorIds(store, retriever, handle.NotebookId, tilted, 8);
        Assert.Equal(newIds, third.Ids.Take(3));
        Assert.Empty(third.Ids.Intersect(oldIds));
        Assert.Equal(2, cache.Statistics().LoadCount);
        Assert.Equal(303, cache.ResidentRowCount(key));

        // Over budget: the same answer streams.
        var tiny = new Retriever(store, new NoQueryEmbedding(), () => "synthetic", new VectorMatrixCache(1_000), null);
        var streamed = await VectorIds(store, tiny, handle.NotebookId, tilted, 8);
        Assert.True(streamed.Streamed);
        Assert.Equal(third.Ids, streamed.Ids);
    }

    [Fact]
    public void BudgetScalesWithPhysicalMemory()
    {
        Assert.Equal(RagContractV1.Cache.GlobalBudgetBytes, VectorMatrixCache.ResidentBudget(8L << 30));
        Assert.Equal(1L << 30, VectorMatrixCache.ResidentBudget(16L << 30));
        Assert.Equal(1L << 30, VectorMatrixCache.ResidentBudget(64L << 30));
        Assert.Equal(RagContractV1.Cache.GlobalBudgetBytes, VectorMatrixCache.ResidentBudget(0));
    }
}

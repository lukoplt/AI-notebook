using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>Store-level <c>embedding-plan-v1</c> behaviour beyond the shared build cases.</summary>
public sealed class EmbeddingPlanStoreTests : IDisposable
{
    private readonly EmbeddingPlanContractTests.RecordingOllama _handler = new();
    private readonly HttpClient _http;
    private readonly FolderEmbeddingSession _session;
    private readonly EmbeddingSelection _selection;

    public EmbeddingPlanStoreTests()
    {
        _http = new HttpClient(_handler);
        _session = new FolderEmbeddingSession(new ProviderConfig("local", ProviderType.Ollama, "Local", "http://localhost:11434",
            true, false, DateTime.UnixEpoch), "m", null, null, "1", "1", _http);
        _selection = _session.Selection with { Dims = 3 };
    }

    public void Dispose() => _http.Dispose();

    private static (NotebookStore Store, long Notebook) MakeStore(object[] sources)
    {
        var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebook = store.CreateNotebook("plan").Id!.Value;
        EmbeddingPlanContractTests.Seed(store, notebook, JsonSerializer.SerializeToElement(sources));
        return (store, notebook);
    }

    private async Task Build(NotebookStore store, long notebook, bool copyExisting = false)
    {
        long jobId = store.RequestEmbeddingBuild(notebook, _selection, copyExisting, 1);
        string token = $"build-{jobId}";
        var job = store.ClaimJob(1, token, jobId)!;
        var coordinator = new FolderIndexCoordinator(store, new IngestionAdmission(), new EmbeddingPlanContractTests.PlanClock(),
            (_, _) => Task.FromResult<FolderEmbeddingSession?>(_session), _ => Task.FromResult<EmbeddingSelection?>(_selection));
        await coordinator.ExecuteAsync(job, new JobFence(jobId, token));
    }

    private (long GenerationId, JobFence Fence) Claim(NotebookStore store, long notebook)
    {
        long jobId = store.RequestEmbeddingBuild(notebook, _selection, copyExisting: false, 1);
        string target = store.Job(jobId)!.Draft.Target;
        store.ClaimJob(1, "owner", jobId);
        return (long.Parse(target["generation:".Length..], System.Globalization.CultureInfo.InvariantCulture), new JobFence(jobId, "owner"));
    }

    /// <summary>
    /// Capped spreadsheet chunks are full-text only: the source is done, the notebook needs no embedding, the status is
    /// ready, and the query pin serves the source's 64 vectors.
    /// </summary>
    [Fact]
    public async Task CappedSpreadsheetIsIndexedNotMissing()
    {
        var (store, notebook) = MakeStore([new { id = 1, type = "xlsx", chunks = Enumerable.Range(0, 100).Select(n => $"row {n}").ToArray() }]);
        using var _ = store;
        await Build(store, notebook);
        Assert.Equal([64], _handler.Calls.Select(c => c.Length));
        var active = store.ActiveGeneration(notebook)!;
        Assert.Equal(["done"], store.Manifest(active.Id).Select(e => e.State));
        Assert.False(store.NotebookNeedsEmbedding(notebook));
        Assert.Equal(IndexingPhase.Ready, store.IndexingStatus(notebook, 5).Phase);
        var pin = store.PinQuery(notebook, "local:m");
        try
        {
            Assert.True(pin.VectorRevisions.ContainsKey(1));
            Assert.Equal(64, store.PinnedEmbeddings(pin).Count);
        }
        finally { store.ReleaseQuery(pin); }
        Assert.Equal([99L], store.Connection.Query<long>("""
            SELECT c.ord FROM chunks_fts JOIN source_chunks c ON c.id=chunks_fts.chunk_id WHERE chunks_fts MATCH '"row 99"'
            """));
    }

    /// <summary>
    /// A source re-published behind the keyset cursor is picked up in the next round: reconciling changed the
    /// manifest, so the walk restarts from the beginning.
    /// </summary>
    [Fact]
    public void CursorResetsWhenTheManifestChanges()
    {
        var (store, notebook) = MakeStore([new { id = 1, type = "text", chunks = new[] { "a1" } }, new { id = 2, type = "text", chunks = new[] { "b1", "b2" } }]);
        using var _ = store;
        var (generationId, fence) = Claim(store, notebook);
        var first = store.CaptureEmbeddingRound(generationId, 2, null, fence, 2)!;
        Assert.Equal(["a1", "b1"], first.Items.Select(i => i.Text));
        Assert.Equal(new EmbeddingCursor(0, 2, 0), first.Cursor);
        Assert.True(store.CommitEmbeddingBatch(generationId, first.Items.Select(i => i.ChunkId).ToArray(),
            first.Items.Select(i => i.RevisionId).ToArray(), [[1, 0, 0], [0, 1, 0]], fence, 2));
        store.CommitForegroundRevision(1, new RevisionDraft("new", "a new", 1, 2), ScalarChunker.Chunk("a new"), 2, "republish");
        var second = store.CaptureEmbeddingRound(generationId, 2, first.Cursor, fence, 2)!;
        Assert.True(second.Reset);
        Assert.Equal(["a new", "b2"], second.Items.Select(i => i.Text));
        var third = store.CaptureEmbeddingRound(generationId, 2, second.Cursor, fence, 2)!;
        Assert.False(third.Reset);
        Assert.Empty(third.Items);
        Assert.Null(store.CaptureEmbeddingRound(generationId, 2, null, new JobFence(fence.JobId, "other"), 2));
    }

    /// <summary>Copies count separately in progress while the build runs; done still reaches total.</summary>
    [Fact]
    public void ProgressCountsCopiedVectors()
    {
        var (store, notebook) = MakeStore([new { id = 1, type = "text", chunks = new[] { "same", "x" } }, new { id = 2, type = "text", chunks = new[] { "same" } }]);
        using var _ = store;
        var (generationId, fence) = Claim(store, notebook);
        var round = store.CaptureEmbeddingRound(generationId, 1, null, fence, 2)!;
        Assert.Equal(["same"], round.Items.Select(i => i.Text));
        Assert.Empty(round.Joined);
        Assert.True(store.CommitEmbeddingBatch(generationId, round.Items.Select(i => i.ChunkId).ToArray(),
            round.Items.Select(i => i.RevisionId).ToArray(), [[1, 2, 2]], fence, 2));
        var next = store.CaptureEmbeddingRound(generationId, 1, round.Cursor, fence, 2)!;
        Assert.Equal(["x"], next.Items.Select(i => i.Text));
        Assert.Equal(1, next.Copied);
        Assert.Equal(1, store.GenerationProgress(notebook).Copied);
        var status = store.IndexingStatus(notebook, 2);
        Assert.Equal((IndexingPhase.Embedding, 2, 3), (status.Phase, status.Done, status.Total));
        var blobs = store.Connection.Query<byte[]>("""
            SELECT e.embedding FROM chunk_embeddings e JOIN source_chunks c ON c.id=e.chunk_id WHERE c.text='same' ORDER BY c.id
            """).ToArray();
        Assert.Equal(2, blobs.Length);
        Assert.Equal(blobs[0], blobs[1]);
    }

    /// <summary>
    /// An incremental build carries the ledger of copied unchanged vectors, so a new source whose text the active index
    /// already embedded costs no provider call.
    /// </summary>
    [Fact]
    public async Task IncrementalBuildDedupsAgainstCarriedVectors()
    {
        var (store, notebook) = MakeStore([new { id = 1, type = "xlsx", chunks = new[] { "Header", "Row" } }]);
        using var _ = store;
        await Build(store, notebook);
        long first = store.ActiveGeneration(notebook)!.Id;
        EmbeddingPlanContractTests.Seed(store, notebook, JsonSerializer.SerializeToElement(new object[]
            { new { id = 2, type = "xlsx", chunks = new[] { "Header", "Row", "New" } } }));
        int before = _handler.Calls.Count;
        await Build(store, notebook, copyExisting: true);
        Assert.Equal([["New"]], _handler.Calls.Skip(before));
        long second = store.ActiveGeneration(notebook)!.Id;
        Assert.NotEqual(first, second);
        Assert.Equal(3, store.Connection.ExecuteScalar<int>(
            "SELECT count(*) FROM generation_text_hashes WHERE generation_id=$second AND copied=0", new { second }));
        Assert.Equal(2, store.Connection.ExecuteScalar<int>(
            "SELECT count(*) FROM generation_text_hashes WHERE generation_id=$second AND copied=1", new { second }));
    }
}

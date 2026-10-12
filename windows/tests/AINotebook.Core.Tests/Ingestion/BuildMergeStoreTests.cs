using System.Net;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary><c>ingestion-build-merge-v1</c> and <c>indexing-status-v1</c> §8 through the real store, coordinator and runtime.</summary>
public sealed class BuildMergeStoreTests : IDisposable
{
    private readonly HookedOllama _handler = new();
    private readonly HttpClient _http;
    private readonly FolderEmbeddingSession _session;

    public BuildMergeStoreTests()
    {
        _http = new HttpClient(_handler);
        _session = new FolderEmbeddingSession(new ProviderConfig("ollama", ProviderType.Ollama, "Ollama", "http://localhost:11434",
            true, false, DateTime.UnixEpoch), "nomic-embed-text", null, null, "2", "2", _http);
    }

    public void Dispose() => _http.Dispose();

    /// <summary>A raw provider: dimensions unknown until the first response.</summary>
    private EmbeddingSelection Raw => _session.Selection;
    private GenerationIdentity Identity => IngestionGenerationSQL.Identity(Raw, 3);

    private static (NotebookStore Store, long Notebook) NewStore(int sources)
    {
        var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebook = store.CreateNotebook("merge").Id!.Value;
        Seed(store, notebook, Enumerable.Range(1, sources).Select(id => (id, $"chunk text {id}")));
        return (store, notebook);
    }

    private static void Seed(NotebookStore store, long notebook, IEnumerable<(int Id, string Chunk)> sources) =>
        EmbeddingPlanContractTests.Seed(store, notebook, JsonSerializer.SerializeToElement(
            sources.Select(s => new { id = s.Id, type = "text", chunks = new[] { s.Chunk } }).ToArray()));

    private long Bootstrap(NotebookStore store, long notebook, bool copyExisting = true) =>
        store.EnqueueJob(new IngestJobDraft("embed", $"notebook:{notebook}", null,
            IngestionGenerationSQL.SerializeOptions(Raw, copyExisting)), 1);

    private static long GenerationCount(NotebookStore store, long notebook)
    {
        lock (store.Gate)
            return store.Connection.ExecuteScalar<long>("SELECT count(*) FROM index_generations WHERE notebook_id=$notebook", new { notebook });
    }

    private static string[] UnfinishedEmbedJobs(NotebookStore store)
    {
        lock (store.Gate)
            return store.Connection.Query<string>("""
                SELECT target FROM ingest_jobs WHERE kind='embed' AND (state IN ('queued','running','paused')
                  OR (state='failed' AND attempts<5 AND next_retry_at IS NOT NULL)) ORDER BY id
                """).ToArray();
    }

    private FolderIndexCoordinator Coordinator(NotebookStore store) =>
        new(store, new IngestionAdmission(), new EmbeddingPlanContractTests.PlanClock(),
            (_, _) => Task.FromResult<FolderEmbeddingSession?>(_session), _ => Task.FromResult<EmbeddingSelection?>(Raw))
        { BatchSize = 1 };

    private static async Task RunAsync(NotebookStore store, FolderIndexCoordinator coordinator, long jobId, string lease)
    {
        var job = store.ClaimJob(2, lease, jobId) ?? throw new InvalidOperationException("claim");
        await coordinator.ExecuteAsync(job, new JobFence(jobId, lease));
    }

    private static (IndexingPhase, int?, int?, bool) Phase(IndexingStatus status) => (status.Phase, status.Done, status.Total, status.Preparing);

    // ---------------------------------------------------------------- indexing-status-v1 §8

    /// <summary>The reported database: generation 1 building with its running job, a bootstrap queued behind it.</summary>
    [Fact]
    public void RunningBuildIsNotHiddenByQueuedBootstrap()
    {
        var (store, notebook) = NewStore(2);
        using var _ = store;
        long generation = store.RequestReindex(notebook, Identity, 1);
        long jobId = store.GenerationProgress(notebook).JobId!.Value;
        Assert.NotNull(store.ClaimJob(2, "build", jobId));
        Bootstrap(store, notebook);
        Assert.Equal((IndexingPhase.Embedding, 0, 2, false), Phase(store.IndexingStatus(notebook, 2)));
        var progress = store.GenerationProgress(notebook);
        Assert.False(progress.Preparing);
        Assert.Equal(jobId, progress.JobId);
        Assert.Equal(generation, progress.GenerationId);
    }

    /// <summary>After a restart the build job is queued again; the newer bootstrap still reports the build's progress.</summary>
    [Fact]
    public void QueuedBootstrapReportsBuildingGenerationProgress()
    {
        var (store, notebook) = NewStore(2);
        using var _ = store;
        store.RequestReindex(notebook, Identity, 1);
        Bootstrap(store, notebook);
        Assert.Equal((IndexingPhase.Embedding, 0, 2, false), Phase(store.IndexingStatus(notebook, 2)));
        Assert.False(store.GenerationProgress(notebook).Preparing);
    }

    [Fact]
    public void BootstrapWithoutGenerationStillPrepares()
    {
        var (store, notebook) = NewStore(1);
        using var _ = store;
        store.RequestEmbeddingBuild(notebook, Raw, copyExisting: true, 1);
        Assert.Equal((IndexingPhase.Embedding, (int?)null, (int?)null, true), Phase(store.IndexingStatus(notebook, 2)));
        Assert.True(store.GenerationProgress(notebook).Preparing);
    }

    // ---------------------------------------------------------------- ingestion-build-merge-v1 §2–3

    [Fact]
    public void RawBuildRequestJoinsBuildingGeneration()
    {
        var (store, notebook) = NewStore(2);
        using var _ = store;
        long generation = store.RequestReindex(notebook, Identity, 1);
        long jobId = store.GenerationProgress(notebook).JobId!.Value;
        Assert.NotNull(store.ClaimJob(2, "build", jobId));
        Assert.Equal(jobId, store.RequestEmbeddingBuild(notebook, Raw, copyExisting: true, 2));
        Assert.Equal([$"generation:{generation}"], UnfinishedEmbedJobs(store));
        Assert.Equal(1, GenerationCount(store, notebook));
    }

    [Fact]
    public void GenerationJobSupersedesQueuedBootstraps()
    {
        var (store, notebook) = NewStore(2);
        using var _ = store;
        long early = Bootstrap(store, notebook);
        long reindex = Bootstrap(store, notebook, copyExisting: false);
        long generation = store.RequestReindex(notebook, Identity, 1);
        Assert.Equal("done", store.Job(early)!.State);
        Assert.Null(store.Job(early)!.Error);
        Assert.Equal("queued", store.Job(reindex)!.State);
        Assert.Equal([$"notebook:{notebook}", $"generation:{generation}"], UnfinishedEmbedJobs(store));
    }

    [Fact]
    public async Task RawBuildRequestBesideActiveSpaceSkipsBootstrap()
    {
        var (store, notebook) = NewStore(2);
        using var _ = store;
        await RunAsync(store, Coordinator(store), store.RequestEmbeddingBuild(notebook, Raw, copyExisting: true, 1), "first");
        Assert.Equal(Identity, store.ActiveGeneration(notebook)!.Identity);
        Seed(store, notebook, [(3, "new")]);
        store.RequestEmbeddingBuild(notebook, Raw, copyExisting: true, 3);
        var pending = UnfinishedEmbedJobs(store);
        Assert.Single(pending);
        Assert.StartsWith("generation:", pending[0]);
    }

    // ---------------------------------------------------------------- ingestion-build-merge-v1 §4

    [Fact]
    public void StartupMergesBootstrapIntoBuildingGeneration()
    {
        var (store, notebook) = NewStore(2);
        using var _ = store;
        long generation = store.RequestReindex(notebook, Identity, 1);
        long legacy = Bootstrap(store, notebook);
        Assert.Equal(1, store.MergeRedundantBootstraps(2));
        Assert.Equal("done", store.Job(legacy)!.State);
        Assert.Equal([$"generation:{generation}"], UnfinishedEmbedJobs(store));
        Assert.Equal(1, GenerationCount(store, notebook));
        Assert.Equal(0, store.MergeRedundantBootstraps(2));
    }

    [Fact]
    public async Task StartupCompletesBootstrapOfCurrentActiveSpace()
    {
        var (store, notebook) = NewStore(2);
        using var _ = store;
        await RunAsync(store, Coordinator(store), store.RequestEmbeddingBuild(notebook, Raw, copyExisting: true, 1), "first");
        long legacy = Bootstrap(store, notebook);
        long reindex = Bootstrap(store, notebook, copyExisting: false);
        Assert.Equal(1, store.MergeRedundantBootstraps(2));
        Assert.Equal("done", store.Job(legacy)!.State);
        Assert.Equal("queued", store.Job(reindex)!.State);
        Assert.Equal(1, GenerationCount(store, notebook));
    }

    [Fact]
    public async Task RuntimeStartMergesLegacyBootstrap()
    {
        var (store, notebook) = NewStore(2);
        using var _ = store;
        long generation = store.RequestReindex(notebook, Identity, 1);
        long legacy = Bootstrap(store, notebook);
        var fs = new NativeFolderFileSystem();
        var admission = new IngestionAdmission();
        var clock = new EmbeddingPlanContractTests.PlanClock();
        var extractor = new BoundedDocumentExtractor();
        Func<long, Task<EmbeddingSelection?>> selected = _ => Task.FromResult<EmbeddingSelection?>(Raw);
        var runtime = new FolderIngestionRuntime(store, new FolderScanner(store, fs, UnicodeTables.LoadBundled(), clock),
            new FolderExtractionWorker(store, fs, LanguageDetector.Unavailable, clock, selected,
                (uri, type, rules, ct) => extractor.ExtractAsync(uri, type, rules, ct)),
            Coordinator(store), new JobQueue(store, clock, admission), clock, admission, new SilentWatches(), identity: fs,
            selectedSelection: selected, embeddingAvailability: _ => Task.FromResult(EmbeddingAvailability.Ready))
        { AutoDispatch = false };
        await runtime.StartAsync();
        Assert.Equal("done", store.Job(legacy)!.State);
        Assert.Equal([$"generation:{generation}"], UnfinishedEmbedJobs(store));
        for (int i = 0; i < 20 && await runtime.DrainOnceAsync(); i++) { }
        await runtime.StopAsync();
        Assert.Equal(generation, store.ActiveGeneration(notebook)!.Id);
        Assert.Equal(1, GenerationCount(store, notebook));
        Assert.Empty(UnfinishedEmbedJobs(store));
    }

    // ---------------------------------------------------------------- end to end

    /// <summary>
    /// A raw-provider build in progress, a publication arrives: one generation, one activation, "Indexing d / t"
    /// throughout and the new source covered.
    /// </summary>
    [Fact]
    public async Task PublicationDuringRawBuildActivatesOnce()
    {
        var (store, notebook) = NewStore(3);
        using var _ = store;
        var phases = new List<(IndexingPhase, int?, int?, bool)>();
        var jobs = new List<long>();
        string[] pending = [];
        _handler.HookAt = 2;
        _handler.Hook = () =>
        {
            phases.Add(Phase(store.IndexingStatus(notebook, 2)));
            Seed(store, notebook, [(4, "published during the build")]);
            // What the publication transaction does (PublishLooseExtraction → QueueEmbedding).
            jobs.Add(store.RequestEmbeddingBuild(notebook, Raw, copyExisting: true, 2));
            phases.Add(Phase(store.IndexingStatus(notebook, 2)));
            pending = UnfinishedEmbedJobs(store);
        };
        long jobId = store.RequestEmbeddingBuild(notebook, Raw, copyExisting: true, 1);
        Assert.Equal((IndexingPhase.Embedding, (int?)null, (int?)null, true), Phase(store.IndexingStatus(notebook, 1)));
        await RunAsync(store, Coordinator(store), jobId, "build");

        Assert.Equal([(IndexingPhase.Embedding, 1, 3, false), (IndexingPhase.Embedding, 1, 4, false)], phases);
        Assert.Equal([jobId], jobs);
        Assert.Single(pending);
        Assert.Empty(UnfinishedEmbedJobs(store));
        Assert.Equal(1, GenerationCount(store, notebook));
        var active = store.ActiveGeneration(notebook)!;
        Assert.Equal([1L, 2, 3, 4], store.Manifest(active.Id).Where(e => e.State == "done").Select(e => e.SourceId).Order());
        Assert.Equal(4, _handler.Calls);
        Assert.Equal(IndexingPhase.Ready, store.IndexingStatus(notebook, 3).Phase);
    }

    private sealed class SilentWatches : IFolderWatchFactory
    {
        public IFolderWatchHandle Create(FolderSource folder, Action<string> onEvent) => new Handle();
        private sealed class Handle : IFolderWatchHandle
        {
            public void Start() { }
            public void Dispose() { }
        }
    }

    /// <summary>Ollama <c>/api/embed</c>: a 3-dimensional vector per input; runs <see cref="Hook"/> before call <see cref="HookAt"/>.</summary>
    private sealed class HookedOllama : HttpMessageHandler
    {
        private int _calls;
        public int Calls => Volatile.Read(ref _calls);
        public int HookAt { get; set; }
        public Action? Hook { get; set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(ct));
            int call = Interlocked.Increment(ref _calls);
            if (call == HookAt) Hook?.Invoke();
            var vectors = body.RootElement.GetProperty("input").EnumerateArray()
                .Select(t => new double[] { t.GetString()!.Length + 1, 1, 2 }).ToArray();
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(JsonSerializer.Serialize(new { embeddings = vectors }), Encoding.UTF8, "application/json")
            };
        }
    }
}

using System.Net;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>Store inputs, live updates and runtime behaviour behind <c>indexing-status-v1</c>.</summary>
public sealed class IndexingStatusStoreTests
{
    private static readonly EmbeddingSelection Selection = new("local", "1", "m", null, null, "l2", "1", "1", "2");

    // ---------------------------------------------------------------- live updates

    [Fact]
    public void ClaimFailRequeueRecoverAndCompletePostChanges()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebook = store.CreateNotebook("n").Id!.Value;
        long other = store.CreateNotebook("o").Id!.Value;
        var log = new List<long>();
        store.IndexingStatusChanged += id => { lock (log) log.Add(id); };
        long[] Take() { lock (log) { var copy = log.ToArray(); log.Clear(); return copy; } }
        string options = """{"copyExisting":true,"selection":{"providerId":"local","endpointRevision":"1","model":"m","modelDigest":null,"dims":null,"normalization":"l2","queryFormatVersion":"1","docFormatVersion":"1","chunkerVersion":"2"}}""";
        long job = store.EnqueueJob(new IngestJobDraft("embed", $"notebook:{notebook}", null, options), 0);
        Take();
        Assert.NotNull(store.ClaimJob(0, "a", job));
        Assert.Equal([notebook], Take());
        Assert.True(store.FailJob(new JobFence(job, "a"), "providerUnreachable", 1));
        Assert.Equal([notebook], Take());
        Assert.Equal(0, store.RequeueRetryableJobs(0));
        Assert.Empty(Take());
        Assert.Equal(1, store.RequeueRetryableJobs(10_000));
        Assert.Equal([notebook], Take());
        Assert.NotNull(store.ClaimJob(10_000, "b", job));
        Take();
        Assert.Equal(1, store.RecoverExpiredJobs(20_000));
        Assert.Equal([notebook], Take());
        Assert.NotNull(store.ClaimJob(99_999, "c", job));
        Take();
        Assert.True(store.CompleteJob(new JobFence(job, "c"), 99_999));
        Assert.Equal([notebook], Take());
        // Owned-extraction cancellation and user cancellation.
        long source = store.CreateSource(other, SourceType.Text, "t", null, null).Id!.Value;
        long extract = store.EnqueueJob(new IngestJobDraft("extract", $"source:{source}", null), 0);
        Assert.NotNull(store.ClaimJob(100_000, "d", extract));
        Take();
        Assert.True(store.CancelJob(new JobFence(extract, "d"), 100_000));
        Assert.Equal([other], Take());
        long queued = store.EnqueueJob(new IngestJobDraft("extract", $"source:{source}", null), 0);
        Take();
        Assert.True(store.CancelIngestJob(queued, null, 100_000));
        Assert.Equal([other], Take());
        Assert.False(store.FailJob(new JobFence(queued, "zzz"), "x", 100_000));
        Assert.Empty(Take());
    }

    // ---------------------------------------------------------------- store inputs

    [Fact]
    public void StoreStatusFollowsEmbedJob()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebook = store.CreateNotebook("s").Id!.Value;
        Assert.Equal(IndexingPhase.Empty, store.IndexingStatus(notebook, 0).Phase);
        long source = store.CreateSource(notebook, SourceType.Text, "t", null, null).Id!.Value;
        store.CommitForegroundRevision(source, new RevisionDraft("h", "hello indexing world", 1, 2),
            ScalarChunker.Chunk("hello indexing world"), 0, "seed");
        Assert.True(store.NotebookNeedsEmbedding(notebook));
        Assert.Equal(IndexingPhase.LexicalOnly, store.IndexingStatus(notebook, 0).Phase);
        var blocked = store.IndexingStatus(notebook, 0, EmbeddingAvailability.NoModel);
        Assert.Equal((IndexingPhase.Blocked, IndexingBlockedReason.NoEmbeddingModel), (blocked.Phase, blocked.BlockedReason!.Value));
        var runtime = store.IndexingStatus(notebook, 0, runtimeError: "unexpectedError");
        Assert.Equal((IndexingBlockedReason.RuntimeFailed, "unexpectedError"), (runtime.BlockedReason!.Value, runtime.ErrorCode));
        long job = store.RequestEmbeddingBuild(notebook, Selection, copyExisting: true, 0);
        Assert.True(store.HasUnfinishedEmbedJob(notebook));
        var preparing = store.IndexingStatus(notebook, 0);
        Assert.Equal((IndexingPhase.Embedding, true), (preparing.Phase, preparing.Preparing));
        Assert.NotNull(store.ClaimJob(0, "t", job));
        Assert.True(store.FailEmbeddingJob(new JobFence(job, "t"), "providerUnreachable", 10));
        var retrying = store.IndexingStatus(notebook, 10);
        Assert.Equal(IndexingPhase.Retrying, retrying.Phase);
        Assert.Equal(new IndexingRetry("providerUnreachable", 70, 1, 60), retrying.Retry);
        Assert.True(store.ExpediteEmbedRetry(notebook, 10));
        Assert.Equal("queued", store.Job(job)!.State);
        Assert.Equal(IndexingPhase.Embedding, store.IndexingStatus(notebook, 10).Phase);
        Assert.False(store.ExpediteEmbedRetry(notebook, 10));
        var inputs = store.IndexingInputs(notebook, 10);
        Assert.Equal((1, 1, 1), (inputs.SourcesTotal, inputs.SourcesReady, inputs.EmbedJob!.Attempts));
        Assert.Throws<StorageV19Exception>(() => store.IndexingInputs(9_999, 0));
    }

    // ---------------------------------------------------------------- runtime behaviour

    /// <summary>
    /// ingestion-memory-pressure-v1 (field report v0.15.0): a due extraction stalls while the probe reports critical, the
    /// status says so, and the job runs once pressure drops — with no OS event, only the next scheduler tick.
    /// </summary>
    [Fact]
    public async Task DueExtractionResumesAndStatusShowsPause()
    {
        var level = MemoryPressureLevel.Critical;
        using var rig = new Rig(EmbeddingAvailability.NoProvider, () => level);
        long source = rig.Store.CreateSource(rig.Notebook, SourceType.Text, "t", null, null).Id!.Value;
        long job = rig.Store.EnqueueJob(new IngestJobDraft("extract", $"source:{source}", null), 0);
        await rig.Runtime.TickAsync(0);
        var paused = await rig.Runtime.IndexingStatusAsync(rig.Notebook);
        Assert.Equal((IndexingPhase.Extracting, MemoryPressureLevel.Critical), (paused.Phase, paused.MemoryPressure!.Value));
        var drain = rig.Runtime.DrainOnceAsync();
        await Task.Delay(200);
        Assert.False(drain.IsCompleted);
        Assert.Equal("queued", rig.Store.Job(job)!.State);
        level = MemoryPressureLevel.Normal;
        await rig.Runtime.TickAsync(100);
        Assert.True(await drain.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(1, rig.Store.Job(job)!.Attempts);
        Assert.Null((await rig.Runtime.IndexingStatusAsync(rig.Notebook)).MemoryPressure);
    }

    [Fact]
    public async Task ScanNowOnUnchangedFolderBuildsMissingIndex()
    {
        using var rig = new Rig(EmbeddingAvailability.NoProvider);
        var folder = await rig.Runtime.AddFolderAsync(rig.Notebook, rig.Root);
        await rig.DrainAllAsync();
        Assert.False(rig.Store.HasUnfinishedEmbedJob(rig.Notebook));
        var status = await rig.Runtime.IndexingStatusAsync(rig.Notebook);
        Assert.Equal((IndexingPhase.Blocked, IndexingBlockedReason.NoEmbeddingModel), (status.Phase, status.BlockedReason!.Value));
        Assert.Equal(EmbeddingAvailability.NoProvider, await rig.Runtime.EmbeddingAvailabilityAsync(rig.Notebook));
        Assert.Equal((1, 1), (rig.Runtime.LastScanOutcome(folder.Id)!.ChangedFiles, rig.Runtime.LastScanOutcome(folder.Id)!.FilesSeen));

        rig.Available = EmbeddingAvailability.Ready;
        Assert.Equal(IndexingPhase.LexicalOnly, (await rig.Runtime.IndexingStatusAsync(rig.Notebook)).Phase);
        // Scan now on the unchanged folder: fast path, no publication, yet the index gets built.
        await rig.Runtime.ScanNowAsync(folder.Id, false);
        Assert.True(await rig.Runtime.DrainOnceAsync());
        Assert.Equal((0, 1), (rig.Runtime.LastScanOutcome(folder.Id)!.ChangedFiles, rig.Runtime.LastScanOutcome(folder.Id)!.FilesSeen));
        Assert.True(rig.Store.HasUnfinishedEmbedJob(rig.Notebook));
        status = await rig.Runtime.IndexingStatusAsync(rig.Notebook);
        Assert.Equal((IndexingPhase.Embedding, true), (status.Phase, status.Preparing));
        await rig.DrainAllAsync();
        Assert.NotNull(rig.Store.ActiveGeneration(rig.Notebook));
        status = await rig.Runtime.IndexingStatusAsync(rig.Notebook);
        Assert.Equal(IndexingPhase.Ready, status.Phase);
        Assert.False(status.IsActive);
        await rig.Runtime.ScanNowAsync(folder.Id, false);
        await rig.DrainAllAsync();
        Assert.False(rig.Store.HasUnfinishedEmbedJob(rig.Notebook));
    }

    [Fact]
    public async Task RetryNowExpeditesWaitingJobAndRebuildsAfterTerminalFailure()
    {
        using var rig = new Rig(EmbeddingAvailability.Ready);
        rig.Handler.Fail = true;
        await rig.Runtime.AddFolderAsync(rig.Notebook, rig.Root);
        await rig.DrainAllAsync();
        var status = await rig.Runtime.IndexingStatusAsync(rig.Notebook);
        Assert.Equal(IndexingPhase.Retrying, status.Phase);
        Assert.Equal("providerHttp500", status.Retry!.Code);
        Assert.Equal(1, status.Retry.Attempt);
        Assert.True(status.Retry.RetryInSeconds > 0);
        rig.Handler.Fail = false;
        await rig.Runtime.RetryIndexingNowAsync(rig.Notebook);
        status = await rig.Runtime.IndexingStatusAsync(rig.Notebook);
        Assert.Equal((IndexingPhase.Embedding, true), (status.Phase, status.Preparing));
        await rig.DrainAllAsync();
        Assert.Equal(IndexingPhase.Ready, (await rig.Runtime.IndexingStatusAsync(rig.Notebook)).Phase);

        // Terminal failure: retry queues a fresh build.
        long failed = rig.Store.RequestEmbeddingBuild(rig.Notebook, Selection, copyExisting: true, 0);
        rig.Store.Connection.Execute("UPDATE ingest_jobs SET state='failed',attempts=5,error='providerHttp500' WHERE id=$failed", new { failed });
        rig.Store.Connection.Execute("UPDATE index_generations SET state='retired' WHERE notebook_id=$nb", new { nb = rig.Notebook });
        status = await rig.Runtime.IndexingStatusAsync(rig.Notebook);
        Assert.Equal((IndexingPhase.Blocked, IndexingBlockedReason.IndexFailed, "providerHttp500"),
            (status.Phase, status.BlockedReason!.Value, status.ErrorCode));
        await rig.Runtime.RetryIndexingNowAsync(rig.Notebook);
        Assert.True(rig.Store.HasUnfinishedEmbedJob(rig.Notebook));
        await rig.DrainAllAsync();
        Assert.Equal(IndexingPhase.Ready, (await rig.Runtime.IndexingStatusAsync(rig.Notebook)).Phase);
    }

    /// <summary>A source whose current revision never published defers activation; the attempt ends, never spins.</summary>
    [Fact]
    public async Task UnpublishableSourceDefersActivationWithoutSpinning()
    {
        using var rig = new Rig(EmbeddingAvailability.Ready);
        long published = rig.Store.CreateSource(rig.Notebook, SourceType.Text, "t", null, null).Id!.Value;
        rig.Store.CommitForegroundRevision(published, new RevisionDraft("h", "published text", 1, 2),
            ScalarChunker.Chunk("published text"), 0, "seed");
        long stuck = rig.Store.CreateSource(rig.Notebook, SourceType.Text, "stuck", null, null).Id!.Value;
        rig.Store.Connection.Execute("""
            INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
            VALUES($stuck,1,'h','',1,2,$created);
            UPDATE sources SET current_revision=last_insert_rowid() WHERE id=$stuck;
            """, new { stuck, created = SqliteDate.ToDb(DateTime.UnixEpoch) });
        await rig.Runtime.RetryIndexingNowAsync(rig.Notebook);
        var drain = rig.DrainAllAsync();
        Assert.Same(drain, await Task.WhenAny(drain, Task.Delay(TimeSpan.FromSeconds(20))));
        Assert.Null(rig.Store.ActiveGeneration(rig.Notebook));
    }

    [Fact]
    public async Task ExtractionPublishesWhenCredentialCannotBeLoaded()
    {
        using var rig = new Rig(EmbeddingAvailability.CredentialUnavailable);
        await rig.Runtime.AddFolderAsync(rig.Notebook, rig.Root);
        await rig.DrainAllAsync();
        Assert.Equal([SourceStatus.Ready], rig.Store.Sources(rig.Notebook).Select(s => s.Status).ToArray());
        Assert.False(rig.Store.HasUnfinishedEmbedJob(rig.Notebook));
        var status = await rig.Runtime.IndexingStatusAsync(rig.Notebook);
        Assert.Equal((IndexingPhase.Blocked, IndexingBlockedReason.CredentialUnavailable), (status.Phase, status.BlockedReason!.Value));
        Assert.Equal(0, status.SourceErrors);
    }

    [Fact]
    public async Task ExtractionWorkerToleratesThrowingSelection()
    {
        Assert.Null(await FolderExtractionWorker.PublishableSelectionAsync(1,
            _ => throw new InvalidOperationException("credential store down"), CancellationToken.None));
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => FolderExtractionWorker.PublishableSelectionAsync(1,
            _ => throw new OperationCanceledException(cancelled.Token), cancelled.Token));
    }

    [Fact]
    public async Task StartFailureIsExposedAndRetried()
    {
        using var rig = new Rig(EmbeddingAvailability.Ready);
        rig.Store.Connection.Execute("""
            INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,watch_enabled,created_at)
            VALUES(7,$nb,'/broken','{','B','["md"]','[]','{}',1,$created)
            """, new { nb = rig.Notebook, created = SqliteDate.ToDb(DateTime.UnixEpoch) });
        await Assert.ThrowsAnyAsync<Exception>(() => rig.Runtime.StartAsync());
        Assert.Equal("unexpectedError", rig.Runtime.StartError);
        var status = await rig.Runtime.IndexingStatusAsync(rig.Notebook);
        Assert.Equal((IndexingPhase.Blocked, IndexingBlockedReason.RuntimeFailed, "unexpectedError"),
            (status.Phase, status.BlockedReason!.Value, status.ErrorCode));
        string identity = JsonSerializer.Serialize(new FolderIdentity("v", ["broken"], "b"),
            new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
        rig.Store.Connection.Execute("UPDATE folder_sources SET path_identity=$identity WHERE id=7", new { identity });
        await rig.Runtime.RetryIndexingNowAsync(rig.Notebook);
        Assert.Null(rig.Runtime.StartError);
        status = await rig.Runtime.IndexingStatusAsync(rig.Notebook);
        Assert.Equal((IndexingPhase.Scanning, (int?)null), (status.Phase, status.FilesSeen));
        await rig.Runtime.StopAsync();
    }

    // ---------------------------------------------------------------- rig

    /// <summary>In-memory store, one temp folder with one Markdown file, deterministic draining.</summary>
    private sealed class Rig : IDisposable
    {
        private readonly HttpClient _http;

        public Rig(EmbeddingAvailability available, Func<MemoryPressureLevel>? memoryPressure = null)
        {
            Available = available;
            Notebook = Store.CreateNotebook("idx").Id!.Value;
            Root = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "idx-" + Guid.NewGuid().ToString("N"))).FullName;
            File.WriteAllText(Path.Combine(Root, "a.md"), "Indexing progress keeps the user informed.\n");
            _http = new HttpClient(Handler);
            var session = new FolderEmbeddingSession(new ProviderConfig("local", ProviderType.Ollama, "Local", "http://localhost:11434",
                true, false, DateTime.UnixEpoch), "embed-a", null, null, "1", "1", _http);
            var fs = new NativeFolderFileSystem();
            var admission = new IngestionAdmission();
            var extractor = new BoundedDocumentExtractor();
            Func<long, Task<EmbeddingSelection?>> selected = _ => Available switch
            {
                EmbeddingAvailability.Ready => Task.FromResult<EmbeddingSelection?>(session.Selection),
                EmbeddingAvailability.CredentialUnavailable => throw new FolderIngestionException("credentialUnavailable"),
                _ => Task.FromResult<EmbeddingSelection?>(null)
            };
            Runtime = new FolderIngestionRuntime(Store, new FolderScanner(Store, fs, UnicodeTables.LoadBundled(), Clock),
                new FolderExtractionWorker(Store, fs, LanguageDetector.Unavailable, Clock, selected,
                    (uri, type, rules, ct) => extractor.ExtractAsync(uri, type, rules, ct)),
                new FolderIndexCoordinator(Store, admission, Clock, async (id, _) =>
                    await selected(id).ConfigureAwait(false) is null ? null : session, selected),
                new JobQueue(Store, Clock, admission), Clock, admission, new SilentWatches(), memoryPressure: memoryPressure, identity: fs,
                selectedSelection: selected, embeddingAvailability: _ => Task.FromResult(Available))
            { AutoDispatch = false };
        }

        public NotebookStore Store { get; } = new(StorePath.InMemory, configuredEmbeddingModelKey: null);
        public StepClock Clock { get; } = new();
        public OllamaHandler Handler { get; } = new();
        public FolderIngestionRuntime Runtime { get; }
        public long Notebook { get; }
        public string Root { get; }
        public EmbeddingAvailability Available { get; set; }

        public async Task DrainAllAsync()
        {
            for (int i = 0; i < 200 && await Runtime.DrainOnceAsync(); i++) { }
        }

        public void Dispose()
        {
            _http.Dispose();
            Store.Dispose();
            try { Directory.Delete(Root, true); } catch (IOException) { }
        }
    }

    private sealed class StepClock : IIngestLeaseClock
    {
        public long Now => 1_000;
        public Task WaitUntilAsync(long deadline, CancellationToken ct) => Task.Delay(Timeout.Infinite, ct);
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

    /// <summary>Ollama <c>/api/embed</c>: [1, 0] per input, or HTTP 500 while failing.</summary>
    private sealed class OllamaHandler : HttpMessageHandler
    {
        public volatile bool Fail;

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(ct));
            int count = body.RootElement.GetProperty("input").GetArrayLength();
            if (Fail) return new HttpResponseMessage(HttpStatusCode.InternalServerError) { Content = new StringContent("{}") };
            string json = JsonSerializer.Serialize(new { embeddings = Enumerable.Range(0, count).Select(_ => new[] { 1.0, 0.0 }).ToArray() });
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
        }
    }
}

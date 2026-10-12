using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>
/// FR-E1 watched folder, now a facade over the durable runtime: a persisted folder, a recursive native watch and
/// fenced scans/extractions. The event-driven paths write real files and observe the real native watcher, but never
/// race wall-clock sleeps against the pipeline:
/// <list type="bullet">
/// <item>A native watch can be armed asynchronously (macOS FSEvents drops changes made in roughly the first second
/// after <c>EnableRaisingEvents</c>), so each test first proves the watch is live with a probe file whose event must
/// arrive (<see cref="WatchIsLiveAsync"/>).</item>
/// <item>After a file operation, <see cref="AfterRescansAsync"/> waits for a native event, then for the runtime's own
/// idle signal (debounce, scan and extraction finished) before checking — repeating only when another event arrives.
/// The only bounded wait left is the OS delivering the event.</item>
/// </list>
/// </summary>
public class FolderWatchServiceTests : IAsyncLifetime
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "watch-" + Guid.NewGuid());
    private readonly List<(NotebookStore Store, FolderIngestionRuntime Runtime)> _created = [];
    private readonly ObservedWatchFactory _watches = new();
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(60);

    /// <summary>
    /// Real <see cref="NativeFolderWatchHandle"/>s whose deliveries are counted after the runtime recorded the
    /// signal, so an observed event implies the debounced rescan is already scheduled.
    /// </summary>
    private sealed class ObservedWatchFactory : IFolderWatchFactory
    {
        private readonly object _gate = new();
        private int _events;
        private TaskCompletionSource _next = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public int Events { get { lock (_gate) return _events; } }

        public IFolderWatchHandle Create(FolderSource folder, Action<string> onEvent) =>
            new NativeFolderWatchHandle(folder.Draft.RootPath, kind =>
            {
                onEvent(kind);
                TaskCompletionSource next;
                lock (_gate)
                {
                    _events++;
                    next = _next;
                    _next = new(TaskCreationOptions.RunContinuationsAsynchronously);
                }
                next.TrySetResult();
            });

        /// <summary>Completes once more than <paramref name="seen"/> events were delivered.</summary>
        public async Task AfterAsync(int seen, CancellationToken ct)
        {
            while (true)
            {
                Task next;
                lock (_gate)
                {
                    if (_events > seen) return;
                    next = _next.Task;
                }
                await next.WaitAsync(ct);
            }
        }
    }

    public Task InitializeAsync()
    {
        Directory.CreateDirectory(_dir);
        return Task.CompletedTask;
    }

    public async Task DisposeAsync()
    {
        foreach (var (store, runtime) in _created)
        {
            await runtime.StopAsync();
            store.Dispose();
        }
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }

    private async Task<(NotebookStore store, FolderIngestionRuntime runtime, long notebookId)> NewStore()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var clock = new SystemIngestLeaseClock();
        var admission = new IngestionAdmission();
        var fs = new NativeFolderFileSystem();
        var extractor = new BoundedDocumentExtractor();
        Func<long, Task<EmbeddingSelection?>> none = _ => Task.FromResult<EmbeddingSelection?>(null);
        var runtime = new FolderIngestionRuntime(store, new FolderScanner(store, fs, UnicodeTables.LoadBundled(), clock),
            new FolderExtractionWorker(store, fs, LanguageDetector.Unavailable, clock, none, (uri, type, rules, ct) => extractor.ExtractAsync(uri, type, rules, ct)),
            new FolderIndexCoordinator(store, admission, clock, (_, _) => Task.FromResult<AINotebook.Core.Providers.FolderEmbeddingSession?>(null), none),
            new JobQueue(store, clock, admission), clock, admission, _watches, identity: fs);
        await runtime.StartAsync();
        _created.Add((store, runtime));
        return (store, runtime, store.CreateNotebook("NB").Id!.Value);
    }

    /// <summary>
    /// Waits for the enable command, the folder's initial scan and extractions, then proves the native watch delivers
    /// events (a probe file the scanner skips) and lets the probe's rescan finish. Returns the folder ID.
    /// </summary>
    private async Task<long> WatchIsLiveAsync(FolderIngestionRuntime runtime, FolderWatchService watcher, NotebookStore store, long nb)
    {
        using var cts = new CancellationTokenSource(Deadline);
        await watcher.WhenIdleAsync().WaitAsync(cts.Token);
        long folderId = Assert.Single(store.Folders(nb)).Id;
        await runtime.WaitForFolderIdleAsync(folderId, cts.Token);
        for (int probe = 0; ; probe++)
        {
            int seen = _watches.Events;
            await File.WriteAllTextAsync(Path.Combine(_dir, $"watch-probe-{probe}.probe"), "probe", cts.Token);
            using var attempt = CancellationTokenSource.CreateLinkedTokenSource(cts.Token);
            attempt.CancelAfter(TimeSpan.FromSeconds(2));
            try
            {
                await _watches.AfterAsync(seen, attempt.Token);
                break;
            }
            catch (OperationCanceledException) when (!cts.IsCancellationRequested) { }
        }
        await runtime.WaitForFolderIdleAsync(folderId, cts.Token);
        return folderId;
    }

    /// <summary>
    /// Checks <paramref name="done"/> only when the folder is idle; while it does not hold, waits for the next native
    /// event (whose rescan is then already scheduled) and for that rescan to finish. False after the deadline.
    /// </summary>
    private async Task<bool> AfterRescansAsync(FolderIngestionRuntime runtime, long folderId, Func<bool> done)
    {
        using var cts = new CancellationTokenSource(Deadline);
        try
        {
            while (true)
            {
                int seen = _watches.Events;
                await runtime.WaitForFolderIdleAsync(folderId, cts.Token);
                if (done()) return true;
                await _watches.AfterAsync(seen, cts.Token);
            }
        }
        catch (OperationCanceledException) when (cts.IsCancellationRequested) { return done(); }
    }

    [Fact]
    public async Task EnableAndDisableReportTheWatchedFolderAndClearItAgain()
    {
        var (_, runtime, nb) = await NewStore();
        using var watcher = new FolderWatchService(runtime);

        Assert.False(watcher.IsActive);
        Assert.Null(watcher.WatchedFolder);

        watcher.Enable(nb, _dir);
        Assert.True(watcher.IsActive);
        Assert.Equal(_dir, watcher.WatchedFolder);
        await watcher.WhenIdleAsync();
        Assert.Single(runtime.WatchedFolderIds);

        watcher.Disable();
        Assert.False(watcher.IsActive);
        Assert.Null(watcher.WatchedFolder);
        await watcher.WhenIdleAsync();
        Assert.Empty(runtime.WatchedFolderIds);
    }

    [Fact]
    public async Task EnablingTwiceSwitchesFoldersInsteadOfLeakingTheFirstWatcher()
    {
        var (_, runtime, nb) = await NewStore();
        var second = Path.Combine(_dir, "nested");
        Directory.CreateDirectory(second);
        using var watcher = new FolderWatchService(runtime);

        watcher.Enable(nb, _dir);
        watcher.Enable(nb, second);

        Assert.Equal(second, watcher.WatchedFolder);
        Assert.True(watcher.IsActive);
        await watcher.WhenIdleAsync();
        // The first root's watch was released; the nested root overlaps that persisted folder and is rejected
        // before any second watch starts.
        Assert.Empty(runtime.WatchedFolderIds);
        Assert.IsType<StorageV19Exception>(watcher.LastError);
    }

    [Fact]
    public async Task DisableIsIdempotentAndSafeBeforeAnyEnable()
    {
        var (_, runtime, _) = await NewStore();
        var watcher = new FolderWatchService(runtime);

        watcher.Disable();
        watcher.Disable();
        watcher.Dispose();
        watcher.Dispose();

        Assert.False(watcher.IsActive);
    }

    [Fact]
    public async Task ANewSupportedFileIsIngestedAndStampedWithItsContentHash()
    {
        var (store, runtime, nb) = await NewStore();
        using var watcher = new FolderWatchService(runtime);
        watcher.Enable(nb, _dir);
        long folderId = await WatchIsLiveAsync(runtime, watcher, store, nb);
        Assert.Empty(store.Sources(nb));

        await File.WriteAllTextAsync(Path.Combine(_dir, "memo.txt"), "Watched content.");

        Assert.True(await AfterRescansAsync(runtime, folderId, () =>
                store.Sources(nb) is [{ ContentHash: not null }]),
            "the watcher never ingested the new file");
        var source = store.Sources(nb).Single();
        Assert.Equal("memo", source.Title);
        Assert.Equal(SourceType.Text, source.Type);
        Assert.NotNull(store.Source(source.Id!.Value)!.ContentHash);
        Assert.NotNull(store.Source(source.Id!.Value)!.LastSyncedAt);
    }

    [Fact]
    public async Task AFileTypeTheAppCannotReadIsIgnored()
    {
        var (store, runtime, nb) = await NewStore();
        using var watcher = new FolderWatchService(runtime);
        watcher.Enable(nb, _dir);
        long folderId = await WatchIsLiveAsync(runtime, watcher, store, nb);

        await File.WriteAllTextAsync(Path.Combine(_dir, "photo.jpeg"), "not text");
        await File.WriteAllTextAsync(Path.Combine(_dir, "memo.txt"), "text");

        // The .txt is the tripwire: once it has landed, the .jpeg has had at
        // least as long to be (wrongly) picked up.
        Assert.True(await AfterRescansAsync(runtime, folderId, () => store.Sources(nb).Any(s => s.Title == "memo")));
        Assert.DoesNotContain(store.Sources(nb), s => s.Title == "photo");
    }

    [Fact]
    public async Task NothingIsIngestedAfterTheWatcherIsDisabled()
    {
        var (store, runtime, nb) = await NewStore();
        using var watcher = new FolderWatchService(runtime);

        watcher.Enable(nb, _dir);
        watcher.Disable();
        await watcher.WhenIdleAsync();
        // The persisted folder's initial scan may still finish; only watch-driven ingestion must stop.
        var folder = Assert.Single(store.Folders(nb));
        await runtime.WaitForFolderIdleAsync(folder.Id).WaitAsync(TimeSpan.FromSeconds(15));
        await File.WriteAllTextAsync(Path.Combine(_dir, "after.txt"), "content");
        await Task.Delay(2000);

        Assert.Empty(store.Sources(nb));
    }

    [Fact]
    public async Task ReindexingAnUnchangedFileIsSkippedButAnEditIsPickedUp()
    {
        var (store, runtime, nb) = await NewStore();
        var path = Path.Combine(_dir, "memo.txt");
        await File.WriteAllTextAsync(path, "Original body.");

        using var watcher = new FolderWatchService(runtime);
        watcher.Enable(nb, _dir);

        // Touch without changing content: the hash matches, so nothing to do.
        File.SetLastWriteTimeUtc(path, DateTime.UtcNow);
        long folderId = await WatchIsLiveAsync(runtime, watcher, store, nb);
        var source = Assert.Single(store.Sources(nb));
        var firstHash = store.Source(source.Id!.Value)!.ContentHash;
        Assert.NotNull(firstHash);

        // Now genuinely change it — the hash differs, so it is re-ingested.
        await File.WriteAllTextAsync(path, "Completely different body text now.");

        Assert.True(await AfterRescansAsync(runtime, folderId, () => store.Source(source.Id!.Value)!.ContentHash != firstHash),
            "the edit was never re-ingested");
        // Still one source: an edit updates in place rather than duplicating.
        Assert.Single(store.Sources(nb));
    }

    [Fact]
    public async Task ADeletedFileBecomesMissingButKeepsItsSource()
    {
        var (store, runtime, nb) = await NewStore();
        var path = Path.Combine(_dir, "gone.txt");
        await File.WriteAllTextAsync(path, "Short lived.");
        using var watcher = new FolderWatchService(runtime);
        watcher.Enable(nb, _dir);
        long folderId = await WatchIsLiveAsync(runtime, watcher, store, nb);
        var source = Assert.Single(store.Sources(nb));
        Assert.NotNull(source.PublishedRevisionId);

        File.Delete(path);

        Assert.True(await AfterRescansAsync(runtime, folderId, () => store.Source(source.Id!.Value)!.Availability == "missing"),
            "the deletion was never reconciled");
        Assert.Single(store.Sources(nb));
    }

    [Fact]
    public async Task ARenamedDirectoryIsRescannedRecursively()
    {
        var (store, runtime, nb) = await NewStore();
        Directory.CreateDirectory(Path.Combine(_dir, "old"));
        await File.WriteAllTextAsync(Path.Combine(_dir, "old", "deep.md"), "# Deep\nnested body");
        using var watcher = new FolderWatchService(runtime);
        watcher.Enable(nb, _dir);
        long folderId = await WatchIsLiveAsync(runtime, watcher, store, nb);
        Assert.Contains(store.Sources(nb), s => s.RelPath == "old/deep.md" && s.PublishedRevisionId is not null);

        Directory.Move(Path.Combine(_dir, "old"), Path.Combine(_dir, "new"));

        Assert.True(await AfterRescansAsync(runtime, folderId, () =>
            store.Sources(nb).Any(s => s.RelPath == "new/deep.md" && s.Availability == "present") &&
            store.Sources(nb).Any(s => s.RelPath == "old/deep.md" && s.Availability == "missing")),
            "the renamed directory was never rescanned");
    }

    [Fact]
    public void OverflowAndErrorsForceAFullScanAndDisposalInvalidatesCallbacks()
    {
        var kinds = new List<string>();
        var handle = new NativeFolderWatchHandle(_dir, kinds.Add);
        Assert.False(handle.IsActive);
        handle.Start();
        Assert.True(handle.IsActive);
        Assert.Equal(_dir, handle.WatchedFolder);
        handle.RaiseForTests("overflow");
        Assert.Equal(new[] { "overflow" }, kinds);
        Assert.True(FolderWatchEventPolicy.ForceHash(kinds[0]));
        handle.Dispose();
        handle.Dispose();
        Assert.False(handle.IsActive);
        handle.RaiseForTests("changed");
        Assert.Single(kinds);
    }
}

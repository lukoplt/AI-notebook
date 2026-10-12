using System.Collections.Concurrent;
using System.Globalization;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Ingestion;

/// <summary>A native (or test) watch registration. Start begins delivering raw event kinds.</summary>
public interface IFolderWatchHandle : IDisposable
{
    void Start();
}

public interface IFolderWatchFactory
{
    IFolderWatchHandle Create(FolderSource folder, Action<string> onEvent);
}

/// <summary>Maps a raw watcher event kind to whether the follow-up scan must re-hash (verify all).</summary>
public static class FolderWatchEventPolicy
{
    /// <summary>Only a pure creation can rely on the stat fast path; edits, renames, deletes and overflow re-hash.</summary>
    public static bool ForceHash(string kind) => !StringComparer.Ordinal.Equals(kind, "created");
}

/// <summary>Creates recursive <see cref="NativeFolderWatchHandle"/> instances for persisted folder roots.</summary>
public sealed class NativeFolderWatchFactory : IFolderWatchFactory
{
    public IFolderWatchHandle Create(FolderSource folder, Action<string> onEvent)
    {
        ArgumentNullException.ThrowIfNull(folder);
        return new NativeFolderWatchHandle(folder.Draft.RootPath, onEvent);
    }
}

/// <summary>
/// Process-wide durable folder ingestion: owns watches, per-folder rescan debouncing, the reconciler and the job
/// dispatch loops (one extraction loop per admission permit, one scan loop, one embed/gc loop). The admission's adaptive
/// limit (contract <c>ingestion-memory-pressure-v1</c> addendum A) decides how many extractions run. Views never run
/// ingestion themselves;
/// every callback carries a folder ID and no "current notebook" is consulted. Construction does no IO.
/// </summary>
public sealed class FolderIngestionRuntime : IAsyncDisposable
{
    private readonly NotebookStore _store;
    private readonly FolderScanner _scanner;
    private readonly FolderExtractionWorker _extraction;
    private readonly FolderIndexCoordinator _index;
    private readonly JobQueue _queue;
    private readonly IIngestLeaseClock _clock;
    private readonly IngestionAdmission _admission;
    private readonly IFolderWatchFactory _watches;
    private readonly Func<long> _milliseconds;
    private readonly Func<MemoryPressureLevel>? _memoryPressure;
    private readonly Func<SystemSample>? _systemLoad;
    private readonly ConcurrencyGovernor _governor;
    private long? _lastSystemSample;
    private readonly IFolderPathIdentity _identity;
    private readonly Func<long, Task<EmbeddingSelection?>>? _selectedSelection;
    private readonly Func<long, Task<EmbeddingAvailability>>? _embeddingAvailability;
    private readonly object _gate = new();
    private readonly ConcurrentDictionary<long, FolderScanOutcome> _scanOutcomes = new();
    private readonly Dictionary<long, Watch> _watchHandles = new();
    private readonly Dictionary<long, FolderSchedule> _schedules = new();
    private readonly ConcurrentDictionary<long, byte> _runningScans = new();
    private TaskCompletionSource _pulse = NewPulse();
    private CancellationTokenSource? _stopping;
    private FolderReconciler? _reconciler;
    private List<Task> _loops = [];
    private bool _started;
    private bool _starting;
    private string? _startError;

    public FolderIngestionRuntime(NotebookStore store, FolderScanner scanner, FolderExtractionWorker extraction,
        FolderIndexCoordinator index, JobQueue queue, IIngestLeaseClock clock, IngestionAdmission admission,
        IFolderWatchFactory watches, Func<long>? milliseconds = null, Func<MemoryPressureLevel>? memoryPressure = null,
        IFolderPathIdentity? identity = null, Func<long, Task<EmbeddingSelection?>>? selectedSelection = null,
        Func<long, Task<EmbeddingAvailability>>? embeddingAvailability = null, Func<SystemSample>? systemLoad = null)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _scanner = scanner ?? throw new ArgumentNullException(nameof(scanner));
        _extraction = extraction ?? throw new ArgumentNullException(nameof(extraction));
        _index = index ?? throw new ArgumentNullException(nameof(index));
        _queue = queue ?? throw new ArgumentNullException(nameof(queue));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _admission = admission ?? throw new ArgumentNullException(nameof(admission));
        _watches = watches ?? throw new ArgumentNullException(nameof(watches));
        _milliseconds = milliseconds ?? (() => Environment.TickCount64);
        _memoryPressure = memoryPressure;
        _systemLoad = systemLoad;
        _governor = new ConcurrencyGovernor(_admission.MaxExtractions);
        _identity = identity ?? new NativeFolderFileSystem();
        _selectedSelection = selectedSelection;
        _embeddingAvailability = embeddingAvailability;
        _store.FolderIngestionChanged += _ => Pulse();
    }

    internal NotebookStore Store => _store;

    /// <summary>The generation coordinator (re-index, progress, discard) owned by this runtime.</summary>
    public FolderIndexCoordinator Index => _index;

    /// <summary>Test seam: false keeps dispatch and timer loops off so DrainOnceAsync/TickAsync are deterministic.</summary>
    internal bool AutoDispatch { get; init; } = true;

    /// <summary>Most recent background failure (routed from fire-and-forget facades and loops).</summary>
    public Exception? LastError { get; private set; }

    /// <summary>Folder IDs whose native watch is currently started.</summary>
    public IReadOnlyList<long> WatchedFolderIds
    {
        get { lock (_gate) return _watchHandles.Keys.Order().ToArray(); }
    }

    /// <summary>
    /// Contract code of the last failed <see cref="StartAsync"/>; null once a start succeeded. Surfaces as indexing
    /// status <c>blocked(runtimeFailed)</c>; <see cref="RetryIndexingNowAsync"/> retries the start.
    /// </summary>
    public string? StartError
    {
        get { lock (_gate) return _startError; }
    }

    /// <summary>
    /// Idempotent: recovers durable state, schedules watched folders, starts watches and dispatch loops, then requests
    /// missing index builds. The runtime counts as started only after the reconciler started; a failure is kept as
    /// <see cref="StartError"/> and a later call may retry.
    /// </summary>
    public async Task StartAsync(CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (_started || _starting) return;
            _starting = true;
        }
        IReadOnlyList<FolderSource> watched;
        var reconciler = new FolderReconciler(_store, _clock, (folderId, verifyAll) =>
        {
            _store.RequestFolderScan(folderId, verifyAll, _clock.Now);
            Pulse();
            return Task.CompletedTask;
        }, IsWatchHealthy);
        try
        {
            await reconciler.StartAsync(ct).ConfigureAwait(false);
            watched = _store.WatchedFolders();
            lock (_gate)
            {
                _reconciler = reconciler;
                _started = true;
                _startError = null;
                _stopping = new CancellationTokenSource();
            }
        }
        catch (Exception error)
        {
            await reconciler.StopAsync().ConfigureAwait(false);
            lock (_gate) _startError = ErrorCode(error);
            LastError = error;
            NotifyAllNotebooks();
            throw;
        }
        finally
        {
            lock (_gate) _starting = false;
        }
        var token = _stopping!.Token;
        foreach (var folder in watched) StartWatch(folder);
        NotifyAllNotebooks();
        var loops = new List<Task>();
        if (!AutoDispatch)
        {
            await EnsureIndexBuildsAsync(ct).ConfigureAwait(false);
            Pulse();
            return; // Deterministic tests drive DrainOnceAsync/TickAsync explicitly.
        }
        for (int i = 0; i < _admission.MaxExtractions; i++)
            loops.Add(Task.Run(() => DispatchLoopAsync("extract", token), CancellationToken.None));
        loops.Add(Task.Run(() => DispatchLoopAsync("scan", token), CancellationToken.None));
        loops.Add(Task.Run(() => DispatchLoopAsync("embed", token), CancellationToken.None));
        loops.Add(Task.Run(() => DispatchLoopAsync("gc", token), CancellationToken.None));
        loops.Add(Task.Run(() => TimerLoopAsync(token), CancellationToken.None));
        lock (_gate) _loops = loops;
        await EnsureIndexBuildsAsync(ct).ConfigureAwait(false);
        Pulse();
    }

    /// <summary>Why background embedding can or cannot run for the notebook right now.</summary>
    public async Task<EmbeddingAvailability> EmbeddingAvailabilityAsync(long notebookId)
    {
        if (_embeddingAvailability is not null) return await _embeddingAvailability(notebookId).ConfigureAwait(false);
        if (_selectedSelection is null) return EmbeddingAvailability.NoProvider;
        try
        {
            return await _selectedSelection(notebookId).ConfigureAwait(false) is null
                ? EmbeddingAvailability.NoProvider : EmbeddingAvailability.Ready;
        }
        catch (Exception) { return EmbeddingAvailability.NoProvider; }
    }

    /// <summary>
    /// The notebook's indexing status: store inputs + embedding availability + runtime start error + admission memory
    /// pressure (contract <c>indexing-status-v1</c>).
    /// </summary>
    public async Task<IndexingStatus> IndexingStatusAsync(long notebookId, CancellationToken ct = default)
    {
        var availability = await EmbeddingAvailabilityAsync(notebookId).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        var inputs = _store.IndexingInputs(notebookId, _clock.Now, availability, StartError) with
        {
            MemoryPressure = _admission.PressureLevel
        };
        return IndexingStatusDerivation.Derive(inputs);
    }

    /// <summary>The folder's last finished scan in this process ("No changes · N files up to date"); null before one.</summary>
    public FolderScanOutcome? LastScanOutcome(long folderId) => _scanOutcomes.TryGetValue(folderId, out var outcome) ? outcome : null;

    /// <summary>
    /// "Retry now" / "Build index": retries a failed runtime start, makes the notebook's waiting embed job due now, or
    /// else requests a missing build.
    /// </summary>
    public async Task RetryIndexingNowAsync(long notebookId, CancellationToken ct = default)
    {
        if (StartError is not null) await StartAsync(ct).ConfigureAwait(false);
        if (!_store.ExpediteEmbedRetry(notebookId, _clock.Now)) await EnsureIndexBuildAsync(notebookId, ct).ConfigureAwait(false);
        Pulse();
    }

    /// <summary>
    /// Explicit "Retry" of one failed folder source: its failure budget starts over and extraction is queued
    /// (<c>ingestion-retry-cap-v1</c> §5). True when the source was retried.
    /// </summary>
    public Task<bool> RetryFailedSourceAsync(long sourceId, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        bool retried = _store.RetryFailedExtraction(sourceId, _clock.Now);
        Pulse();
        return Task.FromResult(retried);
    }

    /// <summary>"Retry all failed" for the notebook. Returns the number of retried sources.</summary>
    public Task<int> RetryFailedSourcesAsync(long notebookId, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        int count = _store.RetryFailedExtractions(notebookId, _clock.Now);
        Pulse();
        return Task.FromResult(count);
    }

    /// <summary>
    /// Requests an incremental build when the notebook has unindexed published content, no unfinished embed job and an
    /// available selection. True when a build was requested.
    /// </summary>
    internal async Task<bool> EnsureIndexBuildAsync(long notebookId, CancellationToken ct = default)
    {
        if (_selectedSelection is null) return false;
        if (_store.HasUnfinishedEmbedJob(notebookId)) return false;
        bool needs = _store.NotebookNeedsEmbedding(notebookId);
        var selection = await _selectedSelection(notebookId).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        if (selection is null) return false;
        // embedding-raw-format-v2 §5: a complete index at raw format 1 is rebuilt once at format 2;
        // the active generation keeps serving queries until the build activates.
        if (!needs && !RawFormatUpgradeDue(_store.ActiveGeneration(notebookId), selection)) return false;
        _store.RequestEmbeddingBuild(notebookId, selection, copyExisting: true, _clock.Now);
        Pulse();
        return true;
    }

    internal static bool RawFormatUpgradeDue(IndexGeneration? active, EmbeddingSelection selected)
    {
        if (active is null || selected.QueryFormatVersion != AINotebook.Core.Providers.RawEmbeddingFormat.Current
            || selected.DocFormatVersion != AINotebook.Core.Providers.RawEmbeddingFormat.Current) return false;
        var identity = active.Identity;
        return identity.ProviderId == selected.ProviderId && identity.EndpointRevision == selected.EndpointRevision
            && identity.Model == selected.Model && identity.QueryFormatVersion == "1" && identity.DocFormatVersion == "1";
    }

    private async Task EnsureIndexBuildsAsync(CancellationToken ct)
    {
        foreach (long notebookId in _store.Notebooks().Select(n => n.Id!.Value))
        {
            // Best effort: a provider error here must not fail the start.
            try { await EnsureIndexBuildAsync(notebookId, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception error) { LastError = error; }
        }
    }

    private void NotifyAllNotebooks()
    {
        try { _store.NotifyIndexingStatusChanged(_store.Notebooks().Select(n => n.Id!.Value)); }
        catch (Exception error) { LastError = error; }
    }

    internal static string ErrorCode(Exception error) => error switch
    {
        FolderIngestionException ingestion => ingestion.Code,
        StorageV19Exception storage => storage.Code,
        _ => "unexpectedError"
    };

    /// <summary>Stops watches, timers, reconciliation and dispatch, and joins them. Claimed work is left to lease recovery.</summary>
    public async Task StopAsync()
    {
        CancellationTokenSource? stopping;
        List<Task> loops;
        Watch[] watches;
        lock (_gate)
        {
            if (!_started) return;
            _started = false;
            stopping = _stopping;
            _stopping = null;
            loops = _loops;
            _loops = [];
            watches = _watchHandles.Values.ToArray();
            _watchHandles.Clear();
        }
        foreach (var watch in watches) watch.Dispose();
        stopping?.Cancel();
        Pulse();
        if (_reconciler is not null) await _reconciler.StopAsync().ConfigureAwait(false);
        await _queue.StopAsync().ConfigureAwait(false);
        try { await Task.WhenAll(loops).ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        stopping?.Dispose();
    }

    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);

    /// <summary>Resolves the native identity off the UI thread, persists defaults and queues the first scan.</summary>
    public async Task<FolderSource> AddFolderAsync(long notebookId, string path, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        var folder = await Task.Run(() =>
        {
            ct.ThrowIfCancellationRequested();
            string trimmed = path.TrimEnd('/', '\\');
            string name = Path.GetFileName(trimmed);
            var draft = new FolderDraft(path, name.Length == 0 ? path : name, FolderRules.Defaults.IncludeExts,
                FolderRules.Defaults.IgnoreGlobs, "{}", FolderRules.Defaults.EncodingFallback, true);
            // Overlapping roots fail here, before any watch starts.
            return _store.CreateFolder(notebookId, draft, _identity, _clock.Now);
        }, ct).ConfigureAwait(false);
        _store.RequestFolderScan(folder.Id, false, _clock.Now);
        bool started;
        lock (_gate) started = _started;
        if (started) StartWatch(folder);
        Pulse();
        return folder;
    }

    public Task<long> ScanNowAsync(long folderId, bool verifyAll, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        long job = _store.RequestFolderScan(folderId, verifyAll, _clock.Now);
        Pulse();
        return Task.FromResult(job);
    }

    /// <summary>Persists the flag and starts/disposes only that folder's native watch; manual scans keep working.</summary>
    public Task SetWatchingAsync(long folderId, bool enabled, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var folder = _store.Folder(folderId) ?? throw new StorageV19Exception("notFound");
        if (folder.Draft.WatchEnabled != enabled)
            _store.UpdateFolder(folderId, folder.Draft with { WatchEnabled = enabled }, _identity);
        if (!enabled) StopWatch(folderId);
        else
        {
            bool started;
            lock (_gate) started = _started;
            if (started) StartWatch(_store.Folder(folderId)!);
        }
        _store.NotifyFolderIngestionChanged(folder.NotebookId);
        return Task.CompletedTask;
    }

    /// <summary>
    /// Invalidates the watch callback first, cancels the folder's scan and extraction jobs, then deletes the database
    /// rows. Files on disk are never touched.
    /// </summary>
    public Task RemoveFolderAsync(long folderId, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var folder = _store.Folder(folderId) ?? throw new StorageV19Exception("notFound");
        StopWatch(folderId);
        lock (_gate) _schedules.Remove(folderId);
        _scanOutcomes.TryRemove(folderId, out _);
        _store.CancelFolderJobs(folderId);
        _store.DeleteFolder(folderId);
        _store.NotifyFolderIngestionChanged(folder.NotebookId);
        return Task.CompletedTask;
    }

    /// <summary>Records a raw watcher signal on the monotonic millisecond clock (500 ms debounce, 5 s maximum).</summary>
    public Task SignalAsync(long folderId, long milliseconds, bool forceHash)
    {
        lock (_gate)
        {
            if (!_schedules.TryGetValue(folderId, out var schedule))
            {
                if (_store.Folder(folderId) is null) return Task.CompletedTask;
                _schedules[folderId] = schedule = new FolderSchedule();
            }
            schedule.Schedule.Signal(milliseconds);
            schedule.ForceHash |= forceHash;
        }
        return Task.CompletedTask;
    }

    /// <summary>
    /// Whether the folder's native watch counts as healthy for the reconciler (contract ingestion-scan-perf-v1 §4):
    /// started and no lost-events report (overflow / watcher error) since.
    /// </summary>
    public bool IsWatchHealthy(long folderId)
    {
        lock (_gate) return _watchHandles.TryGetValue(folderId, out var watch) && watch.Healthy;
    }

    /// <summary>
    /// After system sleep the watches may have missed events: every watched folder gets one debounced stat-only rescan
    /// (contract ingestion-scan-perf-v1 §4).
    /// </summary>
    public async Task SystemDidWakeAsync()
    {
        long now = _milliseconds();
        foreach (long folderId in WatchedFolderIds) await SignalAsync(folderId, now, forceHash: false).ConfigureAwait(false);
    }

    /// <summary>Waits until the folder has no queued, running or retryable scan/extract work.</summary>
    public async Task WaitForFolderIdleAsync(long folderId, CancellationToken ct = default)
    {
        while (true)
        {
            Task pulse;
            lock (_gate) pulse = _pulse.Task;
            bool due;
            lock (_gate) due = _schedules.TryGetValue(folderId, out var schedule) && schedule.Schedule.DueAt is not null;
            if (!due && !_store.FolderHasPendingWork(folderId)) return;
            await Task.WhenAny(pulse, Task.Delay(100, ct)).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
        }
    }

    /// <summary>Deterministic seam: attempts one due job (scan, then extraction, then embedding/gc).</summary>
    public async Task<bool> DrainOnceAsync(CancellationToken ct = default)
    {
        await TickAsync(_milliseconds(), ct).ConfigureAwait(false);
        foreach (string kind in new[] { "scan", "extract", "embed", "gc" })
            if (await _queue.RunOneAsync(kind, ReservationAsync, Execute(kind), ct).ConfigureAwait(false)) return true;
        return false;
    }

    /// <summary>
    /// Test/timer seam: samples the memory-pressure probe (contract <c>ingestion-memory-pressure-v1</c> §3: every tick,
    /// a failing probe reads as normal), then queues due debounced rescans. A due schedule keeps requesting (the store
    /// coalesces the queued job) until that folder's scan actually starts.
    /// </summary>
    internal Task TickAsync(long milliseconds, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        MemoryPressureLevel? sampled = null;
        if (_memoryPressure is not null)
        {
            MemoryPressureLevel level;
            try { level = _memoryPressure(); }
            catch (Exception) { level = MemoryPressureLevel.Normal; }
            _admission.SetMemoryPressure(level);
            sampled = level;
        }
        ApplyConcurrency(milliseconds, sampled);
        List<(long FolderId, bool ForceHash)> due = [];
        lock (_gate)
            foreach (var (folderId, schedule) in _schedules)
                if (schedule.Schedule.IsDue(milliseconds)) due.Add((folderId, schedule.ForceHash));
        foreach (var (folderId, forceHash) in due)
        {
            if (_store.Folder(folderId) is null) continue;
            _store.RequestFolderScan(folderId, forceHash, _clock.Now);
        }
        if (due.Count > 0) Pulse();
        return Task.CompletedTask;
    }

    /// <summary>
    /// Every <see cref="AdaptiveConcurrency.SampleIntervalMs"/> of ticks: samples the system probe, runs the target
    /// through the governor and applies the limit to admission (addendum A §A.4). A failing probe reads as idle.
    /// </summary>
    private void ApplyConcurrency(long milliseconds, MemoryPressureLevel? memory)
    {
        if (_systemLoad is null) return;
        int limit;
        lock (_gate)
        {
            if (_lastSystemSample is long last && milliseconds >= last && milliseconds - last < AdaptiveConcurrency.SampleIntervalMs)
                return;
            _lastSystemSample = milliseconds;
            SystemSample sample;
            try { sample = _systemLoad(); }
            catch (Exception) { sample = new SystemSample(Environment.ProcessorCount, 0); }
            int target = AdaptiveConcurrency.Target(sample, _admission.RunningExtractions, memory ?? _admission.PressureLevel);
            limit = _governor.Observe(target, milliseconds);
        }
        _admission.SetConcurrencyLimit(limit);
    }

    /// <summary>
    /// Wakes durable embedding for every notebook whose selected embedding space has unindexed published content
    /// (loose sources and notes publish through legacy paths without an embedding selection).
    /// </summary>
    public async Task<int> RequestEmbeddingWorkAsync(CancellationToken ct = default)
    {
        if (_selectedSelection is null) return 0;
        int requested = 0;
        foreach (long notebookId in _store.Notebooks().Select(n => n.Id!.Value))
        {
            ct.ThrowIfCancellationRequested();
            var selection = await _selectedSelection(notebookId).ConfigureAwait(false);
            if (selection is null || !_store.NeedsEmbeddingWork(notebookId, selection)) continue;
            _store.RequestEmbeddingBuild(notebookId, selection, copyExisting: true, _clock.Now);
            requested++;
        }
        if (requested > 0) Pulse();
        return requested;
    }

    private Func<IngestJob, JobFence, CancellationToken, Task> Execute(string kind) => kind switch
    {
        "scan" => ScanAsync,
        "extract" => (job, fence, ct) => _extraction.ExecuteAsync(job, fence, ct),
        "embed" => (job, fence, ct) => _index.ExecuteAsync(job, fence, ct),
        _ => CollectAsync
    };

    private async Task ScanAsync(IngestJob job, JobFence fence, CancellationToken ct)
    {
        long folderId = TargetId(job.Draft.Target);
        bool verifyAll = _store.ScanOptions(job.Id);
        FolderSchedule schedule;
        lock (_gate)
        {
            if (!_schedules.TryGetValue(folderId, out schedule!)) _schedules[folderId] = schedule = new FolderSchedule();
            schedule.Schedule.Started();
            schedule.ForceHash = false;
        }
        _runningScans[folderId] = 0;
        long baseline = _store.MaxIngestJobId();
        try
        {
            await _scanner.ScanAsync(folderId, verifyAll, fence, _clock.Now, ct).ConfigureAwait(false);
            await ScanCompletedAsync(folderId, baseline, ct).ConfigureAwait(false);
        }
        finally
        {
            _runningScans.TryRemove(folderId, out _);
            lock (_gate)
                if (_schedules.TryGetValue(folderId, out var current)) current.Schedule.Finished(_milliseconds());
            Pulse();
        }
    }

    /// <summary>
    /// Records the scan outcome and builds a missing index ("Scan now" on an unchanged folder). Provider errors never
    /// fail the scan job.
    /// </summary>
    private async Task ScanCompletedAsync(long folderId, long baseline, CancellationToken ct)
    {
        var folder = _store.Folder(folderId);
        if (folder is null || folder.ScanState == "scanning") return;
        if (_store.FolderScanOutcome(folderId, baseline, _clock.Now) is { } outcome) _scanOutcomes[folderId] = outcome;
        _store.NotifyIndexingStatusChanged(folder.NotebookId);
        try { await EnsureIndexBuildAsync(folder.NotebookId, ct).ConfigureAwait(false); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception error) { LastError = error; }
    }

    private Task CollectAsync(IngestJob job, JobFence fence, CancellationToken ct)
    {
        if (job.Draft.Target.StartsWith("generation:", StringComparison.Ordinal) &&
            _store.Generation(TargetId(job.Draft.Target)) is { } generation)
            _store.GarbageCollect(generation.NotebookId);
        _store.CompleteJob(fence, _clock.Now);
        return Task.CompletedTask;
    }

    /// <summary>
    /// Conservative per-job extraction reservation from the observed file size, extension and the folder's limits
    /// (Office/PDF add the expanded allowance). Unknown sources reserve the text maximum.
    /// </summary>
    private Task<long> ReservationAsync(IngestJob job, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var limits = IngestionLimits.Defaults;
        long size = limits.FileBytes;
        string extension = "txt";
        if (job.Draft.Target.StartsWith("source:", StringComparison.Ordinal) && _store.Source(TargetId(job.Draft.Target)) is { } source)
        {
            size = source.SizeBytes ?? size;
            if (source.RelPath is { } relPath) extension = FolderRuleClassifier.Extension(relPath);
            if (source.FolderId is long folderId && _store.Folder(folderId) is { } folder)
            {
                try { limits = NotebookStore.FolderRulesOf(folder).Limits; }
                catch (FolderIngestionException) { }
            }
        }
        return Task.FromResult(IngestionAdmission.ExtractionReservation(size, extension, limits));
    }

    private async Task DispatchLoopAsync(string kind, CancellationToken ct)
    {
        var execute = Execute(kind);
        while (!ct.IsCancellationRequested)
        {
            Task pulse;
            lock (_gate) pulse = _pulse.Task;
            try
            {
                if (await _queue.RunOneAsync(kind, ReservationAsync, execute, ct).ConfigureAwait(false)) continue;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
            catch (Exception error)
            {
                // The queue already recorded the failure under the job's fence; keep dispatching.
                LastError = error;
            }
            try { await Task.WhenAny(pulse, Task.Delay(1000, ct)).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
        }
    }

    /// <summary>Lease-clock seconds between two scheduler ticks (normally 100 ms apart) that mean the process was
    /// suspended, e.g. by system sleep.</summary>
    public const long WakeGapSeconds = 60;

    /// <summary>
    /// Whether two consecutive scheduler ticks bracket a suspension (contract ingestion-scan-perf-v1 §4, fixture
    /// ingestion-scan-cadence-v1).
    /// </summary>
    public static bool SuspendedBetween(long previous, long now) =>
        now >= previous && unchecked((ulong)(now - previous)) >= WakeGapSeconds;

    private async Task TimerLoopAsync(CancellationToken ct)
    {
        long previous = _clock.Now;
        while (!ct.IsCancellationRequested)
        {
            try
            {
                // Platform-neutral wake detection: the unpackaged app has no resume event to forward.
                long now = _clock.Now;
                if (SuspendedBetween(previous, now)) await SystemDidWakeAsync().ConfigureAwait(false);
                previous = now;
                await TickAsync(_milliseconds(), ct).ConfigureAwait(false);
                await Task.Delay(100, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
            catch (Exception error) { LastError = error; }
        }
    }

    private void StartWatch(FolderSource folder)
    {
        if (!folder.Draft.WatchEnabled) return;
        var watch = new Watch(folder.Id);
        lock (_gate)
        {
            if (!_started || _watchHandles.ContainsKey(folder.Id)) return;
            _watchHandles[folder.Id] = watch;
        }
        try
        {
            // The callback is token-guarded: a removed or disabled watch can never reschedule its folder.
            watch.Handle = _watches.Create(folder, kind =>
            {
                if (!watch.Valid) return;
                // Lost events force a re-hashing rescan and degrade the watch, so periodic passes rescan it again.
                if (kind == "overflow") watch.Degrade();
                _ = SignalAsync(folder.Id, _milliseconds(), FolderWatchEventPolicy.ForceHash(kind));
            });
            watch.Handle.Start();
            watch.MarkStarted();
        }
        catch (Exception error)
        {
            LastError = error;
            lock (_gate) _watchHandles.Remove(folder.Id);
            watch.Dispose();
        }
    }

    private void StopWatch(long folderId)
    {
        Watch? watch;
        lock (_gate)
        {
            if (!_watchHandles.Remove(folderId, out watch)) return;
        }
        watch.Dispose();
    }

    private void Pulse()
    {
        TaskCompletionSource previous;
        lock (_gate)
        {
            previous = _pulse;
            _pulse = NewPulse();
        }
        previous.TrySetResult();
    }

    private static TaskCompletionSource NewPulse() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    private static long TargetId(string target) =>
        long.Parse(target[(target.IndexOf(':') + 1)..], NumberStyles.None, CultureInfo.InvariantCulture);

    private sealed class FolderSchedule
    {
        public RescanSchedule Schedule { get; } = new();
        public bool ForceHash { get; set; }
    }

    private sealed class Watch(long folderId) : IDisposable
    {
        private int _valid = 1;
        private int _started;
        private int _degraded;
        public long FolderId { get; } = folderId;
        public IFolderWatchHandle? Handle { get; set; }
        public bool Valid => Volatile.Read(ref _valid) == 1;
        public bool Healthy => Valid && Volatile.Read(ref _started) == 1 && Volatile.Read(ref _degraded) == 0;
        public void MarkStarted() => Volatile.Write(ref _started, 1);
        public void Degrade() => Volatile.Write(ref _degraded, 1);

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _valid, 0) == 0) return;
            Handle?.Dispose();
        }
    }
}

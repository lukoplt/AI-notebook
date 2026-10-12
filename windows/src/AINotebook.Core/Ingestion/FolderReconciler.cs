using AINotebook.Core.Storage;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// App-lifetime durable reconciliation: on start it recovers leases, requeues due retries, repairs orphan scans to
/// partial (never missing), requeues extraction failures recorded under an older extractor revision
/// (<c>ingestion-reextract-v1</c>, every folder, watched or not), and schedules one scan for every watch-enabled folder of every notebook; afterwards an
/// injected clock drives a reconciliation every 1,800 seconds. A pass rescans a watch-enabled folder only when
/// <see cref="VerifyDue"/> says so: every pass without a healthy native watch, otherwise every 6 hours (contract
/// ingestion-scan-perf-v1 §4). Disabled folders are never auto-scanned. Scheduling never changes
/// <c>last_full_scan_at</c>; only a completed full scan does.
/// </summary>
public sealed class FolderReconciler
{
    public const long Interval = 1800;
    /// <summary>Re-verification interval of a folder whose native watch is healthy.</summary>
    public const int WatchedVerifyHours = 6;
    public const long WatchedVerifyInterval = WatchedVerifyHours * 3600L;
    private readonly NotebookStore _store;
    private readonly IIngestLeaseClock _clock;
    private readonly Func<long, bool, Task> _requestScan;
    private readonly Func<long, bool> _watchHealthy;
    private readonly object _gate = new();
    /// <summary>Lease-clock seconds of the last scan this reconciler requested per folder.</summary>
    private readonly Dictionary<long, long> _lastRequested = [];
    private CancellationTokenSource? _stopping;
    private Task? _loop;
    private long? _next;

    /// <param name="watchHealthy">The folder's native watch is running and has not reported lost events since it
    /// started. The default (no watches) keeps every pass rescanning every watch-enabled folder.</param>
    public FolderReconciler(NotebookStore store, IIngestLeaseClock clock, Func<long, bool, Task> requestScan,
        Func<long, bool>? watchHealthy = null)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _requestScan = requestScan ?? throw new ArgumentNullException(nameof(requestScan));
        _watchHealthy = watchHealthy ?? (_ => false);
    }

    /// <summary>
    /// Whether a pass requests a (stat-only) scan of a watch-enabled folder (contract ingestion-scan-perf-v1 §4,
    /// fixture ingestion-scan-cadence-v1).
    /// </summary>
    public static bool VerifyDue(bool startup, bool watchHealthy, long? lastFullScanAt, long? lastRequestedAt, long now)
    {
        if (startup || !watchHealthy) return true;
        long? last = lastFullScanAt is long full && lastRequestedAt is long requested ? Math.Max(full, requested)
            : lastFullScanAt ?? lastRequestedAt;
        if (last is not long known) return true;
        if (now < known) return false;
        // now >= known, so the unsigned difference is exact even beyond long.MaxValue.
        return unchecked((ulong)(now - known)) >= WatchedVerifyInterval;
    }

    internal bool Running { get { lock (_gate) return _loop is not null; } }
    internal long? NextReconcileAt { get { lock (_gate) return _next; } }

    /// <summary>Idempotent.</summary>
    public async Task StartAsync(CancellationToken ct = default)
    {
        lock (_gate)
            if (_loop is not null) return;
        long now = _clock.Now;
        _store.RecoverExpiredJobs(now);
        _store.RequeueRetryableJobs(now);
        _store.RepairOrphanScans(now);
        // ingestion-build-merge-v1 §4: no bootstrap builds a second generation of a building space.
        _store.MergeRedundantBootstraps(now);
        // Failures under an older extractor get one attempt with the current one.
        _store.RequeueUpgradedExtractions(now);
        // Spreadsheets published under an older canonical text, in throttled batches.
        _store.RequeueSpreadsheetUpgrades(now);
        await ScheduleWatchedAsync(now, startup: true, ct).ConfigureAwait(false);
        lock (_gate)
        {
            if (_loop is not null) return;
            _next = now + Interval;
            _stopping = new CancellationTokenSource();
            var token = _stopping.Token;
            _loop = Task.Run(() => LoopAsync(token), CancellationToken.None);
        }
    }

    public async Task StopAsync()
    {
        Task? loop;
        CancellationTokenSource? stopping;
        lock (_gate)
        {
            loop = _loop;
            stopping = _stopping;
            _loop = null;
            _stopping = null;
        }
        if (stopping is null) return;
        stopping.Cancel();
        try { if (loop is not null) await loop.ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        finally { stopping.Dispose(); }
    }

    /// <summary>
    /// One reconciliation pass if the periodic deadline has passed: recovery, due retries, upgrade requeues and one coalesced scan
    /// per watch-enabled folder (the store coalesces queued scans). Returns whether a pass ran.
    /// </summary>
    public async Task<bool> ReconcileAsync(long now, CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (_next is long due && now < due) return false;
            _next = now + Interval;
        }
        _store.RecoverExpiredJobs(now);
        _store.RequeueRetryableJobs(now);
        _store.MergeRedundantBootstraps(now);
        _store.RequeueUpgradedExtractions(now);
        // Every pass (30 min), independent of the 6 h watched-folder verification cadence.
        _store.RequeueSpreadsheetUpgrades(now);
        await ScheduleWatchedAsync(now, startup: false, ct).ConfigureAwait(false);
        return true;
    }

    private async Task ScheduleWatchedAsync(long now, bool startup, CancellationToken ct)
    {
        foreach (var folder in _store.WatchedFolders())
        {
            ct.ThrowIfCancellationRequested();
            long? requested;
            lock (_gate) requested = _lastRequested.TryGetValue(folder.Id, out long at) ? at : null;
            if (!VerifyDue(startup, _watchHealthy(folder.Id), folder.LastFullScanAt, requested, now)) continue;
            await _requestScan(folder.Id, false).ConfigureAwait(false);
            lock (_gate) _lastRequested[folder.Id] = now;
        }
    }

    private async Task LoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            long due;
            lock (_gate) due = _next ?? _clock.Now + Interval;
            await _clock.WaitUntilAsync(due, ct).ConfigureAwait(false);
            try { await ReconcileAsync(_clock.Now, ct).ConfigureAwait(false); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception error)
            {
                // Persisted state is unchanged by a failed pass; the next deadline retries it.
                System.Diagnostics.Trace.TraceError("Folder reconciliation failed: {0}", error.GetType().Name);
            }
        }
    }
}

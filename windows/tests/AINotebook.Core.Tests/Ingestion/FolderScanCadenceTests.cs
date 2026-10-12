using AINotebook.Core.Extractors;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>Periodic reconcile cadence (contract ingestion-scan-perf-v1 §4, fixture ingestion-scan-cadence-v1).</summary>
public sealed class FolderScanCadenceTests
{
    [Fact]
    public void CadenceFixture()
    {
        var fixture = SharedFixtures.Json("contracts/ingestion-scan-cadence-v1.json");
        Assert.Equal("ingestion-scan-cadence", fixture.GetProperty("contract").GetString());
        Assert.Equal(RagContractV1.Scan.PeriodicReconcileMinutes, fixture.GetProperty("periodicReconcileMinutes").GetInt32());
        Assert.Equal(FolderReconciler.WatchedVerifyHours, fixture.GetProperty("watchedVerifyHours").GetInt32());
        Assert.Equal(FolderIngestionRuntime.WakeGapSeconds, fixture.GetProperty("wakeGapSeconds").GetInt64());
        var counts = new Dictionary<string, int>();
        foreach (var row in fixture.GetProperty("cases").EnumerateArray())
        {
            var input = row.GetProperty("input");
            long? Time(string key) => input.GetProperty(key).ValueKind == System.Text.Json.JsonValueKind.Null
                ? null : input.GetProperty(key).GetInt64();
            string operation = row.GetProperty("operation").GetString()!, name = row.GetProperty("name").GetString()!;
            counts[operation] = counts.GetValueOrDefault(operation) + 1;
            if (operation == "unreadable-file") continue; // replayed through the scanner by FolderScanUnreadableTests
            bool actual = operation switch
            {
                "verify-due" => FolderReconciler.VerifyDue(input.GetProperty("startup").GetBoolean(),
                    input.GetProperty("watchHealthy").GetBoolean(), Time("lastFullScanAt"), Time("lastRequestedAt"), Time("now")!.Value),
                "wake-gap" => FolderIngestionRuntime.SuspendedBetween(Time("previous")!.Value, Time("now")!.Value),
                _ => throw new InvalidOperationException("unknown operation " + operation),
            };
            Assert.True(row.GetProperty("expected").GetBoolean() == actual, name);
        }
        Assert.Equal(13, counts["verify-due"]);
        Assert.Equal(6, counts["wake-gap"]);
        Assert.Equal(8, counts["unreadable-file"]);
    }

    private static string[] QueuedScans(NotebookStore store)
    {
        lock (store.Gate)
        {
            var queued = store.Connection.Query<string>(
                "SELECT target FROM ingest_jobs WHERE kind='scan' AND state='queued' ORDER BY target").ToArray();
            store.Connection.Execute("UPDATE ingest_jobs SET state='done' WHERE kind='scan' AND state='queued'");
            return queued;
        }
    }

    [Fact]
    public async Task HealthyWatchStretchesPeriodicRescan()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebook = store.CreateNotebook("c").Id!.Value;
        var ids = new List<long>();
        foreach (var (root, watch) in new[] { ("/healthy", true), ("/unhealthy", true), ("/manual", false) })
            ids.Add(store.CreateFolder(notebook, new FolderDraft(root, root, ["md"], [], "{}", "cp1250", watch), new CadenceFS(), 0).Id);
        long healthy = ids[0], unhealthy = ids[1];
        var clock = new CadenceClock();
        var reconciler = new FolderReconciler(store, clock, (id, verify) =>
        {
            store.RequestFolderScan(id, verify, clock.Now);
            return Task.CompletedTask;
        }, id => id == healthy);
        await reconciler.StartAsync();
        try
        {
            Assert.Equal(new[] { $"folder:{healthy}", $"folder:{unhealthy}" }, QueuedScans(store)); // startup scans every watched folder
            Assert.True(await reconciler.ReconcileAsync(1800));
            Assert.Equal(new[] { $"folder:{unhealthy}" }, QueuedScans(store)); // a healthy watch skips the 30-minute rescan
            Assert.True(await reconciler.ReconcileAsync(FolderReconciler.WatchedVerifyInterval - 1));
            Assert.Equal(new[] { $"folder:{unhealthy}" }, QueuedScans(store));
            // A pass is due every 30 minutes after the previous one.
            long verify = FolderReconciler.WatchedVerifyInterval - 1 + FolderReconciler.Interval;
            Assert.True(await reconciler.ReconcileAsync(verify));
            Assert.Equal(new[] { $"folder:{healthy}", $"folder:{unhealthy}" }, QueuedScans(store)); // re-verified every 6 hours
            // A completed full scan also counts as verification.
            long later = verify + FolderReconciler.WatchedVerifyInterval;
            lock (store.Gate)
                store.Connection.Execute("UPDATE folder_sources SET last_full_scan_at=$at WHERE id=$id", new { at = later - 60, id = healthy });
            Assert.True(await reconciler.ReconcileAsync(later));
            Assert.Equal(new[] { $"folder:{unhealthy}" }, QueuedScans(store));
        }
        finally
        {
            await reconciler.StopAsync();
        }
    }

    [Fact]
    public async Task RuntimeWatchHealthOverflowAndWake()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebook = store.CreateNotebook("w").Id!.Value;
        var fs = new CadenceFS();
        var folder = store.CreateFolder(notebook, new FolderDraft("/w", "W", ["md"], [], "{}", "cp1250", true), fs, 0);
        var watches = new CadenceWatches();
        long ms = 1_000;
        var clock = new CadenceClock();
        var admission = new IngestionAdmission();
        var extractor = new BoundedDocumentExtractor();
        Func<long, Task<EmbeddingSelection?>> none = _ => Task.FromResult<EmbeddingSelection?>(null);
        var runtime = new FolderIngestionRuntime(store, new FolderScanner(store, fs, UnicodeTables.LoadBundled(), clock),
            new FolderExtractionWorker(store, fs, LanguageDetector.Unavailable, clock, none, (uri, type, rules, ct) => extractor.ExtractAsync(uri, type, rules, ct)),
            new FolderIndexCoordinator(store, admission, clock, (_, _) => Task.FromResult<FolderEmbeddingSession?>(null), none),
            new JobQueue(store, clock, admission), clock, admission, watches, () => Interlocked.Read(ref ms), identity: fs)
        { AutoDispatch = false };
        Assert.False(runtime.IsWatchHealthy(folder.Id)); // no watch before start
        await runtime.StartAsync();
        try
        {
            Assert.True(runtime.IsWatchHealthy(folder.Id));
            while (await runtime.DrainOnceAsync()) { } // the startup scan
            Assert.Equal("idle", store.Folder(folder.Id)!.ScanState);
            long ScanJobs() { lock (store.Gate) return store.Connection.ExecuteScalar<long>("SELECT count(*) FROM ingest_jobs WHERE kind='scan'"); }
            long before = ScanJobs();

            // Wake: one debounced stat-only rescan of every watched folder.
            await runtime.SystemDidWakeAsync();
            Interlocked.Exchange(ref ms, 1_000 + RagContractV1.Scan.WatchMaxCoalesceMs);
            await runtime.TickAsync(Interlocked.Read(ref ms));
            Assert.Equal(before + 1, ScanJobs());
            long wakeJob;
            lock (store.Gate) wakeJob = store.Connection.ExecuteScalar<long>("SELECT max(id) FROM ingest_jobs WHERE kind='scan'");
            Assert.False(store.ScanOptions(wakeJob));

            // Lost events (overflow / watcher error) degrade the watch; periodic passes rescan it again.
            watches.Raise(folder.Id, "overflow");
            Assert.False(runtime.IsWatchHealthy(folder.Id));
        }
        finally
        {
            await runtime.StopAsync();
        }
    }

    private sealed class CadenceClock : IIngestLeaseClock
    {
        public long Now => 0;
        public Task WaitUntilAsync(long deadline, CancellationToken ct) => Task.Delay(Timeout.Infinite, ct);
    }

    private sealed class CadenceFS : IFolderFileSystem
    {
        public FolderIdentity Resolve(string rootPath) => new("cadence", rootPath.Split('/', StringSplitOptions.RemoveEmptyEntries), rootPath);
        public bool CaseSensitive(FolderSource root) => true;
        public IReadOnlyList<FolderEntry> List(FolderSource root, string directory) => [];
        public FileStamp Stat(FolderSource root, string relativePath) => new(root.Identity.RootFileId, 0, 0);
        public FolderRead Hash(FolderSource root, string relativePath, long maxBytes) => throw new InvalidOperationException();
        public FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes) => throw new InvalidOperationException();
    }

    private sealed class CadenceWatches : IFolderWatchFactory
    {
        private readonly Dictionary<long, Action<string>> _callbacks = [];
        public IFolderWatchHandle Create(FolderSource folder, Action<string> onEvent)
        {
            lock (_callbacks) _callbacks[folder.Id] = onEvent;
            return new Handle();
        }
        public void Raise(long folderId, string kind)
        {
            Action<string> callback;
            lock (_callbacks) callback = _callbacks[folderId];
            callback(kind);
        }
        private sealed class Handle : IFolderWatchHandle
        {
            public void Start() { }
            public void Dispose() { }
        }
    }
}

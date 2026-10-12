using System.Text;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>
/// Parallel look-ahead hashing (contract <c>ingestion-memory-pressure-v1</c> addendum A §A.5) commits exactly what the
/// sequential scan committed; the runtime tick governs the admission limit.
/// </summary>
public sealed class FolderScanHashAheadTests
{
    private static readonly Lazy<UnicodeTables> Tables = new(UnicodeTables.LoadBundled);

    private sealed class HashMeter
    {
        private readonly object _lock = new();
        private int _active;
        public int Peak { get; private set; }
        public int Calls { get; private set; }
        public void Enter() { lock (_lock) { _active++; Calls++; Peak = Math.Max(Peak, _active); } }
        public void Leave() { lock (_lock) _active--; }
    }

    /// <summary>Two-level tree with per-file hash failures: grew past the limit, vanished, became a link (unreadable files
    /// are added by the rescans; any unreadable file only leaves its directory incomplete, contract
    /// ingestion-scan-perf-v1 §5).</summary>
    private sealed class TreeFS : IFolderFileSystem
    {
        public Dictionary<string, List<FolderEntry>> Directories { get; } = new(StringComparer.Ordinal);
        public Dictionary<string, FileStamp> Files { get; } = new(StringComparer.Ordinal);
        public Dictionary<string, Exception> Failures { get; } = new(StringComparer.Ordinal);
        public required HashMeter Meter { get; init; }

        public static TreeFS Make(HashMeter meter, Func<string, long>? mtime = null)
        {
            var fs = new TreeFS { Meter = meter };
            FolderEntry Dir(string path) => new(path, true, false, new FileStamp("dir:" + path, 0, 0));
            FolderEntry File(string path, bool link = false)
            {
                var stamp = new FileStamp("id:" + path, mtime?.Invoke(path) ?? 1, Encoding.UTF8.GetByteCount(path));
                if (!link) fs.Files[path] = stamp;
                return new FolderEntry(path, false, link, stamp);
            }
            // Files before and after the subdirectories: look-ahead spans the descent.
            fs.Directories[""] = [.. Enumerable.Range(0, 12).Select(i => File($"r{i:D2}.md")), Dir("a"), Dir("b"),
                .. Enumerable.Range(12, 8).Select(i => File($"r{i:D2}.{(i % 4 == 0 ? "png" : "md")}")), File("zlink.md", link: true)];
            fs.Directories["a"] = [.. Enumerable.Range(0, 40).Select(i => File($"a/f{i:D2}.md"))];
            fs.Directories["b"] = [.. Enumerable.Range(0, 40).Select(i => File($"b/f{i:D2}.txt"))];
            fs.Failures["b/f17.txt"] = new FolderIngestionException("fileLimit");
            fs.Failures["a/f30.md"] = new FileNotFoundException("gone");
            fs.Failures["a/f12.md"] = new FolderIngestionException("interiorLink");
            return fs;
        }

        public FolderIdentity Resolve(string rootPath) => new("tree", ["tree"], "root");
        public bool CaseSensitive(FolderSource root) => true;
        public IReadOnlyList<FolderEntry> List(FolderSource root, string directory) =>
            Directories.TryGetValue(directory, out var entries) ? entries : [];
        public FileStamp Stat(FolderSource root, string relativePath) =>
            relativePath.Length == 0 ? new FileStamp("root", 0, 0)
            : Directories.ContainsKey(relativePath) ? new FileStamp("dir:" + relativePath, 0, 0)
            : Files.TryGetValue(relativePath, out var stamp) ? stamp : throw new FileNotFoundException(relativePath);
        public FolderRead Hash(FolderSource root, string relativePath, long maxBytes)
        {
            Meter.Enter();
            try
            {
                Thread.Sleep(1); // long enough for concurrent hashes to overlap
                if (Failures.TryGetValue(relativePath, out var failure)) throw failure;
                return Files.TryGetValue(relativePath, out var stamp)
                    ? new FolderRead([], stamp, $"h:{relativePath}:{stamp.MtimeNs}")
                    : throw new FileNotFoundException(relativePath);
            }
            finally { Meter.Leave(); }
        }
        public FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes) => throw new NotSupportedException();
    }

    private sealed class Clock : IIngestLeaseClock
    {
        public long Now => 10;
        public Task WaitUntilAsync(long deadline, CancellationToken ct) => Task.CompletedTask;
    }

    private static NotebookStore MakeStore()
    {
        var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        store.CreateNotebook("nb");
        store.CreateFolder(1, new FolderDraft("/tree", "Tree", ["md", "txt"], [], "{}", "cp1250", true), TreeFS.Make(new HashMeter()), 0);
        return store;
    }

    private static async Task Scan(NotebookStore store, TreeFS fs, int width, string token, bool verifyAll)
    {
        long job = store.RequestFolderScan(1, verifyAll, 10);
        Assert.NotNull(store.ClaimJob(10, token, job));
        await new FolderScanner(store, fs, Tables.Value, new Clock(), () => width).ScanAsync(1, verifyAll, new JobFence(job, token), 10);
    }

    /// <summary>Everything a scan decides, independent of row ids and lease tokens.</summary>
    private static string State(NotebookStore store)
    {
        var text = new StringBuilder();
        lock (store.Gate)
        {
            void Rows(string sql)
            {
                foreach (IDictionary<string, object?> row in store.Connection.Query(sql))
                    text.AppendLine(string.Join("|", row.Select(pair => $"{pair.Key}={pair.Value}")));
            }
            Rows("SELECT rel_path,kind,skip_reason,mtime,size_bytes,seen_generation FROM scan_items ORDER BY rel_path");
            Rows("SELECT rel_path,status,availability,eligible,content_hash,mtime,size_bytes FROM sources ORDER BY rel_path");
            Rows("""
                SELECT s.rel_path,j.state FROM ingest_jobs j JOIN sources s ON j.target='source:'||s.id
                WHERE j.kind='extract' ORDER BY s.rel_path,j.id
                """);
            Rows("SELECT scan_state,scan_generation,last_scan_error FROM folder_sources");
        }
        return text.ToString();
    }

    [Fact]
    public async Task ParallelHashingCommitsExactlyTheSequentialScan()
    {
        var states = new List<string>();
        foreach (int width in new[] { 1, 4 })
        {
            var meter = new HashMeter();
            using var store = MakeStore();
            // First scan (everything new), then Verify all after some files changed, then a stat-only rescan.
            await Scan(store, TreeFS.Make(meter), width, "first", false);
            int firstPeak = meter.Peak, firstCalls = meter.Calls;
            var changed = TreeFS.Make(meter, path => path.EndsWith("3.md", StringComparison.Ordinal) ? 2 : 1);
            changed.Failures["a/f08.md"] = new IOException("busy");
            changed.Failures["b/f05.txt"] = new UnauthorizedAccessException("denied");
            changed.Directories["b"].RemoveRange(37, 3); // vanished files: missing-marking must agree too
            foreach (string path in new[] { "b/f37.txt", "b/f38.txt", "b/f39.txt" }) changed.Files.Remove(path);
            await Scan(store, changed, width, "verify", true);
            await Scan(store, changed, width, "plain", false);
            Assert.True(firstCalls > 90);
            if (width == 1) Assert.Equal(1, firstPeak);
            else Assert.True(firstPeak > 1, $"width {width} hashes concurrently (peak {firstPeak})");
            Assert.True(meter.Peak <= width);
            states.Add(State(store));
        }
        Assert.Equal(states[0], states[1]);
        Assert.True(states[0].Contains("rel_path=b/f17.txt|kind=skipped|skip_reason=over_limit", StringComparison.Ordinal), states[0]);
    }

    private sealed class SampleProbe(SystemSample sample)
    {
        public SystemSample Sample { get; set; } = sample;
        public int Reads { get; private set; }
        public SystemSample Get() { Reads++; return Sample; }
    }

    [Fact]
    public async Task RuntimeTickGovernsTheAdmissionLimit()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        var fs = TreeFS.Make(new HashMeter());
        var clock = new Clock();
        var admission = new IngestionAdmission(6, 1L << 30);
        var extractor = new BoundedDocumentExtractor();
        var probe = new SampleProbe(new SystemSample(12, 0));
        Func<long, Task<EmbeddingSelection?>> none = _ => Task.FromResult<EmbeddingSelection?>(null);
        await using var runtime = new FolderIngestionRuntime(store, new FolderScanner(store, fs, Tables.Value, clock),
            new FolderExtractionWorker(store, fs, LanguageDetector.Unavailable, clock, none, (uri, type, rules, ct) => extractor.ExtractAsync(uri, type, rules, ct)),
            new FolderIndexCoordinator(store, admission, clock, (_, _) => Task.FromResult<FolderEmbeddingSession?>(null), none),
            new JobQueue(store, clock, admission), clock, admission, new NoWatches(), () => 0,
            memoryPressure: () => MemoryPressureLevel.Normal, identity: fs, systemLoad: probe.Get) { AutoDispatch = false };
        async Task<int> Limit(long ms)
        {
            await runtime.TickAsync(ms);
            return admission.ConcurrencyLimit;
        }
        Assert.Equal(2, await Limit(0)); // starts at the previous fixed concurrency
        Assert.Equal(2, await Limit(1_000));
        Assert.Equal(1, probe.Reads); // sampled at most every 2 s
        Assert.Equal(6, await Limit(30_000)); // an idle machine gets the cap after the hold
        probe.Sample = new SystemSample(12, 0, OnBattery: true);
        Assert.Equal(6, await Limit(31_000)); // not sampled yet
        Assert.Equal(2, await Limit(32_000)); // battery steps down at once
        probe.Sample = new SystemSample(12, 12_000);
        Assert.Equal(1, await Limit(34_000)); // a busy machine gets one worker
        probe.Sample = new SystemSample(12, 0, ThermalState.Serious);
        Assert.Equal(1, await Limit(70_000)); // serious thermal state never raises
    }

    private sealed class NoWatches : IFolderWatchFactory
    {
        public IFolderWatchHandle Create(FolderSource folder, Action<string> onEvent) => throw new NotSupportedException();
    }
}

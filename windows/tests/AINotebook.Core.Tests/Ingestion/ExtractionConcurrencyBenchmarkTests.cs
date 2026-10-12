using System.Diagnostics;
using System.Globalization;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Dapper;
using Microsoft.Data.Sqlite;
using Xunit;
using Xunit.Abstractions;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>
/// Opt-in CPU benchmark (AINOTEBOOK_CPU_BENCH=1, contract <c>ingestion-memory-pressure-v1</c> addendum A): the first
/// scan (hashing) and the full extraction of a synthetic mixed folder through the real scanner, job queue, admission,
/// extractors and language detector, at several worker counts. Reports wall time and process CPU time (CPU / wall =
/// average busy cores). The corpus comes from <c>tools/benchmark/gen_cpu_corpus.py</c> (generated on first use) or
/// from AINOTEBOOK_CPU_BENCH_DIR (any real folder). Knobs as in the Swift twin. Without the variable it returns
/// immediately (xunit 2 has no dynamic skip).
/// </summary>
[Trait("Category", "Benchmark")]
public sealed class ExtractionConcurrencyBenchmarkTests(ITestOutputHelper output)
{
    private static string? Env(string name) => Environment.GetEnvironmentVariable(name);

    private static string Corpus()
    {
        if (Env("AINOTEBOOK_CPU_BENCH_DIR") is { } dir) return dir;
        int files = int.TryParse(Env("AINOTEBOOK_CPU_BENCH_FILES"), NumberStyles.Integer, CultureInfo.InvariantCulture, out int n) ? n : 400;
        string outDir = Path.Combine(Path.GetTempPath(), $"ainotebook-cpu-corpus-{files}");
        string root = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(root, "tools", "benchmark", "gen_cpu_corpus.py")))
            root = Path.GetDirectoryName(root) ?? throw new InvalidOperationException("repository root not found");
        using var process = Process.Start(new ProcessStartInfo("python3")
        {
            ArgumentList = { Path.Combine(root, "tools", "benchmark", "gen_cpu_corpus.py"), outDir, "--files", files.ToString(CultureInfo.InvariantCulture) },
            UseShellExecute = false
        })!;
        process.WaitForExit();
        Assert.Equal(0, process.ExitCode);
        return outDir;
    }

    [Fact]
    public async Task FolderExtractionConcurrency()
    {
        if (Env("AINOTEBOOK_CPU_BENCH") != "1") return;
        string root = Corpus();
        int[] widths = (Env("AINOTEBOOK_CPU_BENCH_WIDTHS") ?? "1,2,4,6,8").Split(',')
            .Select(w => int.Parse(w, CultureInfo.InvariantCulture)).ToArray();
        long budgetMb = long.TryParse(Env("AINOTEBOOK_CPU_BENCH_BUDGET_MB"), NumberStyles.Integer, CultureInfo.InvariantCulture, out long b) ? b : 0;
        long budget = budgetMb > 0 ? budgetMb * 1_048_576 : IngestionAdmission.Standard().MemoryBytes;
        int? fixedHashWidth = int.TryParse(Env("AINOTEBOOK_CPU_BENCH_HASH_WIDTH"), NumberStyles.Integer, CultureInfo.InvariantCulture,
            out int h) ? h : null;
        var tables = UnicodeTables.LoadBundled();
        var detector = LanguageDetector.LoadBundled();
        var fs = new NativeFolderFileSystem();
        var clock = new SystemIngestLeaseClock();
        var self = Process.GetCurrentProcess();
        output.WriteLine(string.Format(CultureInfo.InvariantCulture, "CPU-BENCH dotnet corpus={0} cores={1} budget={2}MB",
            root, Environment.ProcessorCount, budget / 1_048_576));

        // Stage breakdown on one core: parse (extractor) vs detect + chunk (Prepare); the rest of a job is
        // snapshot/verify IO and the serialized publication transaction.
        if (Env("AINOTEBOOK_CPU_BENCH_STAGES") != "0")
        {
            var stageExtractor = new BoundedDocumentExtractor();
            var stats = new SortedDictionary<string, (double Parse, double Prepare, int Count)>(StringComparer.Ordinal);
            foreach (string file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories).Order(StringComparer.Ordinal))
            {
                string extension = FolderRuleClassifier.Extension(file);
                if (SourceTypeExtensions.Detect(Path.GetFileName(file)) is not { } kind) continue;
                long t0 = Stopwatch.GetTimestamp();
                CanonicalDocument document;
                try { document = await stageExtractor.ExtractAsync(new Uri(file), kind, FolderRules.Defaults); }
                catch (Exception) { continue; }
                long t1 = Stopwatch.GetTimestamp();
                FolderExtractionWorker.Prepare(document, "x", 0, Path.GetFileName(file), detector, IngestionLimits.Defaults);
                long t2 = Stopwatch.GetTimestamp();
                var current = stats.GetValueOrDefault(extension);
                stats[extension] = (current.Parse + Stopwatch.GetElapsedTime(t0, t1).TotalSeconds,
                    current.Prepare + Stopwatch.GetElapsedTime(t1, t2).TotalSeconds, current.Count + 1);
            }
            foreach (var (extension, (parse, prepare, count)) in stats)
                output.WriteLine(string.Format(CultureInfo.InvariantCulture,
                    "CPU-BENCH dotnet stage {0} x{1}: parse {2:F2}s ({3:F1} ms/file), detect+chunk {4:F2}s ({5:F1} ms/file)",
                    extension, count, parse, parse * 1000 / count, prepare, prepare * 1000 / count));
        }

        foreach (int width in widths)
        {
            string path = Path.Combine(Path.GetTempPath(), $"cpu-bench-cs-{Guid.NewGuid():N}.sqlite");
            try
            {
                using var store = new NotebookStore(new StorePath(path), configuredEmbeddingModelKey: null);
                long notebookId = store.CreateNotebook("bench").Id!.Value;
                var folder = store.CreateFolder(notebookId, new FolderDraft(root, "Bench", FolderRules.Defaults.IncludeExts,
                    FolderRules.Defaults.IgnoreGlobs, "{}", "cp1250", false), fs, clock.Now);

                // First scan: every file is new, so every eligible file is hashed.
                int hashWidth = fixedHashWidth ?? AdaptiveConcurrency.HashWidth(width);
                long scanJob = store.RequestFolderScan(folder.Id, false, clock.Now);
                Assert.NotNull(store.ClaimJob(clock.Now, "scan", scanJob));
                var scanner = new FolderScanner(store, fs, tables, clock, () => hashWidth);
                self.Refresh();
                var cpu = self.TotalProcessorTime;
                long start = Stopwatch.GetTimestamp();
                await scanner.ScanAsync(folder.Id, false, new JobFence(scanJob, "scan"), clock.Now);
                double scanWall = Stopwatch.GetElapsedTime(start).TotalSeconds;
                self.Refresh();
                double scanCpu = (self.TotalProcessorTime - cpu).TotalSeconds;
                long queued;
                lock (store.Gate)
                    queued = store.Connection.ExecuteScalar<long>("SELECT count(*) FROM ingest_jobs WHERE kind='extract' AND state='queued'");

                // Full extraction: `width` dispatch loops over one admission, as the runtime runs them.
                var admission = new IngestionAdmission(width, budget);
                var queue = new JobQueue(store, clock, admission);
                var extractor = new BoundedDocumentExtractor();
                var worker = new FolderExtractionWorker(store, fs, detector, clock, _ => Task.FromResult<EmbeddingSelection?>(null),
                    (uri, type, rules, ct) => extractor.ExtractAsync(uri, type, rules, ct));
                Task<long> Reservation(IngestJob job, CancellationToken ct)
                {
                    var source = store.Source(long.Parse(job.Draft.Target["source:".Length..], CultureInfo.InvariantCulture))!;
                    return Task.FromResult(IngestionAdmission.ExtractionReservation(source.SizeBytes ?? 0,
                        FolderRuleClassifier.Extension(source.RelPath!), IngestionLimits.Defaults));
                }
                self.Refresh();
                cpu = self.TotalProcessorTime;
                start = Stopwatch.GetTimestamp();
                await Task.WhenAll(Enumerable.Range(0, width).Select(_ => Task.Run(async () =>
                {
                    while (true)
                    {
                        bool ran;
                        try { ran = await queue.RunOneAsync("extract", Reservation, (job, fence, ct) => worker.ExecuteAsync(job, fence, ct)); }
                        catch (Exception) { ran = false; }
                        if (!ran) return;
                    }
                })));
                double wall = Stopwatch.GetElapsedTime(start).TotalSeconds;
                self.Refresh();
                double used = (self.TotalProcessorTime - cpu).TotalSeconds;
                long ready, notDone, chunks;
                lock (store.Gate)
                {
                    ready = store.Connection.ExecuteScalar<long>("SELECT count(*) FROM sources WHERE folder_id=$id AND status='ready'", new { id = folder.Id });
                    notDone = store.Connection.ExecuteScalar<long>("SELECT count(*) FROM ingest_jobs WHERE kind='extract' AND state<>'done'");
                    chunks = store.Connection.ExecuteScalar<long>("SELECT count(*) FROM source_chunks");
                }
                output.WriteLine(string.Format(CultureInfo.InvariantCulture,
                    "CPU-BENCH dotnet width={0} hashWidth={1}: scan {2} files {3:F2}s wall {4:F2}s cpu ({5:F2} cores) | extract {6} files ({7} not done) {8} chunks: {9:F2}s wall {10:F2}s cpu ({11:F2} cores busy) {12:F1} files/s",
                    width, hashWidth, queued, scanWall, scanCpu, scanCpu / Math.Max(scanWall, 1e-9), ready, notDone, chunks,
                    wall, used, used / Math.Max(wall, 1e-9), ready / Math.Max(wall, 1e-9)));
                Assert.Equal(queued, ready);
            }
            finally
            {
                SqliteConnection.ClearAllPools();
                foreach (string suffix in new[] { "", "-journal", "-wal", "-shm" }) File.Delete(path + suffix);
            }
        }
    }
}

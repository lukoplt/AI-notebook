using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>
/// Shared <c>ingestion-retry-cap-v1</c> fixture plus the end-to-end failure budget: a file that fails extraction three
/// times is given up until its content changes or the user retries.
/// </summary>
public sealed class RetryCapContractTests
{
    private static JsonElement Fixture()
    {
        var fixture = SharedFixtures.Json("contracts/ingestion-retry-cap-v1.json");
        Assert.Equal("ingestion-retry-cap", fixture.GetProperty("contract").GetString());
        Assert.Equal(1, fixture.GetProperty("version").GetInt32());
        return fixture;
    }

    /// <summary>Compact JSON with sorted object keys.</summary>
    private static string Canonical(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.Object => "{" + string.Join(",", e.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal)
            .Select(p => JsonSerializer.Serialize(p.Name) + ":" + Canonical(p.Value))) + "}",
        JsonValueKind.Array => "[" + string.Join(",", e.EnumerateArray().Select(Canonical)) + "]",
        _ => e.GetRawText(),
    };

    private static string Canonical(object? value) => Canonical(JsonSerializer.SerializeToElement(value));

    private static string Normalize(string sql) => string.Join("\n", sql.Split('\n').Select(line => line.Trim())
        .Where(line => line.Length > 0));

    [Fact]
    public void ConstantsAndMigrationMatchFixture()
    {
        var fixture = Fixture();
        Assert.Equal(ExtractionRetryBudget.Failures, fixture.GetProperty("failureBudget").GetInt32());
        Assert.Equal(ExtractionRetryBudget.ExtractMaxAttempts, fixture.GetProperty("extractMaxAttempts").GetInt32());
        Assert.Equal("v21_extract_retry_budget", fixture.GetProperty("migration").GetString());
        Assert.Equal(Normalize(fixture.GetProperty("schemaDDL").GetString()!), Normalize(MigrationV21.Ddl));
        // The SQL predicates spell the budget out; they must agree with the constant.
        Assert.Contains($">={ExtractionRetryBudget.Failures})", RetryBudgetSQL.GaveUpPredicate, StringComparison.Ordinal);
        Assert.EndsWith($"<{ExtractionRetryBudget.Failures}", RetryBudgetSQL.BudgetLeftPredicate, StringComparison.Ordinal);
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        lock (store.Gate)
        {
            var columns = store.Connection.Query("""
                SELECT name,"notnull",dflt_value,pk FROM pragma_table_info('source_extract_budget') ORDER BY cid
                """).Select(r => $"{(string)r.name}:{(long)r.notnull}:{(string?)r.dflt_value ?? "null"}:{(long)r.pk}").ToArray();
            Assert.Equal(new[] { "source_id:0:null:1", "failures:1:0:0", "content_hash:0:null:0" }, columns);
            var keys = store.Connection.Query("""SELECT "table","from",on_delete FROM pragma_foreign_key_list('source_extract_budget')""")
                .Select(r => $"{(string)r.table}.{(string)r.from}:{(string)r.on_delete}").ToArray();
            Assert.Equal(new[] { "sources.source_id:CASCADE" }, keys);
            Assert.Equal(1L, store.Connection.ExecuteScalar<long>(
                "SELECT count(*) FROM grdb_migrations WHERE identifier='v21_extract_retry_budget'"));
        }
    }

    [Fact]
    public void UpgradeFromV18KeepsRowsWithAnEmptyBudget()
    {
        string directory = Path.Combine(Path.GetTempPath(), $"ainotebook-v21-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "db.sqlite");
        File.Copy(SharedFixtures.Path("storage/v18.sqlite"), path);
        try
        {
            using var store = new NotebookStore(new StorePath(path), configuredEmbeddingModelKey: null);
            lock (store.Gate)
            {
                Assert.True(store.Connection.ExecuteScalar<long>("SELECT count(*) FROM sources") > 0);
                Assert.Equal(0L, store.Connection.ExecuteScalar<long>("SELECT count(*) FROM source_extract_budget"));
                Assert.Empty(store.Connection.Query("PRAGMA foreign_key_check"));
            }
        }
        finally
        {
            try { Directory.Delete(directory, true); } catch (IOException) { }
        }
    }

    // ---------------------------------------------------------------- fixture

    private sealed class FixedIdentity : IFolderPathIdentity
    {
        public FolderIdentity Resolve(string rootPath) => new("v", ["docs"], "r");
    }

    /// <summary>Store-level harness of one case: every step runs the production entry point.</summary>
    private sealed class Harness : IDisposable
    {
        private int _tokens;
        private JobFence? _fence;

        public Harness()
        {
            Store.CreateNotebook("retry-cap");
            var defaults = FolderRules.Defaults;
            Store.CreateFolder(1, new FolderDraft("/docs", "Docs", defaults.IncludeExts, defaults.IgnoreGlobs, "{}",
                defaults.EncodingFallback, false), new FixedIdentity(), 0);
        }

        public NotebookStore Store { get; } = new(StorePath.InMemory, configuredEmbeddingModelKey: null);
        private const long SourceId = 1;

        private string Token() => "lease-" + ++_tokens;

        private long ExtractJobCount()
        {
            lock (Store.Gate) return Store.Connection.ExecuteScalar<long>("SELECT count(*) FROM ingest_jobs WHERE kind='extract'");
        }

        private Dictionary<string, object?> Observe(long at, JsonElement step)
        {
            var stamp = new FileStamp("file", step.GetProperty("mtime").GetInt64(), step.GetProperty("size").GetInt64());
            bool verifyAll = step.GetProperty("verifyAll").GetBoolean();
            long before = ExtractJobCount();
            long scan = Store.RequestFolderScan(1, verifyAll, at);
            string lease = Token();
            Assert.NotNull(Store.ClaimJob(at, lease, scan));
            var ticket = Store.BeginFolderScan(1, new JobFence(scan, lease), at);
            Assert.NotNull(ticket);
            bool read = verifyAll || !(Store.FolderKnownSources(1).TryGetValue("a.docx", out var known) && known.FastPath(stamp));
            Store.ObserveFolderFiles(ticket!, [FolderScanObservation.File(new FolderObservation("a.docx", stamp, "eligible", null,
                read ? step.GetProperty("hash").GetString() : null))], at);
            Assert.True(Store.FinishFolderScan(ticket!, new ScanCompletion([""], [], false, null), at));
            return new() { ["read"] = read, ["queued"] = ExtractJobCount() > before };
        }

        public Dictionary<string, object?> Run(JsonElement step)
        {
            long at = step.GetProperty("at").GetInt64();
            switch (step.GetProperty("op").GetString())
            {
                case "observe":
                    return Observe(at, step);
                case "loose":
                {
                    string? raw = step.GetProperty("rawPath").GetBoolean() ? "/nonexistent/retry-cap/a.txt" : null;
                    bool url = step.TryGetProperty("url", out var u) && u.GetBoolean();
                    Store.CreateSource(1, url ? SourceType.Web : SourceType.Text, "a",
                        uri: url ? "https://example.org/" : null, rawPath: raw);
                    return new();
                }
                case "begin":
                {
                    string lease = Token();
                    _fence = Store.BeginExtraction(SourceId, at, lease);
                    return new();
                }
                case "abandon":
                {
                    if (_fence is not { } fence) return new() { ["abandoned"] = false };
                    _fence = null;
                    return new() { ["abandoned"] = Store.AbandonLooseExtraction(fence, at) };
                }
                case "claim":
                {
                    string lease = Token();
                    var job = Store.ClaimJob(at, lease);
                    _fence = job is null ? null : new JobFence(job.Id, lease);
                    return new() { ["claimed"] = job is not null };
                }
                case "fail":
                {
                    if (_fence is not { } fence) return new() { ["failed"] = false };
                    _fence = null;
                    return new() { ["failed"] = Store.FailJob(fence, step.GetProperty("code").GetString()!, at) };
                }
                case "expire":
                    return new() { ["recovered"] = Store.RecoverExpiredJobs(at) };
                case "requeue":
                    return new() { ["requeued"] = Store.RequeueRetryableJobs(at) };
                case "publish":
                {
                    if (_fence is not { } fence) return new() { ["published"] = false };
                    _fence = null;
                    var draft = new RevisionDraft(step.GetProperty("hash").GetString()!, "abc", 1, 2);
                    RevisionChunkDraft[] chunks = [new RevisionChunkDraft("abc", 1, null, 0, 3, null, false)];
                    var metadata = new PublicationMetadata("utf-8", null, null, "{}", [new PageBoundary(1, 0, 3)]);
                    // A loose source publishes without folder stat/rule checks.
                    var revision = Store.ExtractionRequest(SourceId) is { } request
                        ? Store.PublishFolderExtraction(request, draft, chunks, metadata, null, fence, at)
                        : Store.PublishLooseExtraction(SourceId, draft, chunks, metadata, null, fence, at);
                    return new() { ["published"] = revision is not null };
                }
                case "retry":
                    return new() { ["retried"] = Store.RetryFailedExtraction(SourceId, at) };
                case "retryAll":
                    return new() { ["retried"] = Store.RetryFailedExtractions(1, at) };
                case "upgrade":
                    return new() { ["requeued"] = Store.RequeueUpgradedExtractions(at) };
                case "forget":
                    lock (Store.Gate) Store.Connection.Execute("DELETE FROM source_extract_budget");
                    return new();
                default:
                    throw new InvalidOperationException("unknown step");
            }
        }

        public Dictionary<string, object?> Snapshot(long at)
        {
            var gaveUp = Store.GaveUpSourceIds(1);
            object? source;
            List<Dictionary<string, object?>> jobs;
            lock (Store.Gate)
            {
                var row = Store.Connection.QuerySingleOrDefault("""
                    SELECT s.id,s.status,s.error,coalesce(b.failures,0) AS failures
                    FROM sources s LEFT JOIN source_extract_budget b ON b.source_id=s.id
                    """);
                source = row is null ? null : new Dictionary<string, object?>
                {
                    ["status"] = (string)row.status, ["error"] = (string?)row.error, ["extractFailures"] = (long)row.failures,
                    ["gaveUp"] = gaveUp.Contains((long)row.id),
                };
                jobs = Store.Connection.Query("SELECT * FROM ingest_jobs WHERE kind='extract' ORDER BY id").Select(r =>
                    new Dictionary<string, object?>
                    {
                        ["state"] = (string)r.state, ["attempts"] = (long)r.attempts, ["nextRetryAt"] = (long?)r.next_retry_at,
                        ["error"] = (string?)r.error, ["options"] = JsonSerializer.Deserialize<JsonElement>((string)r.options_json),
                    }).ToList();
            }
            var status = Store.IndexingStatus(1, at);
            return new()
            {
                ["source"] = source, ["extractJobs"] = jobs,
                ["indexing"] = new Dictionary<string, object?> { ["active"] = status.IsActive, ["sourceErrors"] = status.SourceErrors },
            };
        }

        public void Dispose() => Store.Dispose();
    }

    [Fact]
    public void FixtureCases()
    {
        var cases = Fixture().GetProperty("cases").EnumerateArray().ToArray();
        Assert.True(cases.Length >= 24);
        foreach (var item in cases)
        {
            string name = item.GetProperty("name").GetString()!;
            using var harness = new Harness();
            int index = 0;
            foreach (var row in item.GetProperty("steps").EnumerateArray())
            {
                var step = row.GetProperty("step");
                string label = $"{name} #{index++} {step.GetProperty("op").GetString()}@{step.GetProperty("at").GetInt64()}";
                var result = harness.Run(step);
                Assert.True(Canonical(row.GetProperty("result")) == Canonical(result), $"{label}: result {Canonical(result)}");
                var snapshot = harness.Snapshot(step.GetProperty("at").GetInt64());
                Assert.True(Canonical(row.GetProperty("expected")) == Canonical(snapshot),
                    $"{label}: expected {Canonical(row.GetProperty("expected"))} got {Canonical(snapshot)}");
            }
        }
    }

    // ---------------------------------------------------------------- end to end

    private sealed class MutableClock : IIngestLeaseClock
    {
        private long _now = 1_000;
        public long Now { get => Interlocked.Read(ref _now); set => Interlocked.Exchange(ref _now, value); }
        public Task WaitUntilAsync(long deadline, CancellationToken ct) => Task.Delay(Timeout.Infinite, ct);
    }

    private sealed class Rig : IDisposable
    {
        public Rig(Action<string> populate, AINotebook.Core.Extractors.ITextExtractor? web = null)
        {
            Notebook = Store.CreateNotebook("retry-cap").Id!.Value;
            Root = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "retry-cap-" + Guid.NewGuid().ToString("N"))).FullName;
            populate(Root);
            var fs = new NativeFolderFileSystem();
            var admission = new IngestionAdmission();
            var extractor = new BoundedDocumentExtractor();
            Func<long, Task<EmbeddingSelection?>> selected = _ => Task.FromResult<EmbeddingSelection?>(null);
            Runtime = new FolderIngestionRuntime(Store, new FolderScanner(Store, fs, UnicodeTables.LoadBundled(), Clock),
                new FolderExtractionWorker(Store, fs, LanguageDetector.Unavailable, Clock, selected,
                    (uri, type, rules, ct) => extractor.ExtractAsync(uri, type, rules, ct), web),
                new FolderIndexCoordinator(Store, admission, Clock, (_, _) => Task.FromResult<FolderEmbeddingSession?>(null), selected),
                new JobQueue(Store, Clock, admission), Clock, admission, new ReextractContractTests.QuietWatches(), identity: fs,
                selectedSelection: selected, embeddingAvailability: _ => Task.FromResult(EmbeddingAvailability.Ready))
            { AutoDispatch = false };
        }

        public NotebookStore Store { get; } = new(StorePath.InMemory, configuredEmbeddingModelKey: null);
        public MutableClock Clock { get; } = new();
        public FolderIngestionRuntime Runtime { get; }
        public long Notebook { get; }
        public string Root { get; }

        public async Task DrainAllAsync()
        {
            for (int i = 0; i < 50 && await Runtime.DrainOnceAsync(); i++) { }
        }

        /// <summary>Runs extraction until nothing is due, making every pending retry due first.</summary>
        public async Task ExhaustAsync()
        {
            for (int i = 0; i < 6; i++)
            {
                await DrainAllAsync();
                Clock.Now += 1_000;
                Store.RequeueRetryableJobs(Clock.Now);
            }
            await DrainAllAsync();
        }

        public long ExtractAttempts()
        {
            lock (Store.Gate)
                return Store.Connection.ExecuteScalar<long>("SELECT coalesce(sum(attempts),0) FROM ingest_jobs WHERE kind='extract'");
        }

        public void Dispose()
        {
            Store.Dispose();
            try { Directory.Delete(Root, true); } catch (IOException) { }
        }
    }

    [Fact]
    public async Task ThreeFailuresGiveUpAcrossRescansUntilContentChangesOrRetry()
    {
        using var rig = new Rig(root => File.WriteAllText(Path.Combine(root, "broken.docx"), "this is not a zip archive"));
        var folder = await rig.Runtime.AddFolderAsync(rig.Notebook, rig.Root);
        await rig.ExhaustAsync();
        long sourceId = rig.Store.Sources(rig.Notebook).Single().Id!.Value;
        Assert.Equal(3, rig.ExtractAttempts());
        Assert.Equal(new[] { sourceId }, rig.Store.GaveUpSourceIds(rig.Notebook).ToArray());
        var source = rig.Store.Source(sourceId)!;
        Assert.Equal(SourceStatus.Error, source.Status);
        Assert.Equal("corruptArchive", source.Error);
        var status = rig.Store.IndexingStatus(rig.Notebook, rig.Clock.Now);
        Assert.False(status.IsActive);
        Assert.Equal(1, status.SourceErrors);

        // Plain scans, Verify all and the periodic reconciliation never try it again.
        foreach (bool verifyAll in new[] { false, true, false })
        {
            await rig.Runtime.ScanNowAsync(folder.Id, verifyAll);
            await rig.ExhaustAsync();
        }
        await new FolderReconciler(rig.Store, rig.Clock, (_, _) => Task.CompletedTask).ReconcileAsync(rig.Clock.Now + 10_000);
        await rig.ExhaustAsync();
        Assert.Equal(3, rig.ExtractAttempts());
        status = rig.Store.IndexingStatus(rig.Notebook, rig.Clock.Now);
        Assert.False(status.IsActive);
        Assert.Equal(1, status.SourceErrors);

        // An explicit retry gives three more attempts.
        Assert.True(await rig.Runtime.RetryFailedSourceAsync(sourceId));
        await rig.ExhaustAsync();
        Assert.Equal(6, rig.ExtractAttempts());
        Assert.Contains(sourceId, rig.Store.GaveUpSourceIds(rig.Notebook));

        // New content resets the budget on the next scan.
        File.WriteAllText(Path.Combine(rig.Root, "broken.docx"), "still not a zip archive, but different bytes");
        File.SetLastWriteTimeUtc(Path.Combine(rig.Root, "broken.docx"), DateTime.UtcNow.AddMinutes(1));
        await rig.Runtime.ScanNowAsync(folder.Id, false);
        await rig.ExhaustAsync();
        Assert.Equal(9, rig.ExtractAttempts());

        // Retry all from the strip's filtered view.
        Assert.Equal(1, await rig.Runtime.RetryFailedSourcesAsync(rig.Notebook));
        Assert.Equal(SourceStatus.Pending, rig.Store.Source(sourceId)!.Status);
        Assert.True(rig.Store.IndexingStatus(rig.Notebook, rig.Clock.Now).IsActive);
    }

    /// <summary>
    /// A loose file follows the same rule: the folder worker re-reads it on the automatic retries, gives up after the third
    /// failure, and an explicit retry starts over.
    /// </summary>
    [Fact]
    public async Task LooseFileGivesUpAfterThreeAttemptsAndRetries()
    {
        using var rig = new Rig(root => File.WriteAllText(Path.Combine(root, "broken.docx"), "this is not a zip archive"));
        string file = Path.Combine(rig.Root, "broken.docx");
        var ingestion = new IngestionService(rig.Store, leaseClock: rig.Clock);
        await Assert.ThrowsAnyAsync<Exception>(() => ingestion.IngestFileAsync(new Uri(file), rig.Notebook));
        long sourceId = rig.Store.Sources(rig.Notebook).Single().Id!.Value;
        Assert.Null(rig.Store.Source(sourceId)!.FolderId);
        await rig.ExhaustAsync();
        Assert.Equal(3, rig.ExtractAttempts());
        Assert.Equal(new[] { sourceId }, rig.Store.GaveUpSourceIds(rig.Notebook).ToArray());
        Assert.Equal("corruptArchive", rig.Store.Source(sourceId)!.Error);
        var status = rig.Store.IndexingStatus(rig.Notebook, rig.Clock.Now);
        Assert.False(status.IsActive);
        Assert.Equal(1, status.SourceErrors);

        Assert.True(await rig.Runtime.RetryFailedSourceAsync(sourceId));
        await rig.ExhaustAsync();
        Assert.Equal(6, rig.ExtractAttempts());
        Assert.Equal(1, rig.Store.RetryFailedExtractions(rig.Notebook, rig.Clock.Now)); // Retry all covers loose files

        // A fixed file publishes on the next attempt and clears the budget.
        string fixedFile = Path.Combine(rig.Root, "fixed.md");
        File.WriteAllText(fixedFile, "now readable");
        lock (rig.Store.Gate)
            rig.Store.Connection.Execute("UPDATE sources SET raw_path=$fixedFile,type='markdown' WHERE id=$sourceId",
                new { fixedFile, sourceId });
        await rig.ExhaustAsync();
        Assert.Equal(SourceStatus.Ready, rig.Store.Source(sourceId)!.Status);
        lock (rig.Store.Gate)
            Assert.Equal(0L, rig.Store.Connection.ExecuteScalar<long>("SELECT count(*) FROM source_extract_budget"));
    }

    private sealed class FlakyWeb : AINotebook.Core.Extractors.ITextExtractor
    {
        private int _calls;
        public int Calls => Volatile.Read(ref _calls);
        public Task<AINotebook.Core.Extractors.ExtractedText> ExtractAsync(Uri url, SourceType kind) =>
            Interlocked.Increment(ref _calls) == 1
                ? throw new FolderIngestionException("unexpectedError")
                : Task.FromResult(new AINotebook.Core.Extractors.ExtractedText("page", "Fetched on the explicit retry."));
    }

    /// <summary>
    /// A loose web source is fetched only by an explicit user action (user decision 2026-10-11): a failed attempt is
    /// never retried automatically, and an explicit Retry fetches exactly once.
    /// </summary>
    [Fact]
    public async Task LooseWebSourceIsFetchedOnlyOnExplicitRetry()
    {
        Assert.False(ExtractionRetryBudget.BackgroundWebRetry);
        var web = new FlakyWeb();
        using var rig = new Rig(_ => { }, web);
        long sourceId = rig.Store.CreateSource(rig.Notebook, SourceType.Web, "example.org", uri: "https://example.org/", rawPath: null)
            .Id!.Value;
        // The foreground fetch failed: the job ends without an automatic retry.
        var fence = rig.Store.BeginExtraction(sourceId, rig.Clock.Now, "foreground");
        Assert.True(rig.Store.FailJob(fence, "unexpectedError", rig.Clock.Now));
        Assert.Null(rig.Store.Job(fence.JobId)!.NextRetryAt);
        await rig.ExhaustAsync();
        Assert.Equal(0, web.Calls);
        Assert.Equal(SourceStatus.Error, rig.Store.Source(sourceId)!.Status);

        // A queued automatic retry of a URL (e.g. a row from before this rule) is abandoned without a fetch.
        long legacy = rig.Store.EnqueueJob(new IngestJobDraft("extract", $"source:{sourceId}", null), rig.Clock.Now);
        await rig.ExhaustAsync();
        Assert.Equal(0, web.Calls);
        Assert.Equal(ExtractionRetryBudget.RetryUnavailable, rig.Store.Job(legacy)!.Error);

        // An explicit Retry fetches once (and fails); the next explicit Retry fetches once and publishes.
        Assert.True(await rig.Runtime.RetryFailedSourceAsync(sourceId));
        await rig.ExhaustAsync();
        Assert.Equal(1, web.Calls);
        Assert.Equal(SourceStatus.Error, rig.Store.Source(sourceId)!.Status);
        lock (rig.Store.Gate)
            Assert.Equal(2L, rig.Store.Connection.ExecuteScalar<long>("SELECT failures FROM source_extract_budget")); // each user attempt counts
        Assert.True(await rig.Runtime.RetryFailedSourceAsync(sourceId));
        await rig.ExhaustAsync();
        Assert.Equal(2, web.Calls);
        Assert.Equal(SourceStatus.Ready, rig.Store.Source(sourceId)!.Status);
        Assert.Equal("Fetched on the explicit retry.", string.Concat(rig.Store.Chunks(sourceId).Select(c => c.Text)));
    }

    /// <summary>A transient failure followed by a publication clears the counter.</summary>
    [Fact]
    public async Task TransientFailureThenSuccessClearsTheBudget()
    {
        using var rig = new Rig(root => File.WriteAllText(Path.Combine(root, "notes.md"), "hello"));
        await rig.Runtime.AddFolderAsync(rig.Notebook, rig.Root);
        Assert.True(await rig.Runtime.DrainOnceAsync()); // scan
        long sourceId = rig.Store.Sources(rig.Notebook).Single().Id!.Value;
        // Two failed attempts (e.g. the file was locked), recorded through the fenced queue.
        for (int i = 0; i < 2; i++)
        {
            string lease = Guid.NewGuid().ToString("N");
            rig.Clock.Now += 1_000;
            rig.Store.RequeueRetryableJobs(rig.Clock.Now);
            var job = rig.Store.ClaimJob(rig.Clock.Now, lease)!;
            Assert.True(rig.Store.FailJob(new JobFence(job.Id, lease), "unexpectedError", rig.Clock.Now));
        }
        lock (rig.Store.Gate)
            Assert.Equal(2L, rig.Store.Connection.ExecuteScalar<long>("SELECT failures FROM source_extract_budget"));
        rig.Clock.Now += 1_000;
        rig.Store.RequeueRetryableJobs(rig.Clock.Now);
        await rig.DrainAllAsync();
        Assert.Equal(SourceStatus.Ready, rig.Store.Source(sourceId)!.Status);
        lock (rig.Store.Gate)
            Assert.Equal(0L, rig.Store.Connection.ExecuteScalar<long>("SELECT count(*) FROM source_extract_budget"));
    }
}

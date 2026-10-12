using System.Net;
using System.Text;
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
/// Shared <c>ingestion-reextract-v1</c> fixture plus the end-to-end recovery of folder sources whose extraction
/// failed under an older extractor.
/// </summary>
public sealed class ReextractContractTests
{
    private static JsonElement Fixture()
    {
        var fixture = SharedFixtures.Json("contracts/ingestion-reextract-v1.json");
        Assert.Equal("ingestion-reextract", fixture.GetProperty("contract").GetString());
        Assert.Equal(1, fixture.GetProperty("version").GetInt32());
        return fixture;
    }

    private static long? Long(JsonElement e, string key) =>
        e.GetProperty(key).ValueKind == JsonValueKind.Number ? e.GetProperty(key).GetInt64() : null;

    private static string? Str(JsonElement e, string key) =>
        e.GetProperty(key).ValueKind == JsonValueKind.String ? e.GetProperty(key).GetString() : null;

    /// <summary>Compact JSON with sorted object keys (the fixture's canonical form).</summary>
    private static string Canonical(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.Object => "{" + string.Join(",", e.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal)
            .Select(p => JsonSerializer.Serialize(p.Name) + ":" + Canonical(p.Value))) + "}",
        JsonValueKind.Array => "[" + string.Join(",", e.EnumerateArray().Select(Canonical)) + "]",
        _ => e.GetRawText(),
    };

    [Fact]
    public void ConstantsMatchFixture()
    {
        var fixture = Fixture();
        Assert.Equal(ExtractorRevision.Current, fixture.GetProperty("extractorRevision").GetInt32());
        Assert.Equal(ExtractorRevision.OptionsKey, fixture.GetProperty("optionsKey").GetString());
        Assert.Equal(fixture.GetProperty("retryableCodes").EnumerateArray().Select(c => c.GetString()!).ToArray(),
            ExtractorRevision.RetryableCodes.ToArray());
        using var options = JsonDocument.Parse(ExtractorRevision.OptionsJson);
        Assert.Equal(ExtractorRevision.Current, options.RootElement.GetProperty(ExtractorRevision.OptionsKey).GetInt32());
    }

    [Fact]
    public void FixtureCases()
    {
        var fixture = Fixture();
        var seed = fixture.GetProperty("seed");
        var folder = seed.GetProperty("folder");
        var cases = fixture.GetProperty("cases").EnumerateArray().ToArray();
        Assert.True(cases.Length > 20);
        string created = SqliteDate.ToDb(DateTime.UnixEpoch);
        foreach (var item in cases)
        {
            string name = item.GetProperty("name").GetString()!;
            var input = item.GetProperty("input");
            var expected = item.GetProperty("expected");
            var source = input.GetProperty("source");
            long sourceId = source.GetProperty("id").GetInt64();
            using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
            var conn = store.Connection;
            conn.Execute("INSERT INTO notebooks(id,name,created_at,updated_at) VALUES($id,'reextract',$created,$created)",
                new { id = seed.GetProperty("notebookId").GetInt64(), created });
            string identity = Canonical(JsonDocument.Parse(JsonSerializer.Serialize(new
            {
                volumeId = folder.GetProperty("volumeId").GetString(),
                components = folder.GetProperty("components").EnumerateArray().Select(c => c.GetString()).ToArray(),
                rootFileId = folder.GetProperty("rootFileId").GetString(),
            })).RootElement);
            conn.Execute("""
                INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,
                    limits,watch_enabled,created_at) VALUES($id,$nb,$root,$identity,'Docs',$includes,$ignores,'{}',0,$created)
                """, new
            {
                id = folder.GetProperty("id").GetInt64(), nb = folder.GetProperty("notebookId").GetInt64(),
                root = folder.GetProperty("rootPath").GetString(), identity,
                includes = JsonSerializer.Serialize(FolderRules.Defaults.IncludeExts),
                ignores = JsonSerializer.Serialize(FolderRules.Defaults.IgnoreGlobs), created,
            });
            conn.Execute("""
                INSERT INTO sources(id,notebook_id,type,title,status,error,ingested_at,folder_id,rel_path,availability,
                    eligible,content_hash) VALUES($id,$nb,'text','a.docx',$status,$error,$created,$folder,$rel,$availability,
                    $eligible,$hash)
                """, new
            {
                id = sourceId, nb = Long(source, "notebookId"), status = Str(source, "status"), error = Str(source, "error"),
                created, folder = Long(source, "folderId"), rel = Str(source, "relPath"),
                availability = Str(source, "availability"), eligible = source.GetProperty("eligible").GetBoolean() ? 1 : 0,
                hash = Str(source, "contentHash"),
            });
            foreach (var revision in input.GetProperty("revisions").EnumerateArray())
                conn.Execute("""
                    INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,
                        chunker_version,created_at) VALUES($id,$source,$revision,$hash,$text,1,2,$created)
                    """, new
                {
                    id = Long(revision, "id"), source = Long(revision, "sourceId"), revision = Long(revision, "revision"),
                    hash = Str(revision, "contentHash"), text = Str(revision, "canonicalText"), created,
                });
            conn.Execute("UPDATE sources SET current_revision=$current,published_revision_id=$published WHERE id=$id",
                new { current = Long(source, "currentRevision"), published = Long(source, "publishedRevisionId"), id = sourceId });
            long maxSeeded = 0;
            foreach (var job in input.GetProperty("jobs").EnumerateArray())
            {
                maxSeeded = Math.Max(maxSeeded, job.GetProperty("id").GetInt64());
                conn.Execute("""
                    INSERT INTO ingest_jobs(id,kind,target,target_revision,attempts,next_retry_at,state,error,options_json)
                    VALUES($id,$kind,$target,$revision,$attempts,$retry,$state,$error,$options)
                    """, new
                {
                    id = Long(job, "id"), kind = Str(job, "kind"), target = Str(job, "target"),
                    revision = Long(job, "targetRevision"), attempts = Long(job, "attempts"), retry = Long(job, "nextRetryAt"),
                    state = Str(job, "state"), error = Str(job, "error"), options = Canonical(job.GetProperty("options")),
                });
            }
            var ingestion = new List<long>();
            var status = new List<long>();
            store.FolderIngestionChanged += id => { lock (ingestion) ingestion.Add(id); };
            store.IndexingStatusChanged += id => { lock (status) status.Add(id); };

            int count = store.RequeueUpgradedExtractions(input.GetProperty("now").GetInt64());

            Assert.True(expected.GetProperty("requeued").GetInt32() == count, name);
            long[] notified = expected.GetProperty("notified").EnumerateArray().Select(n => n.GetInt64()).ToArray();
            Assert.True(notified.SequenceEqual(ingestion), name + ": folderIngestionChanged");
            Assert.True(notified.SequenceEqual(status), name + ": indexingStatusChanged");
            var row = conn.QuerySingle("SELECT status,error FROM sources WHERE id=$id", new { id = sourceId });
            var expectedSource = expected.GetProperty("source");
            Assert.True(Str(expectedSource, "status") == (string)row.status, name + ": status");
            Assert.True(Str(expectedSource, "error") == (string?)row.error, name + ": error");
            var jobs = conn.Query("SELECT * FROM ingest_jobs WHERE id>$max ORDER BY id", new { max = maxSeeded }).ToList();
            var newJob = expected.GetProperty("newJob");
            if (newJob.ValueKind == JsonValueKind.Null)
            {
                Assert.True(jobs.Count == 0, name + ": no new job");
                continue;
            }
            Assert.True(jobs.Count == 1, name + ": one new job");
            var created1 = jobs[0];
            Assert.True(Str(newJob, "kind") == (string)created1.kind, name);
            Assert.True(Str(newJob, "target") == (string)created1.target, name);
            Assert.True(Long(newJob, "targetRevision") == (long?)created1.target_revision, name);
            Assert.True(Str(newJob, "state") == (string)created1.state, name);
            Assert.True(Long(newJob, "attempts") == (long)created1.attempts, name);
            Assert.True(Long(newJob, "nextRetryAt") == (long?)created1.next_retry_at, name);
            Assert.True(Str(newJob, "error") == (string?)created1.error, name);
            Assert.True(Canonical(newJob.GetProperty("options")) ==
                Canonical(JsonDocument.Parse((string)created1.options_json).RootElement), name + ": options");
        }
    }

    // ---------------------------------------------------------------- end to end

    /// <summary>A scan never fast-paths a source in <c>error</c>: a plain scan and Verify all re-extract unchanged bytes.</summary>
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ScanAndVerifyAllReextractErrorSourceWithUnchangedBytes(bool verifyAll)
    {
        using var rig = new Rig();
        var (folder, sourceId) = await rig.FailedUnderOldExtractorAsync(watch: true);
        var status = new List<long>();
        rig.Store.IndexingStatusChanged += id => { lock (status) status.Add(id); };
        await rig.Runtime.ScanNowAsync(folder.Id, verifyAll);
        Assert.True(await rig.Runtime.DrainOnceAsync());
        Assert.Equal(SourceStatus.Pending, rig.Store.Source(sourceId)!.Status);
        lock (status) Assert.Contains(rig.Notebook, status);
        await rig.DrainAllAsync();
        await rig.AssertRecoveredAsync(sourceId);
    }

    /// <summary>
    /// Runtime start requeues the old failure even for a folder that is not watched (no startup scan), raises live
    /// updates, and the publication queues embedding. A failure under the current revision is not requeued again.
    /// </summary>
    [Fact]
    public async Task StartRequeuesUpgradedFailureOnUnwatchedFolderAndEmbeds()
    {
        using var rig = new Rig();
        var (folder, sourceId) = await rig.FailedUnderOldExtractorAsync(watch: false);
        var ingestion = new List<long>();
        rig.Store.FolderIngestionChanged += id => { lock (ingestion) ingestion.Add(id); };
        await rig.Runtime.StartAsync();
        lock (ingestion) Assert.Contains(rig.Notebook, ingestion);
        Assert.Equal(SourceStatus.Pending, rig.Store.Source(sourceId)!.Status);
        var queued = rig.Store.Connection.Query("SELECT kind,options_json FROM ingest_jobs WHERE state='queued' ORDER BY id").ToList();
        Assert.Equal(["extract"], queued.Select(j => (string)j.kind).ToArray());
        Assert.Equal("""{"extractorRevision":2}""", (string)queued[0].options_json);
        var status = await rig.Runtime.IndexingStatusAsync(rig.Notebook);
        Assert.Equal((IndexingPhase.Extracting, 0, 1), (status.Phase, status.Done!.Value, status.Total!.Value));
        await rig.DrainAllAsync();
        await rig.AssertRecoveredAsync(sourceId);

        // The same failure under the current extractor stays failed on the next reconciliation.
        rig.Store.Connection.Execute("""
            UPDATE ingest_jobs SET state='failed',attempts=5,next_retry_at=NULL,error='corruptArchive'
            WHERE kind='extract' AND options_json='{"extractorRevision":2}';
            UPDATE sources SET status='error',error='corruptArchive' WHERE id=$sourceId;
            """, new { sourceId });
        Assert.Equal(0, rig.Store.RequeueUpgradedExtractions(2_000));
        Assert.Equal(1, (await rig.Runtime.IndexingStatusAsync(rig.Notebook)).SourceErrors);
        // Verify all remains the explicit retry.
        await rig.Runtime.ScanNowAsync(folder.Id, true);
        await rig.DrainAllAsync();
        Assert.Equal(SourceStatus.Ready, rig.Store.Source(sourceId)!.Status);
        await rig.Runtime.StopAsync();
    }

    // ---------------------------------------------------------------- rig

    /// <summary>In-memory store, one temp folder with one Markdown file (or the files <paramref name="populate"/>
    /// writes), a ready embedder, deterministic draining. Shared with <see cref="SpreadsheetUpgradeTests"/>.</summary>
    internal sealed class Rig : IDisposable
    {
        private readonly HttpClient _http;

        public Rig(Action<string>? populate = null)
        {
            Notebook = Store.CreateNotebook("reextract").Id!.Value;
            Root = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "reextract-" + Guid.NewGuid().ToString("N"))).FullName;
            if (populate is null) File.WriteAllText(Path.Combine(Root, "a.md"), "Upgraded extractors index files that failed before.\n");
            else populate(Root);
            _http = new HttpClient(new OllamaHandler());
            var session = new FolderEmbeddingSession(new ProviderConfig("local", ProviderType.Ollama, "Local", "http://localhost:11434",
                true, false, DateTime.UnixEpoch), "embed-a", null, null, "1", "1", _http);
            var fs = new NativeFolderFileSystem();
            var admission = new IngestionAdmission();
            var extractor = new BoundedDocumentExtractor();
            Func<long, Task<EmbeddingSelection?>> selected = _ => Task.FromResult<EmbeddingSelection?>(session.Selection);
            Runtime = new FolderIngestionRuntime(Store, new FolderScanner(Store, fs, UnicodeTables.LoadBundled(), Clock),
                new FolderExtractionWorker(Store, fs, LanguageDetector.Unavailable, Clock, selected,
                    (uri, type, rules, ct) => extractor.ExtractAsync(uri, type, rules, ct)),
                new FolderIndexCoordinator(Store, admission, Clock, (_, _) => Task.FromResult<FolderEmbeddingSession?>(session), selected),
                new JobQueue(Store, Clock, admission), Clock, admission, new QuietWatches(), identity: fs,
                selectedSelection: selected, embeddingAvailability: _ => Task.FromResult(EmbeddingAvailability.Ready))
            { AutoDispatch = false };
        }

        public NotebookStore Store { get; } = new(StorePath.InMemory, configuredEmbeddingModelKey: null);
        public FixedClock Clock { get; } = new();
        public FolderIngestionRuntime Runtime { get; }
        public long Notebook { get; }
        public string Root { get; }

        /// <summary>
        /// Adds the folder, runs only its first scan, then records the queued extraction as a terminal failure of an
        /// older extractor (never published).
        /// </summary>
        public async Task<(FolderSource Folder, long SourceId)> FailedUnderOldExtractorAsync(bool watch)
        {
            var folder = await Runtime.AddFolderAsync(Notebook, Root);
            if (!watch) await Runtime.SetWatchingAsync(folder.Id, false);
            Assert.True(await Runtime.DrainOnceAsync());
            long sourceId = Store.Sources(Notebook).Single().Id!.Value;
            Store.Connection.Execute("""
                UPDATE ingest_jobs SET state='failed',attempts=5,next_retry_at=NULL,error='corruptArchive'
                WHERE kind='extract' AND target=$target;
                UPDATE sources SET status='error',error='corruptArchive' WHERE id=$sourceId;
                """, new { target = $"source:{sourceId}", sourceId });
            return (folder, sourceId);
        }

        public async Task DrainAllAsync()
        {
            for (int i = 0; i < 200 && await Runtime.DrainOnceAsync(); i++) { }
        }

        public async Task AssertRecoveredAsync(long sourceId)
        {
            Assert.Equal(SourceStatus.Ready, Store.Source(sourceId)!.Status);
            Assert.NotNull(Store.Connection.ExecuteScalar<long?>("SELECT published_revision_id FROM sources WHERE id=$sourceId", new { sourceId }));
            Assert.NotNull(Store.ActiveGeneration(Notebook));
            var status = await Runtime.IndexingStatusAsync(Notebook);
            Assert.Equal((IndexingPhase.Ready, 0), (status.Phase, status.SourceErrors));
        }

        public void Dispose()
        {
            _http.Dispose();
            Store.Dispose();
            try { Directory.Delete(Root, true); } catch (IOException) { }
        }
    }

    internal sealed class FixedClock : IIngestLeaseClock
    {
        public long Now => 1_000;
        public Task WaitUntilAsync(long deadline, CancellationToken ct) => Task.Delay(Timeout.Infinite, ct);
    }

    internal sealed class QuietWatches : IFolderWatchFactory
    {
        public IFolderWatchHandle Create(FolderSource folder, Action<string> onEvent) => new Handle();
        private sealed class Handle : IFolderWatchHandle
        {
            public void Start() { }
            public void Dispose() { }
        }
    }

    /// <summary>Ollama <c>/api/embed</c>: [1, 0] per input.</summary>
    internal sealed class OllamaHandler : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(ct));
            int count = body.RootElement.GetProperty("input").GetArrayLength();
            string json = JsonSerializer.Serialize(new { embeddings = Enumerable.Range(0, count).Select(_ => new[] { 1.0, 0.0 }).ToArray() });
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
        }
    }
}

using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

public sealed class FolderPublicationTests
{
    private static readonly string[] PipelineOps = ["snapshot", "extract", "change-original", "observe", "expire", "claim", "publish"];

    [Fact]
    public void DescriptorUsesMetadataWithoutSummary()
    {
        var doc = new CanonicalDocument("# Body\nSecret prose", "Metadata", "markdown",
            Array.Empty<PageBoundary>(), Array.Empty<string>(), "utf-8");
        var descriptor = SourceDescriptor.Make(doc, "fallback.md", 32, "cs");
        Assert.Equal("Metadata", descriptor.Title); Assert.Equal("cs", descriptor.Lang);
        var json = JsonSerializer.SerializeToElement(descriptor, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
        Assert.Equal(new[] { "lang", "pageCount", "sheetCount", "sizeBytes", "title", "type", "version" },
            json.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal));
        Assert.DoesNotContain("Secret prose", json.GetRawText());
        // Title preference falls back to the Markdown heading, then the filename; lang stays an explicit null.
        Assert.Equal("Body", SourceDescriptor.Make(doc with { Title = " " }, "fallback.md", 32, null).Title);
        Assert.Equal("fallback", SourceDescriptor.Make(doc with { Title = null, Kind = "text" }, "fallback.md", 32, null).Title);
        Assert.Equal("""{"version":1,"title":"fallback","type":"text","pageCount":0,"sheetCount":0,"sizeBytes":32,"lang":null}""",
            SourceDescriptor.Make(doc with { Title = null, Kind = "text" }, "dir/fallback.md", 32, null).ToJson());
    }

    [Fact]
    public void ReclaimedJobRejectsOldCommitWithoutInsertingRows()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebookId = store.CreateNotebook("fencing").Id!.Value;
        long sourceId = store.CreateSource(notebookId, SourceType.Text, "document", null, null).Id!.Value;
        var original = store.CommitForegroundRevision(sourceId, new RevisionDraft("old-hash", "old", 1, 2),
            new[] { new RevisionChunkDraft("old", 1, null, 0, 3, null, false) }, 0, "seed");
        var stale = store.BeginExtraction(sourceId, 10, "old-owner");
        Assert.Equal(1, store.RecoverExpiredJobs(310));
        var recovered = store.Job(stale.JobId)!;
        Assert.Equal("queued", recovered.State);
        Assert.Equal(370, recovered.NextRetryAt);
        var replacement = store.ClaimJob(370, "new-owner", stale.JobId)!;
        Assert.Equal(2, replacement.Attempts);
        var current = new JobFence(stale.JobId, "new-owner");
        var next = new RevisionDraft("new-hash", "new", 1, 2);
        var chunks = new[] { new RevisionChunkDraft("new", 1, null, 0, 3, null, false) };
        Assert.Null(store.CommitExtraction(sourceId, next, chunks, stale, 371));
        Assert.False(store.FailJob(stale, "late-failure", 371));
        var kept = store.Source(sourceId)!;
        Assert.Equal(original.Id, kept.CurrentRevision);
        Assert.Equal(original.Id, kept.PublishedRevisionId);
        Assert.Equal(new[] { "old" }, store.Chunks(sourceId).Select(c => c.Text));
        Assert.Equal("running", store.Job(stale.JobId)!.State);
        Assert.Equal("new-owner", store.Job(stale.JobId)!.LeaseToken);
        lock (store.Gate)
        {
            Assert.Equal(1, store.Connection.ExecuteScalar<int>(
                "SELECT count(*) FROM source_revisions WHERE source_id=$id", new { id = sourceId }));
            Assert.Equal(1, store.Connection.ExecuteScalar<int>(
                "SELECT count(*) FROM source_chunks WHERE source_id=$id", new { id = sourceId }));
        }
        var published = store.CommitExtraction(sourceId, next, chunks, current, 372);
        Assert.NotNull(published);
        Assert.Equal(published.Id, store.Source(sourceId)!.PublishedRevisionId);
        Assert.Equal(new[] { "new" }, store.Chunks(sourceId).Select(c => c.Text));
        Assert.Null(store.CommitExtraction(sourceId, next, chunks, stale, 373));
        Assert.Equal("old", store.Revision(original.Id)!.Draft.CanonicalText);
        Assert.Equal("done", store.Job(stale.JobId)!.State);
        lock (store.Gate)
        {
            Assert.Equal(2, store.Connection.ExecuteScalar<int>(
                "SELECT count(*) FROM source_revisions WHERE source_id=$id", new { id = sourceId }));
            Assert.Equal(2, store.Connection.ExecuteScalar<int>(
                "SELECT count(*) FROM source_chunks WHERE source_id=$id", new { id = sourceId }));
        }
    }

    [Fact]
    public async Task AllPipelineFixtures()
    {
        var all = SharedFixtures.Json("contracts/ingestion-pipeline-v1.json");
        Assert.Equal("ingestion-pipeline", all.GetProperty("contract").GetString());
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in all.GetProperty("cases").EnumerateArray())
        {
            Assert.True(names.Add(Name(row)));
            switch (Op(row))
            {
                case "pipeline":
                    using (var harness = new PipelineHarness(row)) await harness.ReplayAsync();
                    break;
                case "descriptor": AssertDescriptor(row); break;
                case "chunk-language": AssertChunkLanguage(row); break;
                default: Assert.Fail("Unknown pipeline operation " + Op(row)); break;
            }
        }
        Assert.Equal(21, names.Count);
    }

    [Fact]
    public async Task MetadataAndEmbeddingRollback()
    {
        using (var harness = new PipelineHarness(Case("metadata-and-embed-atomic"))) await harness.ReplayAsync();

        // A fault after the page map, before metadata, rolls everything back too.
        using (var harness = new PipelineHarness(Case("revision-page-map-survives-refresh")))
        {
            var before = harness.State();
            harness.Store.PublicationFault = stage => { if (stage == "after-pages") throw new InvalidOperationException("injectedFailure"); };
            await harness.PrepareAsync();
            await Assert.ThrowsAsync<InvalidOperationException>(() => harness.PublishAsync(12));
            Assert.Equal(before, harness.State());
        }

        // Unknown dimensions queue one notebook bootstrap job; repeated publication coalesces it.
        using (var harness = new PipelineHarness(Case("publish-short"), selection: Selection() with { Dims = null }))
        {
            await harness.PrepareAsync();
            Assert.True((await harness.PublishAsync(12)).Accepted);
            var embed = harness.Jobs().Single(j => j.Draft.Kind == "embed");
            Assert.Equal("notebook:1", embed.Draft.Target);
            Assert.Null(embed.NextRetryAt);
            using var options = JsonDocument.Parse(embed.Draft.OptionsJson);
            Assert.True(options.RootElement.GetProperty("copyExisting").GetBoolean());
            Assert.Equal(JsonValueKind.Null, options.RootElement.GetProperty("selection").GetProperty("dims").ValueKind);
            Assert.DoesNotContain("apiKey", embed.Draft.OptionsJson, StringComparison.OrdinalIgnoreCase);
            lock (harness.Store.Gate) Assert.Equal(0, harness.Store.Connection.ExecuteScalar<int>("SELECT count(*) FROM index_generations"));
        }

        // No configured selection: lexical publication still succeeds and queues no embedding work.
        using (var harness = new PipelineHarness(Case("publish-short"), selection: null))
        {
            await harness.PrepareAsync();
            var result = await harness.PublishAsync(12);
            Assert.True(result.Accepted);
            Assert.DoesNotContain(harness.Jobs(), j => j.Draft.Kind == "embed");
            Assert.Equal(result.RevisionId, harness.Store.Source(101)!.PublishedRevisionId);
        }
    }

    [Fact]
    public async Task OriginalChangesDuringExtraction()
    {
        foreach (string name in new[] { "stat-changed", "hash-changed-same-stat", "new-observation-before-commit" })
            using (var harness = new PipelineHarness(Case(name))) await harness.ReplayAsync();

        // End to end through the real queue, native filesystem and bounded extractor.
        using var dir = new TempDir();
        string root = Directory.CreateDirectory(Path.Combine(dir.Path, "docs")).FullName;
        string file = Path.Combine(root, "a.md");
        await File.WriteAllTextAsync(file, "# Heading\nPrvní verze dokumentu.");
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        var fs = new NativeFolderFileSystem();
        long notebook = store.CreateNotebook("e2e").Id!.Value;
        var folder = store.CreateFolder(notebook, new FolderDraft(root, "Docs", ["md"], [], "{}", "cp1250", true), fs, 0);
        long scan = store.EnqueueJob(new IngestJobDraft("scan", $"folder:{folder.Id}", null), 1);
        store.ClaimJob(1, "scan", scan);
        await new FolderScanner(store, fs, UnicodeTables.LoadBundled(), new FixedClock(2)).ScanAsync(folder.Id, false, new JobFence(scan, "scan"), 1);
        var source = Assert.Single(store.SourcesIncludingShadow(notebook));
        bool mutate = true;
        var extractor = new BoundedDocumentExtractor();
        var worker = new FolderExtractionWorker(store, fs, LanguageDetector.Unavailable, new FixedClock(3), _ => Task.FromResult<EmbeddingSelection?>(null),
            async (uri, type, rules, ct) =>
            {
                var document = await extractor.ExtractAsync(uri, type, rules, ct);
                if (mutate) await File.AppendAllTextAsync(file, " Změna během extrakce.", ct);
                return document;
            });
        var queue = new JobQueue(store, new FixedClock(3), new IngestionAdmission());
        Assert.True(await queue.RunOneAsync("extract", 10, worker.ExecuteAsync));
        Assert.Null(store.Source(source.Id!.Value)!.PublishedRevisionId);
        Assert.Equal(SourceStatus.Pending, store.Source(source.Id!.Value)!.Status);
        mutate = false;
        Assert.True(await queue.RunOneAsync("extract", 10, worker.ExecuteAsync));
        var published = store.Source(source.Id!.Value)!;
        Assert.NotNull(published.PublishedRevisionId);
        Assert.Equal(SourceStatus.Ready, published.Status);
        Assert.Contains("Změna", Assert.Single(store.Chunks(published.Id!.Value)).Text);
        using var descriptor = JsonDocument.Parse(published.Descriptor!);
        Assert.Equal("Heading", descriptor.RootElement.GetProperty("title").GetString());
        Assert.Equal(JsonValueKind.Null, descriptor.RootElement.GetProperty("lang").ValueKind);
        Assert.Null(published.Lang);
        Assert.Null(published.LangCoverage);
        Assert.Equal(Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(file))).ToLowerInvariant(), published.ContentHash);
    }

    [Fact]
    public async Task StaleTokenChangesNothing()
    {
        foreach (string name in new[] { "expired-owner", "replaced-owner" })
            using (var harness = new PipelineHarness(Case(name))) await harness.ReplayAsync();

        using var stale = new PipelineHarness(Case("expired-owner"));
        var before = stale.State();
        Assert.False(stale.Store.RequestFreshExtraction(101, new JobFence(3001, "owner-a"), 310));
        Assert.False(stale.Store.RequestFreshExtraction(101, new JobFence(3001, "owner-x"), 11));
        Assert.Equal(before, stale.State());
    }

    [Fact]
    public async Task DocumentAndChunkDetection()
    {
        foreach (string name in new[] { "publish-short", "detector-unavailable", "inherit-short", "low-confidence-und",
            "background-never-inherits", "mixed-document", "und-document" })
            using (var harness = new PipelineHarness(Case(name))) await harness.ReplayAsync();
        var rows = SharedFixtures.Json("contracts/ingestion-pipeline-v1.json").GetProperty("cases").EnumerateArray()
            .Where(c => Op(c) == "chunk-language").ToArray();
        Assert.Equal(5, rows.Length);
        foreach (var row in rows) AssertChunkLanguage(row);
    }

    [Fact]
    public async Task RevisionPageMapSurvivesRefresh()
    {
        using var harness = new PipelineHarness(Case("revision-page-map-survives-refresh"));
        await harness.ReplayAsync();
        var revision = harness.Store.Source(101)!.PublishedRevisionId!.Value;
        Assert.Equal(new[] { (1, 0, 2), (2, 4, 4), (3, 6, 9) },
            harness.Store.RevisionPages(revision).Select(p => (p.Page, p.CharStart, p.CharEnd)));
        Assert.Equal(new[] { (1, 0, 3) }, harness.Store.RevisionPages(1001).Select(p => (p.Page, p.CharStart, p.CharEnd)));
        lock (harness.Store.Gate)
        {
            var error = Assert.ThrowsAny<Microsoft.Data.Sqlite.SqliteException>(() =>
                harness.Store.Connection.Execute("UPDATE revision_pages SET char_end=1 WHERE revision_id=1001"));
            Assert.Contains("immutable revision page", error.Message);
        }
    }

    [Fact]
    public async Task EmptyRevision()
    {
        using var harness = new PipelineHarness(Case("empty-revision"));
        await harness.ReplayAsync();
        var source = harness.Store.Source(101)!;
        Assert.Equal(SourceStatus.Ready, source.Status);
        Assert.Empty(harness.Store.Chunks(101));
        Assert.Equal("", harness.Store.Revision(source.PublishedRevisionId!.Value)!.Draft.CanonicalText);
        Assert.Equal("und", source.Lang);
    }

    private static void AssertDescriptor(JsonElement row)
    {
        var i = row.GetProperty("input");
        var d = i.GetProperty("document");
        var doc = new CanonicalDocument(d.GetProperty("text").GetString()!, Str(d, "title"), d.GetProperty("kind").GetString()!,
            Pages(d.GetProperty("pages")), d.GetProperty("sheetNames").EnumerateArray().Select(s => s.GetString()!).ToArray(), Str(d, "encoding"));
        var descriptor = SourceDescriptor.Make(doc, i.GetProperty("filename").GetString()!, i.GetProperty("sizeBytes").GetInt64(), Str(i, "lang"));
        using var json = JsonDocument.Parse(descriptor.ToJson());
        AssertJson(row.GetProperty("expected"), json.RootElement, Name(row));
    }

    private static void AssertChunkLanguage(JsonElement row)
    {
        var i = row.GetProperty("input");
        var language = ChunkLanguage.Resolve(Str(i, "label"), Str(i, "reason"), Str(i, "documentLabel"));
        AssertJson(row.GetProperty("expected"), JsonSerializer.SerializeToElement(new { lang = language.Lang, langInherited = language.LangInherited }), Name(row));
    }

    private static EmbeddingSelection Selection() => new("fixture", "fixture-endpoint-1", "fixture-model", null, 2, "l2", "1", "1", "2");

    private sealed class PipelineHarness : IDisposable
    {
        private readonly JsonElement _row;
        private readonly JsonElement _input;
        private readonly PipelineFS _fs;
        private readonly FixedClock _clock = new(0);
        private readonly Dictionary<long, long> _generations = new();
        private readonly FolderExtractionWorker _worker;
        private FolderExtractionWorker.Context? _context;
        private FolderFileSnapshot? _snapshot;
        private FolderExtractionDraft? _draft;
        private int _notifications;
        public NotebookStore Store { get; } = new(StorePath.InMemory, configuredEmbeddingModelKey: null);

        public PipelineHarness(JsonElement row, EmbeddingSelection? selection = null, bool overrideSelection = false)
            : this(row, selection, true, overrideSelection) { }

        public PipelineHarness(JsonElement row) : this(row, null, false, false) { }

        private PipelineHarness(JsonElement row, EmbeddingSelection? selection, bool custom, bool _)
        {
            _row = row;
            _input = row.GetProperty("input");
            var seed = _input.GetProperty("seed");
            var folder = _input.GetProperty("folder");
            Assert.Equal(1, Store.CreateNotebook("pipeline").Id);
            var identity = new FolderIdentity(folder.GetProperty("volumeId").GetString()!,
                folder.GetProperty("components").EnumerateArray().Select(c => c.GetString()!).ToArray(), folder.GetProperty("rootFileId").GetString()!);
            Assert.Equal(1, Store.CreateFolder(1, new FolderDraft(folder.GetProperty("rootPath").GetString()!, "Docs",
                FolderRules.Defaults.IncludeExts, FolderRules.Defaults.IgnoreGlobs, "{}", "cp1250", true), new FixedIdentity(identity), 0).Id);
            var s = seed.GetProperty("source");
            lock (Store.Gate)
            {
                var c = Store.Connection;
                using var tx = c.BeginTransaction();
                c.Execute("UPDATE folder_sources SET scan_generation=$generation,scan_state=$state WHERE id=1",
                    new { generation = folder.GetProperty("scanGeneration").GetInt64(), state = folder.GetProperty("scanState").GetString() }, tx);
                c.Execute("""
                    INSERT INTO sources(id,notebook_id,type,title,status,error,ingested_at,folder_id,rel_path,mtime,size_bytes,
                        availability,eligible,content_hash,encoding,lang,lang_coverage,descriptor)
                    VALUES($id,$notebook,$type,'Old title',$status,$error,'2026-01-01 00:00:00.000',$folder,$path,$mtime,$size,
                        $availability,$eligible,$hash,$encoding,$lang,$coverage,$descriptor)
                    """, new
                {
                    id = s.GetProperty("id").GetInt64(), notebook = s.GetProperty("notebookId").GetInt64(),
                    type = s.GetProperty("descriptor").GetProperty("type").GetString(), status = Str(s, "status"), error = Str(s, "error"),
                    folder = s.GetProperty("folderId").GetInt64(), path = Str(s, "relPath"), mtime = s.GetProperty("mtimeNs").GetInt64(),
                    size = s.GetProperty("sizeBytes").GetInt64(), availability = Str(s, "availability"), eligible = s.GetProperty("eligible").GetBoolean(),
                    hash = Str(s, "contentHash"), encoding = Str(s, "encoding"), lang = Str(s, "lang"),
                    coverage = s.GetProperty("langCoverage").GetRawText(), descriptor = s.GetProperty("descriptor").GetRawText()
                }, tx);
                foreach (var r in seed.GetProperty("revisions").EnumerateArray())
                    c.Execute("""
                        INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                        VALUES($id,$source,$revision,$hash,$text,$format,$chunker,'2026-01-01 00:00:00.000')
                        """, new
                    {
                        id = r.GetProperty("id").GetInt64(), source = r.GetProperty("sourceId").GetInt64(), revision = r.GetProperty("revision").GetInt64(),
                        hash = Str(r, "contentHash"), text = Str(r, "canonicalText"), format = r.GetProperty("textFormatVersion").GetInt64(),
                        chunker = r.GetProperty("chunkerVersion").GetInt64()
                    }, tx);
                foreach (var ch in seed.GetProperty("chunks").EnumerateArray())
                    c.Execute("""
                        INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count,page_hint,char_start,char_end,lang,lang_inherited)
                        VALUES($id,$source,$revision,$ord,$text,$tokens,$page,$start,$end,$lang,$inherited)
                        """, new
                    {
                        id = ch.GetProperty("id").GetInt64(), source = ch.GetProperty("sourceId").GetInt64(), revision = ch.GetProperty("revisionId").GetInt64(),
                        ord = ch.GetProperty("ordinal").GetInt64(), text = Str(ch, "text"), tokens = ch.GetProperty("tokens").GetInt64(),
                        page = Long(ch, "pageFrom"), start = ch.GetProperty("start").GetInt64(), end = ch.GetProperty("end").GetInt64(),
                        lang = Str(ch, "lang"), inherited = ch.GetProperty("langInherited").GetBoolean()
                    }, tx);
                foreach (var p in seed.GetProperty("revisionPages").EnumerateArray())
                    c.Execute("INSERT INTO revision_pages(revision_id,page,char_start,char_end) VALUES($r,$p,$s,$e)", new
                    {
                        r = p.GetProperty("revisionId").GetInt64(), p = p.GetProperty("page").GetInt64(),
                        s = p.GetProperty("start").GetInt64(), e = p.GetProperty("end").GetInt64()
                    }, tx);
                c.Execute("UPDATE sources SET current_revision=$current,published_revision_id=$published WHERE id=$id", new
                {
                    id = s.GetProperty("id").GetInt64(), current = Long(s, "currentRevision"), published = Long(s, "publishedRevisionId")
                }, tx);
                foreach (var j in seed.GetProperty("jobs").EnumerateArray()) InsertJob(c, tx, j);
                Assert.Equal(0, seed.GetProperty("generations").GetArrayLength());
                tx.Commit();
            }
            Store.FolderIngestionChanged += _ => _notifications++;
            var snapshot = _input.GetProperty("snapshot");
            _fs = new PipelineFS(identity, Bytes(snapshot.GetProperty("bytes")), Stamp(snapshot.GetProperty("stamp")), snapshot.GetProperty("sha256").GetString()!);
            var detector = _input.GetProperty("detector").GetString() == "available"
                ? LanguageDetector.CreateForTests(Encoding.UTF8.GetBytes(_input.GetProperty("model").GetRawText() + "\n"), UnicodeTables.LoadBundled())
                : LanguageDetector.Unavailable;
            var fixtureSelection = _input.GetProperty("embeddingSelection").ValueKind == JsonValueKind.Null ? null
                : JsonSerializer.Deserialize<EmbeddingSelection>(_input.GetProperty("embeddingSelection").GetRawText(), Camel);
            var chosen = custom ? selection : fixtureSelection;
            var document = _input.GetProperty("extractor").GetProperty("document");
            Assert.Equal("injected", _input.GetProperty("extractor").GetProperty("kind").GetString());
            Assert.Equal(2048, _input.GetProperty("chunker").GetProperty("window").GetInt32());
            Assert.Equal(256, _input.GetProperty("chunker").GetProperty("overlap").GetInt32());
            _worker = new FolderExtractionWorker(Store, _fs, detector, _clock, _ => Task.FromResult(chosen),
                (uri, type, rules, ct) =>
                {
                    Assert.True(uri.IsFile);
                    Assert.Equal(Str(document, "kind") == "pdf" ? SourceType.Pdf : SourceType.Text, type);
                    return Task.FromResult(new CanonicalDocument(document.GetProperty("text").GetString()!, Str(document, "title"),
                        document.GetProperty("kind").GetString()!, Pages(document.GetProperty("pages")),
                        document.GetProperty("sheetNames").EnumerateArray().Select(x => x.GetString()!).ToArray(), Str(document, "encoding")));
                });
            var request = _input.GetProperty("request");
            var fence = request.GetProperty("fence");
            _context = _worker.Load(Store.Job(fence.GetProperty("jobId").GetInt64())!,
                new JobFence(fence.GetProperty("jobId").GetInt64(), fence.GetProperty("leaseToken").GetString()!));
            Assert.NotNull(_context);
            Assert.Equal(request.GetProperty("expectedCurrentRevision").GetInt64(), _context!.Job.Draft.TargetRevision);
            Assert.Equal(Stamp(request.GetProperty("observation")) with { Identity = "" }, _context.Request.Stamp);
            AssertJson(seed, StateElement(seed), Name(row) + " seed");
        }

        public void Dispose()
        {
            _snapshot?.Dispose();
            Store.Dispose();
        }

        public async Task PrepareAsync()
        {
            _clock.Now = 10;
            _snapshot = _worker.Snapshot(_context!, CancellationToken.None);
            _clock.Now = 11;
            _draft = await _worker.ExtractAsync(_context!, _snapshot, CancellationToken.None);
        }

        public Task<FolderPublicationResult> PublishAsync(long at)
        {
            _clock.Now = at;
            return _worker.PublishAsync(_context!, _snapshot!, _draft!, CancellationToken.None);
        }

        public IReadOnlyList<IngestJob> Jobs()
        {
            lock (Store.Gate) return Store.Connection.Query<long>("SELECT id FROM ingest_jobs ORDER BY id").Select(id => Store.Job(id)!).ToArray();
        }

        public async Task ReplayAsync()
        {
            int index = 0;
            foreach (var e in _row.GetProperty("input").GetProperty("events").EnumerateArray())
            {
                string op = Op(e);
                Assert.Contains(op, PipelineOps);
                long at = e.GetProperty("at").GetInt64();
                _clock.Now = at;
                JsonElement result;
                switch (op)
                {
                    case "snapshot":
                        _snapshot = _worker.Snapshot(_context!, CancellationToken.None);
                        Assert.Equal(_fs.Bytes, await File.ReadAllBytesAsync(_snapshot.Path));
                        result = JsonSerializer.SerializeToElement(new { sha256 = _snapshot.Hash, stamp = StampJson(_snapshot.Stamp) });
                        break;
                    case "extract":
                        _draft = await _worker.ExtractAsync(_context!, _snapshot!, CancellationToken.None);
                        result = DraftJson(_draft);
                        break;
                    case "change-original":
                        var file = e.GetProperty("file");
                        _fs.Replace(Bytes(file.GetProperty("bytes")), Stamp(file.GetProperty("stamp")), file.GetProperty("sha256").GetString()!);
                        result = JsonSerializer.SerializeToElement<object?>(null);
                        break;
                    case "observe":
                        Assert.Equal("committed-scan-observation", Str(e, "transaction"));
                        lock (Store.Gate)
                        {
                            var c = Store.Connection;
                            using var tx = c.BeginTransaction();
                            c.Execute("UPDATE sources SET mtime=$mtime,status='pending',error=NULL WHERE id=$id",
                                new { id = e.GetProperty("sourceId").GetInt64(), mtime = e.GetProperty("observation").GetProperty("mtimeNs").GetInt64() }, tx);
                            c.Execute("UPDATE ingest_jobs SET state='cancelled',lease_until=NULL,lease_token=NULL,next_retry_at=NULL WHERE id=$id",
                                new { id = e.GetProperty("cancelJobId").GetInt64() }, tx);
                            InsertJob(c, tx, e.GetProperty("replacementJob"));
                            tx.Commit();
                        }
                        Store.NotifyFolderIngestionChanged(1);
                        result = JsonSerializer.SerializeToElement(new { extractJobId = e.GetProperty("replacementJob").GetProperty("id").GetInt64() });
                        break;
                    case "expire":
                        result = JsonSerializer.SerializeToElement(new { recovered = Store.RecoverExpiredJobs(at) });
                        break;
                    case "claim":
                        var claimed = Store.ClaimJob(at, Str(e, "leaseToken")!, e.GetProperty("jobId").GetInt64());
                        result = JsonSerializer.SerializeToElement(new { claimedJobId = claimed?.Id });
                        break;
                    case "publish":
                        var fence = e.GetProperty("fence");
                        Assert.Equal(_context!.Fence, new JobFence(fence.GetProperty("jobId").GetInt64(), fence.GetProperty("leaseToken").GetString()!));
                        if (Str(e, "fault") is string fault)
                            Store.PublicationFault = stage => { if (stage == fault) throw new InvalidOperationException("injectedFailure"); };
                        FolderPublicationResult published;
                        try { published = await PublishAsync(at); }
                        catch (InvalidOperationException error) when (error.Message == "injectedFailure")
                        {
                            published = new FolderPublicationResult(false, null, "injectedFailure");
                        }
                        result = JsonSerializer.SerializeToElement(new { accepted = published.Accepted, revisionId = published.RevisionId, error = published.Error });
                        break;
                    default:
                        throw new InvalidOperationException("Unknown pipeline operation " + op);
                }
                var expected = e.GetProperty("expected");
                AssertJson(expected.GetProperty("result"), result, $"{Name(_row)} event {index} result");
                AssertJson(expected.GetProperty("state"), StateElement(expected.GetProperty("state")), $"{Name(_row)} event {index} state");
                index++;
            }
            AssertJson(_row.GetProperty("expected").GetProperty("state"), StateElement(_row.GetProperty("expected").GetProperty("state")), Name(_row) + " final");
        }

        public string State() => StateElement(null).GetRawText();

        private JsonElement StateElement(JsonElement? expected)
        {
            lock (Store.Gate)
            {
                var c = Store.Connection;
                if (expected is JsonElement e)
                {
                    var free = new Queue<long>(e.GetProperty("generations").EnumerateArray().Select(g => g.GetProperty("id").GetInt64())
                        .Where(id => !_generations.ContainsValue(id)).Order());
                    foreach (long id in c.Query<long>("SELECT id FROM index_generations ORDER BY id"))
                        if (!_generations.ContainsKey(id) && free.Count > 0) _generations[id] = free.Dequeue();
                }
                long Gen(long id) => _generations.TryGetValue(id, out long f) ? f : -id;
                string Target(string target) => target.StartsWith("generation:", StringComparison.Ordinal)
                    ? "generation:" + Gen(long.Parse(target["generation:".Length..])) : target;
                var pages = c.Query("SELECT * FROM revision_pages ORDER BY revision_id,page").Select(p => new
                {
                    revisionId = (long)p.revision_id, page = (long)p.page, start = (long)p.char_start, end = (long)p.char_end
                }).ToArray();
                var s = c.QuerySingle("SELECT * FROM sources WHERE id=101");
                JsonElement? coverage = s.lang_coverage is null ? null : JsonDocument.Parse((string)s.lang_coverage).RootElement.Clone();
                var state = new
                {
                    source = new
                    {
                        availability = (string)s.availability, contentHash = (string?)s.content_hash, currentRevision = (long?)s.current_revision,
                        descriptor = s.descriptor is null ? (JsonElement?)null : JsonDocument.Parse((string)s.descriptor).RootElement.Clone(),
                        eligible = (long)s.eligible != 0, encoding = (string?)s.encoding, error = (string?)s.error, folderId = (long?)s.folder_id,
                        id = (long)s.id, lang = (string?)s.lang, langCoverage = coverage,
                        langCoverageBp = coverage is JsonElement value ? value.GetProperty("langCoverageBp").GetInt64() : (long?)null,
                        mtimeNs = (long?)s.mtime, notebookId = (long)s.notebook_id, publishedRevisionId = (long?)s.published_revision_id,
                        relPath = (string?)s.rel_path, sizeBytes = (long?)s.size_bytes, status = (string)s.status
                    },
                    revisions = c.Query("SELECT * FROM source_revisions ORDER BY id").Select(r => new
                    {
                        canonicalText = (string)r.canonical_text, chunkerVersion = (long)r.chunker_version, contentHash = (string)r.content_hash,
                        id = (long)r.id, revision = (long)r.revision, sourceId = (long)r.source_id, textFormatVersion = (long)r.text_format_version
                    }).ToArray(),
                    chunks = c.Query("SELECT * FROM source_chunks ORDER BY id").Select(ch =>
                    {
                        long start = (long)ch.char_start, end = (long)ch.char_end;
                        var hits = pages.Where(p => p.revisionId == (long)ch.revision_id && p.start < p.end && start < p.end && p.start < end)
                            .Select(p => p.page).ToArray();
                        return new
                        {
                            end, id = (long)ch.id, lang = (string?)ch.lang, langInherited = (long)ch.lang_inherited != 0, ordinal = (long)ch.ord,
                            pageFrom = hits.Length == 0 ? (long?)null : hits[0], pageTo = hits.Length == 0 ? (long?)null : hits[^1],
                            revisionId = (long)ch.revision_id, sourceId = (long)ch.source_id, start, text = (string)ch.text, tokens = (long)ch.token_count
                        };
                    }).ToArray(),
                    revisionPages = pages,
                    jobs = c.Query("SELECT * FROM ingest_jobs ORDER BY id").Select(j => new
                    {
                        attempts = (long)j.attempts, error = (string?)j.error, id = (long)j.id, kind = (string)j.kind,
                        leaseToken = (string?)j.lease_token, leaseUntil = (long?)j.lease_until, nextRetryAt = (long?)j.next_retry_at,
                        options = JsonDocument.Parse((string)j.options_json).RootElement.Clone(), state = (string)j.state,
                        target = Target((string)j.target), targetRevision = (long?)j.target_revision
                    }).ToArray(),
                    generations = c.Query("SELECT id FROM index_generations ORDER BY id").Select(row => GenerationJson(Store.Generation((long)row.id)!, Gen)).ToArray(),
                    manifests = c.Query("SELECT * FROM index_generation_manifest ORDER BY generation_id,source_id").Select(m => new
                    {
                        generationId = Gen((long)m.generation_id), reason = (string?)m.reason, revisionId = (long)m.revision_id,
                        sourceId = (long)m.source_id, state = (string)m.state
                    }).ToArray(),
                    notificationCount = _notifications
                };
                return JsonSerializer.SerializeToElement(state);
            }
        }

        private static object GenerationJson(IndexGeneration g, Func<long, long> map) => new
        {
            id = map(g.Id), notebookId = g.NotebookId, state = g.State,
            identity = new
            {
                chunkerVersion = g.Identity.ChunkerVersion, dims = g.Identity.Dims, docFormatVersion = g.Identity.DocFormatVersion,
                endpointRevision = g.Identity.EndpointRevision, model = g.Identity.Model, modelDigest = g.Identity.ModelDigest,
                normalization = g.Identity.Normalization, providerId = g.Identity.ProviderId, queryFormatVersion = g.Identity.QueryFormatVersion
            }
        };

        private static JsonElement DraftJson(FolderExtractionDraft draft)
        {
            var pages = draft.Metadata.Pages;
            JsonElement? coverage = draft.Metadata.CoverageJSON is null ? null : JsonDocument.Parse(draft.Metadata.CoverageJSON).RootElement.Clone();
            return JsonSerializer.SerializeToElement(new
            {
                canonicalText = draft.Revision.CanonicalText, chunkerVersion = draft.Revision.ChunkerVersion, contentHash = draft.Revision.ContentHash,
                textFormatVersion = draft.Revision.TextFormatVersion,
                chunks = draft.Chunks.Select((chunk, i) =>
                {
                    var hits = pages.Where(p => p.Start < p.End && chunk.CharStart < p.End && p.Start < chunk.CharEnd).Select(p => p.Page).ToArray();
                    var detection = draft.Detections[i];
                    return new
                    {
                        detection = detection is null ? null : new { label = detection.Label, reason = detection.Reason },
                        end = chunk.CharEnd, lang = chunk.Lang, langInherited = chunk.LangInherited,
                        pageFrom = hits.Length == 0 ? (int?)null : hits[0], pageTo = hits.Length == 0 ? (int?)null : hits[^1],
                        start = chunk.CharStart, text = chunk.Text, tokens = chunk.TokenCount
                    };
                }).ToArray(),
                documentDetection = draft.Document is null ? null : new
                {
                    label = draft.Document.Label, langCoverageBp = draft.Document.LangCoverageBp, reason = draft.Document.Reason,
                    sampledLetters = draft.Document.SampledLetters, sharesBp = draft.Document.SharesBp, unknownShareBp = draft.Document.UnknownShareBp
                },
                metadata = new
                {
                    descriptor = JsonDocument.Parse(draft.Metadata.DescriptorJSON).RootElement.Clone(), encoding = draft.Metadata.Encoding,
                    lang = draft.Metadata.Lang, langCoverage = coverage,
                    langCoverageBp = coverage is JsonElement value ? value.GetProperty("langCoverageBp").GetInt64() : (long?)null
                },
                pages = pages.Select(p => new { page = p.Page, start = p.Start, end = p.End }).ToArray()
            });
        }

        private static void InsertJob(System.Data.IDbConnection c, System.Data.IDbTransaction tx, JsonElement j) => c.Execute("""
            INSERT INTO ingest_jobs(id,kind,target,target_revision,attempts,next_retry_at,state,lease_until,lease_token,error,options_json)
            VALUES($id,$kind,$target,$revision,$attempts,$retry,$state,$until,$token,$error,$options)
            """, new
        {
            id = j.GetProperty("id").GetInt64(), kind = Str(j, "kind"), target = Str(j, "target"), revision = Long(j, "targetRevision"),
            attempts = j.GetProperty("attempts").GetInt64(), retry = Long(j, "nextRetryAt"), state = Str(j, "state"),
            until = Long(j, "leaseUntil"), token = Str(j, "leaseToken"), error = Str(j, "error"), options = j.GetProperty("options").GetRawText()
        }, tx);
    }

    /// <summary>One scripted original file. Snapshots copy into a private temp file; Hash reports the current original.</summary>
    private sealed class PipelineFS(FolderIdentity identity, byte[] bytes, FileStamp stamp, string sha) : IFolderFileSystem
    {
        public byte[] Bytes { get; private set; } = bytes;
        private FileStamp _stamp = stamp;
        private string _sha = sha;

        public void Replace(byte[] bytes, FileStamp stamp, string sha) { Bytes = bytes; _stamp = stamp; _sha = sha; }
        public FolderIdentity Resolve(string rootPath) => identity;
        public bool CaseSensitive(FolderSource root) => true;
        public IReadOnlyList<FolderEntry> List(FolderSource root, string directory) => throw new InvalidOperationException();
        public FileStamp Stat(FolderSource root, string relativePath) => _stamp;
        public FolderRead Hash(FolderSource root, string relativePath, long maxBytes) => new([], _stamp, _sha);
        public FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes)
        {
            string path = Path.Combine(Path.GetTempPath(), "wp6-snapshot-" + Guid.NewGuid().ToString("N") + Path.GetExtension(relativePath));
            File.WriteAllBytes(path, Bytes);
            Assert.Equal(_sha, Convert.ToHexString(SHA256.HashData(Bytes)).ToLowerInvariant());
            return new FolderFileSnapshot(path, _stamp, _sha);
        }
    }

    private sealed class FixedClock(long now) : IIngestLeaseClock
    {
        public long Now { get; set; } = now;
        public Task WaitUntilAsync(long deadline, CancellationToken ct) =>
            deadline <= Now ? Task.CompletedTask : Task.Delay(Timeout.Infinite, ct);
    }

    private sealed class FixedIdentity(FolderIdentity identity) : IFolderPathIdentity
    {
        public FolderIdentity Resolve(string rootPath) => identity;
    }

    private sealed class TempDir : IDisposable
    {
        public string Path { get; } = Directory.CreateDirectory(System.IO.Path.Combine(System.IO.Path.GetTempPath(),
            "wp6-publication-" + Guid.NewGuid().ToString("N"))).FullName;
        public void Dispose()
        {
            try { Directory.Delete(Path, true); } catch (IOException) { }
        }
    }

    private static readonly JsonSerializerOptions Camel = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private static JsonElement Case(string name) => SharedFixtures.Json("contracts/ingestion-pipeline-v1.json").GetProperty("cases")
        .EnumerateArray().Single(c => Name(c) == name);
    private static string Name(JsonElement row) => row.GetProperty("name").GetString()!;
    private static string Op(JsonElement row) => row.GetProperty("operation").GetString()!;
    private static string? Str(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    private static long? Long(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : null;
    private static byte[] Bytes(JsonElement e) => e.EnumerateArray().Select(b => (byte)b.GetInt32()).ToArray();
    private static FileStamp Stamp(JsonElement e) =>
        new(e.GetProperty("identity").GetString()!, e.GetProperty("mtimeNs").GetInt64(), e.GetProperty("sizeBytes").GetInt64());
    private static object StampJson(FileStamp s) => new { identity = s.Identity, mtimeNs = s.MtimeNs, sizeBytes = s.SizeBytes };
    private static PageBoundary[] Pages(JsonElement e) => e.EnumerateArray()
        .Select(p => new PageBoundary(p.GetProperty("page").GetInt32(), p.GetProperty("start").GetInt32(), p.GetProperty("end").GetInt32())).ToArray();

    private static void AssertJson(JsonElement expected, JsonElement actual, string path)
    {
        if (expected.ValueKind == JsonValueKind.Number)
        {
            Assert.True(actual.ValueKind == JsonValueKind.Number && expected.GetInt64() == actual.GetInt64(), $"{path}: expected {expected} got {actual}");
            return;
        }
        Assert.True(expected.ValueKind == actual.ValueKind, $"{path}: expected {expected} got {actual}");
        switch (expected.ValueKind)
        {
            case JsonValueKind.Object:
                var keys = expected.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal).ToArray();
                Assert.True(keys.SequenceEqual(actual.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal)),
                    $"{path}: keys expected [{string.Join(",", keys)}] got {actual}");
                foreach (string key in keys) AssertJson(expected.GetProperty(key), actual.GetProperty(key), path + "." + key);
                break;
            case JsonValueKind.Array:
                Assert.True(expected.GetArrayLength() == actual.GetArrayLength(), $"{path}: expected {expected} got {actual}");
                int index = 0;
                foreach (var (e, a) in expected.EnumerateArray().Zip(actual.EnumerateArray()))
                    AssertJson(e, a, $"{path}[{index++}]");
                break;
            case JsonValueKind.String:
                Assert.True(expected.GetString() == actual.GetString(), $"{path}: expected {expected} got {actual}");
                break;
        }
    }
}

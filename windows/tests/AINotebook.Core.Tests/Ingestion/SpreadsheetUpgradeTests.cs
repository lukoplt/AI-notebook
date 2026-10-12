using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>
/// <c>ingestion-reextract-v2</c> (contract <c>ingestion-reextract-v1</c> §7): throttled re-extraction of ready folder
/// spreadsheets published under an older spreadsheet canonical text, plus the end-to-end upgrade to
/// <c>ingestion-xlsx-v2</c> (same cases as macOS SpreadsheetUpgradeTests).
/// </summary>
public sealed class SpreadsheetUpgradeTests
{
    private static JsonElement Fixture()
    {
        var fixture = SharedFixtures.Json("contracts/ingestion-reextract-v2.json");
        Assert.Equal("ingestion-reextract", fixture.GetProperty("contract").GetString());
        Assert.Equal(2, fixture.GetProperty("version").GetInt32());
        return fixture;
    }

    private static long? Long(JsonElement e, string key) =>
        e.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Number ? value.GetInt64() : null;

    private static string? Str(JsonElement e, string key) =>
        e.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

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
        Assert.Equal(ExtractorRevision.SpreadsheetTextVersion, fixture.GetProperty("spreadsheetTextVersion").GetInt32());
        Assert.Equal(ExtractorRevision.SpreadsheetOptionsKey, fixture.GetProperty("spreadsheetOptionsKey").GetString());
        Assert.Equal(ExtractorRevision.SpreadsheetBatchSize, fixture.GetProperty("batchSize").GetInt32());
        Assert.Equal("""{"spreadsheetTextVersion":2}""", ExtractorRevision.SpreadsheetOptionsJson);
    }

    [Fact]
    public void FixtureCases()
    {
        var fixture = Fixture();
        var seed = fixture.GetProperty("seed");
        var cases = fixture.GetProperty("cases").EnumerateArray().ToArray();
        Assert.True(cases.Length > 20);
        string created = SqliteDate.ToDb(DateTime.UnixEpoch);
        foreach (var item in cases)
        {
            string name = item.GetProperty("name").GetString()!;
            var input = item.GetProperty("input");
            var expected = item.GetProperty("expected");
            using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
            var conn = store.Connection;
            foreach (var notebook in seed.GetProperty("notebooks").EnumerateArray())
                conn.Execute("INSERT INTO notebooks(id,name,created_at,updated_at) VALUES($id,'upgrade',$created,$created)",
                    new { id = notebook.GetInt64(), created });
            foreach (var folder in seed.GetProperty("folders").EnumerateArray())
            {
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
            }
            var sources = input.GetProperty("sources").EnumerateArray().ToArray();
            foreach (var source in sources)
                conn.Execute("""
                    INSERT INTO sources(id,notebook_id,type,title,status,error,ingested_at,folder_id,rel_path,availability,
                        eligible,content_hash) VALUES($id,$nb,$type,'s',$status,$error,$created,$folder,$rel,$availability,
                        $eligible,$hash)
                    """, new
                {
                    id = Long(source, "id"), nb = Long(source, "notebookId"), type = Str(source, "type"),
                    status = Str(source, "status"), error = Str(source, "error"), created, folder = Long(source, "folderId"),
                    rel = Str(source, "relPath"), availability = Str(source, "availability"),
                    eligible = source.GetProperty("eligible").GetBoolean() ? 1 : 0, hash = Str(source, "contentHash"),
                });
            foreach (var revision in input.GetProperty("revisions").EnumerateArray())
                conn.Execute("""
                    INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,
                        chunker_version,created_at) VALUES($id,$source,$revision,$hash,$text,$format,2,$created)
                    """, new
                {
                    id = Long(revision, "id"), source = Long(revision, "sourceId"), revision = Long(revision, "revision"),
                    hash = Str(revision, "contentHash"), text = Str(revision, "canonicalText"),
                    format = Long(revision, "textFormatVersion"), created,
                });
            foreach (var source in sources)
                conn.Execute("UPDATE sources SET current_revision=$current,published_revision_id=$published WHERE id=$id",
                    new { current = Long(source, "currentRevision"), published = Long(source, "publishedRevisionId"), id = Long(source, "id") });
            foreach (var job in input.GetProperty("jobs").EnumerateArray())
                conn.Execute("""
                    INSERT INTO ingest_jobs(id,kind,target,target_revision,attempts,next_retry_at,state,error,options_json,
                        lease_token,lease_until) VALUES($id,$kind,$target,$revision,$attempts,$retry,$state,$error,$options,$token,$until)
                    """, new
                {
                    id = Long(job, "id"), kind = Str(job, "kind"), target = Str(job, "target"),
                    revision = Long(job, "targetRevision"), attempts = Long(job, "attempts"), retry = Long(job, "nextRetryAt"),
                    state = Str(job, "state"), error = Str(job, "error"), options = Canonical(job.GetProperty("options")),
                    token = Str(job, "leaseToken"), until = Long(job, "leaseUntil"),
                });
            long maxSeeded = conn.ExecuteScalar<long>("SELECT coalesce(max(id),0) FROM ingest_jobs");
            var ingestion = new List<long>();
            store.FolderIngestionChanged += id => { lock (ingestion) ingestion.Add(id); };

            int count = store.RequeueSpreadsheetUpgrades(input.GetProperty("now").GetInt64());

            Assert.True(expected.GetProperty("requeued").GetInt32() == count, name);
            Assert.True(expected.GetProperty("notified").EnumerateArray().Select(n => n.GetInt64()).SequenceEqual(ingestion), name + ": notified");
            foreach (var source in expected.GetProperty("sources").EnumerateArray())
            {
                var row = conn.QuerySingle("SELECT status,error FROM sources WHERE id=$id", new { id = Long(source, "id") });
                Assert.True(Str(source, "status") == (string)row.status, name + ": status");
                Assert.True(Str(source, "error") == (string?)row.error, name + ": error");
            }
            var jobs = conn.Query("SELECT * FROM ingest_jobs WHERE id>$max ORDER BY id", new { max = maxSeeded }).ToList();
            var newJobs = expected.GetProperty("newJobs").EnumerateArray().ToArray();
            Assert.True(newJobs.Length == jobs.Count, name + ": job count");
            foreach (var (want, got) in newJobs.Zip(jobs))
            {
                Assert.True(Str(want, "kind") == (string)got.kind, name);
                Assert.True(Str(want, "target") == (string)got.target, name);
                Assert.True(Long(want, "targetRevision") == (long?)got.target_revision, name);
                Assert.True(Str(want, "state") == (string)got.state, name);
                Assert.True(Long(want, "attempts") == (long)got.attempts, name);
                Assert.True(Long(want, "nextRetryAt") == (long?)got.next_retry_at, name);
                Assert.True(Str(want, "error") == (string?)got.error, name);
                Assert.True(Canonical(want.GetProperty("options")) ==
                    Canonical(JsonDocument.Parse((string)got.options_json).RootElement), name + ": options");
            }
        }
    }

    [Fact]
    public void RevisionsRecordTheSpreadsheetTextFormat()
    {
        Assert.Equal(2, FolderExtractionWorker.TextFormatVersion("xlsx"));
        foreach (string kind in new[] { "text", "markdown", "pdf", "docx", "pptx", "email" })
            Assert.Equal(1, FolderExtractionWorker.TextFormatVersion(kind));
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebook = store.CreateNotebook("formats").Id!.Value;
        long sourceId = store.CreateSource(notebook, SourceType.Xlsx, "s", null, null).Id!.Value;
        foreach (var (format, accepted) in new[] { (1, true), (2, true), (0, false), (3, false) })
        {
            var draft = new RevisionDraft("h" + format, "R1: x", format, 2);
            if (accepted) Assert.Equal(format, store.Revision(store.InsertRevision(sourceId, draft, 1).Id)!.Draft.TextFormatVersion);
            else Assert.Equal("invalidValue", Assert.Throws<StorageV19Exception>(() => store.InsertRevision(sourceId, draft, 1)).Code);
        }
    }

    /// <summary>
    /// Ten workbooks published under the v1 spreadsheet text in an unwatched folder: start queues one batch of eight,
    /// every finished upgrade refills the batch, the old revisions stay searchable until replaced, and the final
    /// revisions carry the v2 text and are embedded.
    /// </summary>
    [Fact]
    public async Task StartUpgradesPublishedSpreadsheetsInBatches()
    {
        byte[] workbook = File.ReadAllBytes(SharedFixtures.Path("ingestion/workbook.xlsx"));
        using var rig = new ReextractContractTests.Rig(root =>
        {
            for (int i = 0; i < 10; i++) File.WriteAllBytes(Path.Combine(root, $"w{i:00}.xlsx"), workbook);
            File.WriteAllText(Path.Combine(root, "notes.md"), "Notes stay untouched.\n");
        });
        var folder = await rig.Runtime.AddFolderAsync(rig.Notebook, rig.Root);
        await rig.Runtime.SetWatchingAsync(folder.Id, false);
        await rig.DrainAllAsync();
        string expected = SpreadsheetSupersession.Map().GetProperty("ingestion-office-v1.json")
            .GetProperty("workbook-order").GetProperty("text").GetString()!;

        // Publish, for every spreadsheet, a revision of the same bytes as the v1 reader produced it.
        const string old = "## Zeta\nA1: Příliš\tC1: A😀B";
        var published = new Dictionary<long, long>();
        foreach (var row in rig.Store.Connection.Query("SELECT id,content_hash FROM sources WHERE type='xlsx' ORDER BY id").ToList())
        {
            long sourceId = (long)row.id;
            var revision = rig.Store.CommitForegroundRevision(sourceId, new RevisionDraft((string)row.content_hash, old, 1, 2),
                [new RevisionChunkDraft(old, 7, null, 0, old.EnumerateRunes().Count(), null, false)], 1_000, "v1-" + sourceId);
            published[sourceId] = revision.Id;
        }
        await rig.DrainAllAsync();
        Assert.Equal(10, published.Count);

        await rig.Runtime.StartAsync();
        var queued = rig.Store.Connection.Query(
            "SELECT target,options_json FROM ingest_jobs WHERE kind='extract' AND state='queued' ORDER BY id").ToList();
        Assert.Equal(ExtractorRevision.SpreadsheetBatchSize, queued.Count);
        Assert.All(queued, j => Assert.Equal(ExtractorRevision.SpreadsheetOptionsJson, (string)j.options_json));
        long[] sorted = published.Keys.Order().ToArray();
        Assert.Equal(sorted.Take(8).Select(id => $"source:{id}"), queued.Select(j => (string)j.target));
        foreach (var (sourceId, revision) in published)
        {
            var source = rig.Store.Source(sourceId)!;
            Assert.Equal(SourceStatus.Ready, source.Status);
            Assert.Equal(revision, source.PublishedRevisionId);
        }

        // One finished upgrade refills the batch with the next source.
        Assert.True(await rig.Runtime.DrainOnceAsync());
        var afterOne = rig.Store.Connection.Query<string>(
            "SELECT target FROM ingest_jobs WHERE state='queued' AND options_json=$options ORDER BY id",
            new { options = ExtractorRevision.SpreadsheetOptionsJson }).ToList();
        Assert.Equal(8, afterOne.Count);
        Assert.Equal($"source:{sorted[8]}", afterOne[^1]);

        for (int i = 0; i < 400 && await rig.Runtime.DrainOnceAsync(); i++) { }
        foreach (long sourceId in sorted)
        {
            var source = rig.Store.Source(sourceId)!;
            Assert.Equal(SourceStatus.Ready, source.Status);
            var revision = rig.Store.Revision(source.PublishedRevisionId!.Value)!;
            Assert.NotEqual(published[sourceId], revision.Id);
            Assert.Equal(2, revision.Draft.TextFormatVersion);
            Assert.Equal(expected, revision.Draft.CanonicalText);
        }
        Assert.Equal(0, rig.Store.RequeueSpreadsheetUpgrades(5_000));
        Assert.NotNull(rig.Store.ActiveGeneration(rig.Notebook));
        var status = await rig.Runtime.IndexingStatusAsync(rig.Notebook);
        Assert.Equal((IndexingPhase.Ready, 0), (status.Phase, status.SourceErrors));
        await rig.Runtime.StopAsync();
    }
}

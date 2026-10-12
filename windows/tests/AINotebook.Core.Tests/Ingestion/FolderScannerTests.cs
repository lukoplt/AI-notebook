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

public sealed class FolderScannerTests
{
    private static readonly Lazy<UnicodeTables> Tables = new(UnicodeTables.LoadBundled);
    private static readonly string[] EventOperations =
        ["list", "stat", "read", "deny", "finish", "cancel", "rootUnavailable", "apply-rules"];

    private sealed class Identity : IFolderPathIdentity
    {
        public FolderIdentity Resolve(string rootPath) => new("test", ["docs"], "root-1");
    }

    [Fact]
    public void ObservedChangeKeepsPublishedSearchable()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        long notebook = store.CreateNotebook("scan").Id!.Value;
        var folder = store.CreateFolder(notebook, new FolderDraft("/docs", "Docs", ["md"], [], "{}", "cp1250", true), new Identity(), 0);
        var source = store.CreateSource(notebook, SourceType.Markdown, "a", null, "/docs/a.md");
        long sourceId = source.Id!.Value;
        store.AttachSource(sourceId, folder.Id, "a.md");
        store.CommitForegroundRevision(sourceId, new RevisionDraft("old", "old", 1, 2), ScalarChunker.Chunk("old"), 0, "initial");
        long jobId = store.EnqueueJob(new IngestJobDraft("scan", $"folder:{folder.Id}", null), 1);
        Assert.NotNull(store.ClaimJob(1, "scan", jobId));
        var ticket = Assert.IsType<ScanTicket>(store.BeginFolderScan(folder.Id, new JobFence(jobId, "scan"), 1));
        var notifications = new List<long>();
        store.FolderIngestionChanged += changedNotebook =>
        {
            Assert.False(System.Threading.Monitor.IsEntered(store.Gate));
            notifications.Add(changedNotebook);
        };
        store.ObserveFolderFile(ticket, new FolderObservation("a.md", new FileStamp("f", 2, 3), "eligible", null, "new"), 1);
        Assert.Equal(new[] { notebook }, notifications);
        var result = store.Coverage(notebook, new RetrievalScope.All());
        Assert.Equal(1, result.Searchable);
        Assert.Equal(1, result.RefreshPending);
        Assert.Equal(0, result.RefreshError);
    }

    [Fact]
    public void AllScanTraces()
    {
        var rows = ScanCases();
        Assert.All(rows, c => Assert.Contains(Op(c), new[] { "walk", "identity", "open", "scan", "rules" }));
        var visited = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in rows.Where(c => Op(c) == "scan"))
        {
            Assert.True(visited.Add(Name(row)), Name(row));
            using var harness = new Harness(row);
            harness.Replay();
        }
        Assert.Equal(25, visited.Count);
    }

    [Fact]
    public void AllCoverageRows()
    {
        var fixture = SharedFixtures.Json("contracts/ingestion-coverage-v1.json");
        Assert.Equal("ingestion-coverage", fixture.GetProperty("contract").GetString());
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in fixture.GetProperty("cases").EnumerateArray())
        {
            Assert.Equal("coverage", Op(row));
            Assert.True(names.Add(Name(row)));
            var i = row.GetProperty("input");
            using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
            Assert.Equal(1, store.CreateNotebook("one").Id);
            Assert.Equal(2, store.CreateNotebook("two").Id);
            long notebook = i.GetProperty("notebookId").GetInt64();
            long folderId = i.GetProperty("folderId").GetInt64();
            string relPath = i.GetProperty("relPath").GetString()!;
            lock (store.Gate)
            {
                var c = store.Connection;
                using var tx = c.BeginTransaction();
                c.Execute("""
                    INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,
                        ignore_globs,limits,scan_state,created_at)
                    VALUES($folderId,$notebook,'/docs','{"volumeId":"test","components":["docs"],"rootFileId":"root-1"}',
                        'Docs','["md"]','[]','{}',$state,'2026-01-01 00:00:00.000')
                    """, new { folderId, notebook, state = i.GetProperty("scanState").GetString() }, tx);
                if (Long(i, "sourceId") is long sourceId)
                {
                    c.Execute("""
                        INSERT INTO sources(id,notebook_id,type,title,status,ingested_at,folder_id,rel_path,availability,eligible)
                        VALUES($sourceId,$notebook,'markdown','a',$status,'2026-01-01 00:00:00.000',$folderId,$relPath,$availability,$eligible)
                        """, new
                    {
                        sourceId, notebook, folderId, relPath, status = i.GetProperty("status").GetString(),
                        availability = i.GetProperty("availability").GetString(), eligible = i.GetProperty("eligible").GetBoolean()
                    }, tx);
                    long? current = Long(i, "currentRevision");
                    long? published = Long(i, "publishedRevisionId");
                    // Vector activation is intentionally not seeded: active-vector state never changes corpus counts.
                    foreach (long revision in new[] { current, published }.OfType<long>().Distinct())
                        c.Execute("""
                            INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,
                                chunker_version,created_at) VALUES($revision,$sourceId,$revision,'h','text',1,2,'2026-01-01 00:00:00.000')
                            """, new { revision, sourceId }, tx);
                    c.Execute("UPDATE sources SET current_revision=$current,published_revision_id=$published WHERE id=$sourceId",
                        new { current, published, sourceId }, tx);
                }
                if (i.GetProperty("hasScanItem").GetBoolean())
                {
                    string kind = i.GetProperty("scanKind").GetString()!;
                    c.Execute("""
                        INSERT INTO scan_items(folder_id,rel_path,kind,skip_reason,mtime,size_bytes,seen_generation)
                        VALUES($folderId,$relPath,$kind,$reason,10,5,1)
                        """, new { folderId, relPath, kind, reason = kind == "skipped" ? "ignored" : null }, tx);
                }
                tx.Commit();
            }
            var scope = i.TryGetProperty("scope", out var rawScope)
                ? RetrievalScopeJson.Deserialize(rawScope.GetRawText()) : new RetrievalScope.All();
            long query = Long(i, "queryNotebookId") ?? notebook;
            var got = store.Coverage(query, scope);
            var expected = row.GetProperty("expected");
            AssertJson(expected, JsonSerializer.SerializeToElement(new
            {
                searchable = got.Searchable, notSearchable = got.NotSearchable, current = got.Current,
                refreshPending = got.RefreshPending, refreshError = got.RefreshError, skipped = got.Skipped,
                missing = got.Missing, unavailable = got.Unavailable, isLowerBound = got.IsLowerBound
            }), Name(row));
            // The raw DTO keeps WP3's pending/error split; the derived dimensions never sum freshness and corpus.
            Assert.Equal(got.NotSearchable, got.Pending + got.Error);
            Assert.Equal(got.Current, got.Searchable + got.Pending + got.Error - got.RefreshPending - got.RefreshError);
        }
        Assert.Equal(19, names.Count);
    }

    [Fact]
    public async Task RuleChangeRevokesImmediately()
    {
        var names = new List<string>();
        foreach (var row in ScanCases().Where(c => Op(c) == "rules"))
        {
            names.Add(Name(row));
            using var harness = new Harness(row);
            harness.Replay();
        }
        Assert.Equal(new[] { "rule-reenable-current", "rule-reenable-unpublished" }, names);

        // Revocation is visible to the next fresh SQL snapshot, before any rescan runs.
        using var revoke = new Harness(ScanCases().Single(c => Name(c) == "rule-reenable-current"));
        Assert.Equal(1, revoke.Store.Coverage(1, new RetrievalScope.All()).Searchable);
        var scanner = new FolderScanner(revoke.Store, new RulesOnlyFS(), Tables.Value, new TestClock(1));
        await scanner.ApplyRulesAsync(1, new FolderRules(["md"], ["docs-*", "*.md"], IngestionLimits.Defaults, "cp1250"), 1);
        var revoked = revoke.Store.Coverage(1, new RetrievalScope.All());
        Assert.Equal(0, revoked.Searchable);
        Assert.Equal(1, revoked.Skipped);

        // Invalid rules are rejected before any write and emit nothing.
        int notified = 0;
        revoke.Store.FolderIngestionChanged += _ => notified++;
        var before = revoke.Snapshot();
        var error = await Assert.ThrowsAsync<FolderIngestionException>(() =>
            scanner.ApplyRulesAsync(1, new FolderRules(["md"], ["[bad"], IngestionLimits.Defaults, "cp1250"), 2));
        Assert.Equal("unsupportedSyntax", error.Code);
        Assert.Equal(before, revoke.Snapshot());
        Assert.Equal(0, notified);

        // Changing extraction limits forces fresh extraction of eligible published content.
        await scanner.ApplyRulesAsync(1, new FolderRules(["md"], [], IngestionLimits.Defaults with { TextScalars = 1000 }, "cp1250"), 3);
        Assert.Equal(1, notified);
        var source = revoke.Store.Source(101)!;
        Assert.True(source.Eligible);
        Assert.Equal(SourceStatus.Pending, source.Status);
        lock (revoke.Store.Gate)
            Assert.Equal(1, revoke.Store.Connection.ExecuteScalar<long>(
                "SELECT count(*) FROM ingest_jobs WHERE kind='extract' AND target='source:101' AND state='queued'"));
        Assert.Equal(1000, NotebookStore.FolderRulesOf(revoke.Store.Folder(1)!).Limits.TextScalars);

        // Skip reasons keep ignored-first precedence from the classifier; without one the store falls back to
        // extension/size checks. A path missing from the verdict map is stale.
        await scanner.ApplyRulesAsync(1, new FolderRules(["txt"], ["a.*"], IngestionLimits.Defaults with { TextScalars = 1000 }, "cp1250"), 4);
        Assert.Equal(("skipped", "ignored"), Inventory(revoke.Store, "a.md"));
        var rules = new FolderRules(["txt"], [], IngestionLimits.Defaults with { TextScalars = 1000 }, "cp1250");
        revoke.Store.ApplyFolderRules(1, rules, new Dictionary<string, bool> { ["a.md"] = false }, 5);
        Assert.Equal(("skipped", "unsupported_ext"), Inventory(revoke.Store, "a.md"));
        Assert.Equal("staleRevision", Assert.Throws<StorageV19Exception>(() =>
            revoke.Store.ApplyFolderRules(1, rules, new Dictionary<string, bool>(), 6)).Code);
    }

    [Fact]
    public async Task StaleScanCannotFinish()
    {
        using (var harness = new Harness(ScanCases().Single(c => Name(c) == "late-old-generation")))
        {
            int notified = 0;
            harness.Store.FolderIngestionChanged += _ => notified++;
            harness.Replay();
            Assert.Equal(0, notified);
        }

        using var store = SingleFolderStore(out long folderId);
        int count = 0;
        store.FolderIngestionChanged += _ => count++;
        long first = store.EnqueueJob(new IngestJobDraft("scan", $"folder:{folderId}", null), 0);
        Assert.NotNull(store.ClaimJob(0, "scan-a", first));
        var ticket = store.BeginFolderScan(folderId, new JobFence(first, "scan-a"), 0)!;
        Assert.Equal(1, count);
        // A second live scan of the same folder cannot start a competing generation.
        long rival = store.EnqueueJob(new IngestJobDraft("scan", $"folder:{folderId}", null), 1);
        Assert.NotNull(store.ClaimJob(1, "scan-b", rival));
        Assert.Null(store.BeginFolderScan(folderId, new JobFence(rival, "scan-b"), 1));
        // Expired lease: neither observation nor completion can commit.
        var observation = new FolderObservation("a.md", new FileStamp("f", 1, 1), "eligible", null, "h");
        Assert.Equal("staleLease", Assert.Throws<StorageV19Exception>(() => store.ObserveFolderFile(ticket, observation, 300)).Code);
        Assert.False(store.FinishFolderScan(ticket, new ScanCompletion([""], [], false, null), 300));
        Assert.Equal(1, count);
        Assert.Equal("scanning", store.Folder(folderId)!.ScanState);
        Assert.Empty(store.ScanItems(folderId));
        // After reclaim, the old ticket fails both generation and token guards.
        Assert.Equal(2, store.RecoverExpiredJobs(301)); // both expired scan leases are reclaimed
        var reclaimed = store.ClaimJob(400, "scan-c", first)!;
        var next = store.BeginFolderScan(folderId, new JobFence(reclaimed.Id, "scan-c"), 400)!;
        Assert.Equal(ticket.Generation + 1, next.Generation);
        Assert.False(store.FinishFolderScan(ticket with { Fence = new JobFence(first, "scan-c") }, new ScanCompletion([""], [], false, null), 401));
        Assert.False(store.MarkFolderScanCancelled(ticket, 401));
        Assert.True(store.FinishFolderScan(next, new ScanCompletion([""], [], false, null), 402));
        Assert.Equal("idle", store.Folder(folderId)!.ScanState);
        Assert.Equal(402, store.Folder(folderId)!.LastFullScanAt);
        // Scanner with a stale fence performs no writes at all.
        var scanner = new FolderScanner(store, new RulesOnlyFS(), Tables.Value, new TestClock(500));
        await scanner.ScanAsync(folderId, false, new JobFence(first, "scan-a"), 500);
        Assert.Equal(next.Generation, store.Folder(folderId)!.ScanGeneration);
    }

    [Fact]
    public async Task PartialAndUnavailable()
    {
        var rows = ScanCases();
        var partial = rows.Single(c => Name(c) == "partial-sibling");
        var fs = new ScriptedFS(partial);
        using (var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null))
        {
            long notebook = store.CreateNotebook("partial").Id!.Value;
            var folder = store.CreateFolder(notebook, fs.Root.Draft, fs, 0);
            Assert.Equal(fs.Root.Id, folder.Id);
            var created = new List<long>();
            foreach (var seed in partial.GetProperty("input").GetProperty("seedSources").EnumerateArray())
            {
                long id = store.CreateSource(notebook, SourceType.Markdown, "gone", null, null).Id!.Value;
                store.AttachSource(id, folder.Id, seed.GetProperty("relPath").GetString()!);
                store.CommitForegroundRevision(id, new RevisionDraft("h", seed.GetProperty("canonicalText").GetString()!, 1, 2),
                    ScalarChunker.Chunk(seed.GetProperty("canonicalText").GetString()!), 0, "seed");
                created.Add(id);
            }
            var fixtureIds = partial.GetProperty("input").GetProperty("seedSources").EnumerateArray()
                .Select(s => s.GetProperty("id").GetInt64()).ToArray();
            long job = store.EnqueueJob(new IngestJobDraft("scan", $"folder:{folder.Id}", null), 1);
            store.ClaimJob(1, "scan", job);
            await new FolderScanner(store, fs, Tables.Value, new TestClock(2)).ScanAsync(folder.Id, false, new JobFence(job, "scan"), 1);
            var missing = created.Select((id, index) => (id, index)).Where(p => store.Source(p.id)!.Availability == "missing")
                .Select(p => fixtureIds[p.index]).ToArray();
            Assert.Equal(Longs(partial.GetProperty("expected"), "missingSourceIds"), missing);
            var after = store.Folder(folder.Id)!;
            Assert.Equal("partial", after.ScanState);
            Assert.Null(after.LastFullScanAt);
            Assert.Equal("done", store.Job(job)!.State);
            Assert.Equal(new[] { "", "bad", "good" }, fs.ListCalls);
        }

        // Interior links are never followed, hashed or created as sources.
        foreach (var row in rows.Where(c => Op(c) == "walk" && c.GetProperty("input").TryGetProperty("linkKinds", out _)))
        {
            var links = new ScriptedFS(row);
            using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
            long notebook = store.CreateNotebook("links").Id!.Value;
            var folder = store.CreateFolder(notebook, links.Root.Draft, links, 0);
            long job = store.EnqueueJob(new IngestJobDraft("scan", $"folder:{folder.Id}", null), 1);
            store.ClaimJob(1, "scan", job);
            await new FolderScanner(store, links, Tables.Value, new TestClock(2)).ScanAsync(folder.Id, false, new JobFence(job, "scan"), 1);
            Assert.Equal(row.GetProperty("expected").GetProperty("targetReadCalls").GetInt32(), links.ReadCalls);
            Assert.Empty(store.SourcesIncludingShadow(notebook));
            Assert.Empty(store.ScanItems(folder.Id));
            Assert.Equal("idle", store.Folder(folder.Id)!.ScanState);
        }

        foreach (string name in new[] { "root-offline", "cancelled", "unexpected-error", "partial-then-full" })
            await RunScanner(rows.Single(c => Name(c) == name));
    }

    [Fact]
    public async Task FingerprintFastPath()
    {
        var single = ScanCases().Where(c => Op(c) == "scan" && Name(c) is not ("late-old-generation" or "root-offline"
            or "cancelled" or "unexpected-error" or "partial-then-full")).ToArray();
        Assert.Equal(20, single.Length);
        foreach (var row in single) await RunScanner(row);
    }

    [Fact]
    public async Task RestartPendingWork()
    {
        using var store = SingleFolderStore(out long folderId);
        long notebook = store.Folder(folderId)!.NotebookId;
        long sourceId = store.CreateSource(notebook, SourceType.Markdown, "a", null, null).Id!.Value;
        store.AttachSource(sourceId, folderId, "a.md");
        store.CommitForegroundRevision(sourceId, new RevisionDraft("h", "old", 1, 2), ScalarChunker.Chunk("old"), 0, "seed");
        var ticket = Begin(store, folderId, 1, "scan-1");
        lock (store.Gate) store.Connection.Execute("UPDATE sources SET mtime=10,size_bytes=5 WHERE id=$sourceId", new { sourceId });

        // A changed observation carries the newly computed hash in memory; the committed hash is unchanged.
        var changed = store.ObserveFolderFile(ticket, new FolderObservation("a.md", new FileStamp("f", 11, 5), "eligible", null, "new"), 2)!;
        Assert.Equal("new", changed.Hash);
        Assert.Equal("h", store.Source(sourceId)!.ContentHash);
        var restarted = store.ExtractionRequest(sourceId)!;
        Assert.Equal("h", restarted.Hash);
        Assert.Equal(new FileStamp("", 11, 5), restarted.Stamp);
        Assert.Equal(NotebookStore.FolderRulesOf(store.Folder(folderId)!), restarted.Rules);
        // A new file has no committed hash until publication.
        var fresh = store.ObserveFolderFile(ticket, new FolderObservation("b.md", new FileStamp("g", 3, 4), "eligible", null, "b-hash"), 2)!;
        Assert.Equal("b-hash", fresh.Hash);
        Assert.Equal("", store.ExtractionRequest(fresh.SourceId)!.Hash);
        Assert.Null(store.Source(fresh.SourceId)!.ContentHash);
        Assert.True(store.FinishFolderScan(ticket, new ScanCompletion([""], [], false, null), 3));

        // A failed refresh with an unchanged stamp is not fast-pathed: the scanner rehashes and, since a retryable
        // failed job is not reusable, supersedes it with one fresh due job (Swift parity: metadata never suppresses work).
        long extract = ExtractJobs(store, sourceId).Single();
        Assert.Null(store.Job(extract)!.NextRetryAt); // WP6 jobs are immediately due
        Assert.NotNull(store.ClaimJob(4, "extract-1", extract));
        Assert.True(store.FailJob(new JobFence(extract, "extract-1"), "corruptArchive", 5));
        Assert.Equal(SourceStatus.Error, store.Source(sourceId)!.Status);
        Assert.False(store.FolderFastPath(folderId, "a.md", new FileStamp("f", 11, 5)));
        var fs = new MapFS(new() { ["a.md"] = (new FileStamp("f", 11, 5), "new"), ["b.md"] = (new FileStamp("g", 3, 4), "b-hash") });
        await Scan(store, folderId, fs, 10, "scan-2");
        Assert.Equal(2, fs.HashCalls);
        var jobs = ExtractJobs(store, sourceId);
        Assert.Equal(2, jobs.Length);
        Assert.Equal("cancelled", store.Job(extract)!.State);
        Assert.Equal(("queued", 0), (store.Job(jobs[1])!.State, store.Job(jobs[1])!.Attempts));
        Assert.Equal(SourceStatus.Pending, store.Source(sourceId)!.Status);

        // An identical observation reuses the unclaimed job instead of queuing another.
        await Scan(store, folderId, fs, 20, "scan-3");
        Assert.Equal(jobs, ExtractJobs(store, sourceId));

        // A user-cancelled refresh becomes a visible error; the next scan re-queues it.
        Assert.True(store.CancelIngestJob(jobs[1], null, 21));
        Assert.Equal((SourceStatus.Error, "cancelled"), (store.Source(sourceId)!.Status, store.Source(sourceId)!.Error));
        await Scan(store, folderId, fs, 22, "scan-4");
        jobs = ExtractJobs(store, sourceId);
        Assert.Equal(3, jobs.Length);
        Assert.Equal("queued", store.Job(jobs[2])!.State);

        // File reverted to the published bytes: outstanding refresh work is superseded.
        var reverted = new MapFS(new() { ["a.md"] = (new FileStamp("f", 12, 3), "h"), ["b.md"] = (new FileStamp("g", 3, 4), "b-hash") });
        await Scan(store, folderId, reverted, 30, "scan-5");
        Assert.Equal("cancelled", store.Job(jobs[2])!.State);
        Assert.Equal(SourceStatus.Ready, store.Source(sourceId)!.Status);
        Assert.Equal(1, store.Coverage(notebook, new RetrievalScope.Selection(new HashSet<long> { sourceId }, new HashSet<long>())).Current);
    }

    private static (string Kind, string? Reason) Inventory(NotebookStore store, string path)
    {
        var item = store.ScanItems(1).Single(i => i.RelPath == path);
        return (item.Kind, item.SkipReason);
    }

    private static async Task Scan(NotebookStore store, long folderId, IFolderFileSystem fs, long at, string token)
    {
        long job = store.EnqueueJob(new IngestJobDraft("scan", $"folder:{folderId}", null), at);
        Assert.NotNull(store.ClaimJob(at, token, job));
        await new FolderScanner(store, fs, Tables.Value, new TestClock(at + 1)).ScanAsync(folderId, false, new JobFence(job, token), at);
        Assert.Equal("done", store.Job(job)!.State);
    }

    private static long[] ExtractJobs(NotebookStore store, long sourceId)
    {
        lock (store.Gate)
            return store.Connection.Query<long>("SELECT id FROM ingest_jobs WHERE kind='extract' AND target=$target AND state<>'done' ORDER BY id",
                new { target = $"source:{sourceId}" }).ToArray();
    }

    private static ScanTicket Begin(NotebookStore store, long folderId, long at, string token)
    {
        long job = store.EnqueueJob(new IngestJobDraft("scan", $"folder:{folderId}", null), at);
        Assert.NotNull(store.ClaimJob(at, token, job));
        return store.BeginFolderScan(folderId, new JobFence(job, token), at)!;
    }

    private static NotebookStore SingleFolderStore(out long folderId)
    {
        var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebook = store.CreateNotebook("scan").Id!.Value;
        folderId = store.CreateFolder(notebook, new FolderDraft("/docs", "Docs", ["md"], [], "{}", "cp1250", true), new Identity(), 0).Id;
        return store;
    }

    /// <summary>
    /// Drives the real <see cref="FolderScanner"/> once per scan segment (a beginScan event up to the next one)
    /// with a filesystem scripted from that segment's events, then compares the segment's final projection.
    /// </summary>
    private static async Task RunScanner(JsonElement row)
    {
        using var harness = new Harness(row);
        var events = row.GetProperty("input").GetProperty("events").EnumerateArray().ToArray();
        bool verifyAll = row.GetProperty("input").TryGetProperty("verifyAll", out var v) && v.GetBoolean();
        var starts = events.Select((e, index) => (e, index)).Where(p => Bool(p.e, "beginScan")).Select(p => p.index).ToArray();
        Assert.NotEmpty(starts);
        int hashes = 0;
        var lists = new List<string>();
        for (int s = 0; s < starts.Length; s++)
        {
            var segment = events[starts[s]..(s + 1 < starts.Length ? starts[s + 1] : events.Length)];
            var begin = segment[0];
            var fence = harness.ClaimFor(begin);
            using var cts = new CancellationTokenSource();
            var fs = new EventFS(row, segment, cts);
            var scanner = new FolderScanner(harness.Store, fs, Tables.Value, new TestClock(segment[^1].GetProperty("at").GetInt64()));
            var scan = scanner.ScanAsync(begin.GetProperty("folderId").GetInt64(), verifyAll, fence, begin.GetProperty("at").GetInt64(), cts.Token);
            if (segment.Any(e => Op(e) == "cancel"))
            {
                await Assert.ThrowsAnyAsync<OperationCanceledException>(() => scan);
                // The queue owns the fenced job cancellation; the scanner only marked its generation partial.
                Assert.True(harness.Store.CancelJob(fence, segment[^1].GetProperty("at").GetInt64()));
            }
            else await scan;
            hashes += fs.HashCalls;
            lists.AddRange(fs.ListCalls);
            harness.SetCounters(hashes, lists);
            harness.AssertProjection(segment[^1].GetProperty("expected"), $"{Name(row)} scanner segment {s}");
        }
        harness.AssertProjection(row.GetProperty("expected"), Name(row) + " scanner final");
    }

    private sealed class Harness : IDisposable
    {
        private readonly JsonElement _row;
        private readonly Dictionary<long, long> _jobs = new();
        private readonly Dictionary<long, long> _sources = new();
        private readonly bool _verifyAll;
        private ScanTicket? _ticket;
        private FolderObservation? _deferred;
        private string? _awaitingRead;
        private int _readCalls;
        private List<string> _listCalls = [];
        public NotebookStore Store { get; } = new(StorePath.InMemory, configuredEmbeddingModelKey: null);

        public Harness(JsonElement row)
        {
            _row = row;
            var input = row.GetProperty("input");
            _verifyAll = input.TryGetProperty("verifyAll", out var v) && v.GetBoolean();
            var root = input.GetProperty("root");
            var seed = input.GetProperty("seed");
            var folder = seed.GetProperty("folder");
            Assert.Equal(root.GetProperty("notebookId").GetInt64(), Store.CreateNotebook("scan").Id);
            string limits = input.TryGetProperty("maxFileBytes", out var max) ? $$"""{"maxFileBytes":{{max.GetInt64()}}}""" : "{}";
            var ignore = input.TryGetProperty("ignoreGlobs", out var globs)
                ? globs.EnumerateArray().Select(g => g.GetString()!).ToArray() : FolderRules.Defaults.IgnoreGlobs.ToArray();
            var identity = new FolderIdentity(root.GetProperty("volumeId").GetString()!,
                root.GetProperty("components").EnumerateArray().Select(c => c.GetString()!).ToArray(), root.GetProperty("rootFileId").GetString()!);
            var created = Store.CreateFolder(root.GetProperty("notebookId").GetInt64(), new FolderDraft(root.GetProperty("rootPath").GetString()!,
                root.GetProperty("displayName").GetString()!, FolderRules.Defaults.IncludeExts, ignore, limits, "cp1250", true),
                new FixedIdentity(identity), 0);
            Assert.Equal(root.GetProperty("id").GetInt64(), created.Id);
            lock (Store.Gate)
            {
                var c = Store.Connection;
                using var tx = c.BeginTransaction();
                c.Execute("""
                    UPDATE folder_sources SET scan_state=$state,scan_generation=$generation,last_full_scan_at=$full,last_scan_error=$error
                    WHERE id=$id
                    """, new
                {
                    id = folder.GetProperty("id").GetInt64(), state = folder.GetProperty("scanState").GetString(),
                    generation = folder.GetProperty("scanGeneration").GetInt64(), full = Long(folder, "lastFullScanAt"),
                    error = Str(folder, "lastScanError")
                }, tx);
                foreach (var s in seed.GetProperty("sources").EnumerateArray())
                {
                    long id = s.GetProperty("id").GetInt64();
                    _sources[id] = id;
                    c.Execute("""
                        INSERT INTO sources(id,notebook_id,type,title,status,error,ingested_at,folder_id,rel_path,mtime,size_bytes,
                            availability,eligible,content_hash)
                        VALUES($id,$notebook,'markdown','seed',$status,$error,'2026-01-01 00:00:00.000',$folder,$path,$mtime,$size,
                            $availability,$eligible,$hash)
                        """, new
                    {
                        id, notebook = s.GetProperty("notebookId").GetInt64(), status = Str(s, "status"), error = Str(s, "error"),
                        folder = s.GetProperty("folderId").GetInt64(), path = Str(s, "relPath"), mtime = Long(s, "mtimeNs"),
                        size = Long(s, "sizeBytes"), availability = Str(s, "availability"), eligible = s.GetProperty("eligible").GetBoolean(),
                        hash = Str(s, "contentHash")
                    }, tx);
                }
                foreach (var r in seed.GetProperty("revisions").EnumerateArray())
                {
                    long id = r.GetProperty("id").GetInt64();
                    c.Execute("""
                        INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                        VALUES($id,$source,1,'h',$text,1,2,'2026-01-01 00:00:00.000')
                        """, new { id, source = r.GetProperty("sourceId").GetInt64(), text = Str(r, "canonicalText") }, tx);
                    int ord = 0;
                    foreach (var chunk in r.GetProperty("chunks").EnumerateArray())
                        c.Execute("""
                            INSERT INTO source_chunks(source_id,revision_id,ord,text,token_count,char_start,char_end)
                            VALUES($source,$id,$ord,$text,1,$start,$end)
                            """, new
                        {
                            source = r.GetProperty("sourceId").GetInt64(), id, ord = ord++, text = Str(chunk, "text"),
                            start = chunk.GetProperty("start").GetInt64(), end = chunk.GetProperty("end").GetInt64()
                        }, tx);
                }
                foreach (var s in seed.GetProperty("sources").EnumerateArray())
                    c.Execute("UPDATE sources SET current_revision=$current,published_revision_id=$published WHERE id=$id", new
                    {
                        id = s.GetProperty("id").GetInt64(), current = Long(s, "currentRevision"), published = Long(s, "publishedRevisionId")
                    }, tx);
                foreach (var j in seed.GetProperty("jobs").EnumerateArray())
                {
                    long id = j.GetProperty("id").GetInt64();
                    _jobs[id] = id;
                    c.Execute("""
                        INSERT INTO ingest_jobs(id,kind,target,target_revision,attempts,state,lease_until,lease_token)
                        VALUES($id,$kind,$target,$revision,$attempts,$state,$until,$token)
                        """, new
                    {
                        id, kind = Str(j, "kind"), target = Str(j, "target"), revision = Long(j, "targetRevision"),
                        attempts = j.GetProperty("attempts").GetInt64(), state = Str(j, "state"), until = Long(j, "leaseUntil"),
                        token = Str(j, "leaseToken")
                    }, tx);
                }
                foreach (var item in seed.GetProperty("inventory").EnumerateArray())
                    c.Execute("""
                        INSERT INTO scan_items(folder_id,rel_path,kind,skip_reason,mtime,size_bytes,seen_generation)
                        VALUES($folder,$path,$kind,$reason,$mtime,$size,$generation)
                        """, new
                    {
                        folder = item.GetProperty("folderId").GetInt64(), path = Str(item, "relPath"), kind = Str(item, "kind"),
                        reason = Str(item, "skipReason"), mtime = Long(item, "mtimeNs"), size = Long(item, "sizeBytes"),
                        generation = item.GetProperty("seenGeneration").GetInt64()
                    }, tx);
                tx.Commit();
            }
            _listCalls = Strings(seed, "listCalls").ToList();
            _readCalls = seed.GetProperty("readCalls").GetInt32();
            AssertProjection(seed, Name(row) + " seed");
        }

        public void Dispose() => Store.Dispose();

        public void SetCounters(int readCalls, List<string> listCalls)
        {
            _readCalls = readCalls;
            _listCalls = listCalls.ToList();
        }

        /// <summary>Creates (or reuses) the running scan job named by a beginScan event and returns its fence.</summary>
        public JobFence ClaimFor(JsonElement e)
        {
            long fixtureId = e.GetProperty("jobId").GetInt64();
            string token = e.GetProperty("leaseToken").GetString()!;
            long at = e.GetProperty("at").GetInt64();
            if (!_jobs.ContainsValue(fixtureId))
            {
                long actual = Store.EnqueueJob(new IngestJobDraft("scan", $"folder:{e.GetProperty("folderId").GetInt64()}", null,
                    """{"verifyAll":false}"""), at);
                Assert.NotNull(Store.ClaimJob(at, token, actual));
                _jobs[actual] = fixtureId;
            }
            return new JobFence(ActualJob(fixtureId), token);
        }

        public void Replay()
        {
            var events = _row.GetProperty("input").GetProperty("events").EnumerateArray().ToArray();
            for (int index = 0; index < events.Length; index++)
            {
                var e = events[index];
                string op = Op(e);
                Assert.Contains(op, EventOperations);
                long at = e.GetProperty("at").GetInt64();
                if (_deferred is not null)
                {
                    // The fixture captures a fast-path stat before its observation commits; the commit closes the visit.
                    Store.ObserveFolderFile(_ticket!, _deferred, at);
                    _deferred = null;
                }
                if (_awaitingRead is not null) Assert.True(op == "read" && Str(e, "relPath") == _awaitingRead, $"{Name(_row)}: read expected");
                switch (op)
                {
                    case "list":
                        if (Bool(e, "beginScan")) Begin(e);
                        _listCalls.Add(Str(e, "directory")!);
                        break;
                    case "stat":
                        Stat(e, at);
                        break;
                    case "read":
                        _awaitingRead = null;
                        _readCalls++;
                        Store.ObserveFolderFile(_ticket!, new FolderObservation(Str(e, "relPath")!, Stamp(e.GetProperty("stamp")),
                            "eligible", null, Str(e, "hash")), at);
                        break;
                    case "deny":
                        if (Str(e, "error") == "permissionDenied") _listCalls.Add(Str(e, "directory")!);
                        else Assert.True(Store.FinishFolderScan(_ticket!, new ScanCompletion([], [""], false, Str(e, "error")), at));
                        break;
                    case "rootUnavailable":
                        if (Bool(e, "beginScan")) Begin(e);
                        Assert.True(Store.FinishFolderScan(_ticket!, new ScanCompletion([], [""], true, Str(e, "error")), at));
                        break;
                    case "cancel":
                        Assert.True(Store.CancelJob(_ticket!.Fence, at));
                        Assert.True(Store.MarkFolderScanCancelled(_ticket, at));
                        break;
                    case "finish":
                        var ticket = e.TryGetProperty("jobId", out var job)
                            ? new ScanTicket(e.GetProperty("folderId").GetInt64(), e.GetProperty("generation").GetInt64(),
                                new JobFence(ActualJob(job.GetInt64()), Str(e, "leaseToken") ?? _ticket!.Fence.LeaseToken))
                            : _ticket! with { Generation = e.GetProperty("generation").GetInt64() };
                        bool accepted = !e.TryGetProperty("accepted", out var a) || a.GetBoolean();
                        Assert.Equal(accepted, Store.FinishFolderScan(ticket, new ScanCompletion(Strings(e, "completed"),
                            Strings(e, "incomplete"), e.GetProperty("rootUnavailable").GetBoolean(), null), at));
                        break;
                    case "apply-rules":
                        var scanner = new FolderScanner(Store, new RulesOnlyFS(), Tables.Value, new TestClock(at));
                        scanner.ApplyRulesAsync(e.GetProperty("folderId").GetInt64(), new FolderRules(Strings(e, "includeExts"),
                            Strings(e, "ignoreGlobs"), IngestionLimits.Defaults, "cp1250"), at).GetAwaiter().GetResult();
                        lock (Store.Gate)
                        {
                            var eligible = Store.Connection.Query<long>("SELECT id FROM sources WHERE folder_id=1 AND eligible=1 ORDER BY id")
                                .Select(id => _sources[id]).ToArray();
                            var retrievable = Store.Connection.Query<long>("""
                                SELECT id FROM sources WHERE folder_id=1 AND eligible=1 AND availability='present'
                                    AND published_revision_id IS NOT NULL ORDER BY id
                                """).Select(id => _sources[id]).ToArray();
                            Assert.Equal(Longs(e, "eligibleSourceIds"), eligible);
                            Assert.Equal(Longs(e, "retrievalSourceIds"), retrievable);
                        }
                        break;
                    default:
                        Assert.Fail("Unknown scan event operation " + op);
                        break;
                }
                AssertProjection(e.GetProperty("expected"), $"{Name(_row)} event {index} ({op})");
            }
            Assert.Null(_awaitingRead);
            Assert.Null(_deferred);
            AssertProjection(_row.GetProperty("expected"), Name(_row) + " final");
        }

        private void Begin(JsonElement e)
        {
            var fence = ClaimFor(e);
            _ticket = Store.BeginFolderScan(e.GetProperty("folderId").GetInt64(), fence, e.GetProperty("at").GetInt64());
            Assert.NotNull(_ticket);
            Assert.Equal(e.GetProperty("generation").GetInt64(), _ticket!.Generation);
        }

        private void Stat(JsonElement e, long at)
        {
            string path = Str(e, "relPath")!;
            var stamp = Stamp(e.GetProperty("stamp"));
            var folder = Store.Folder(_ticket!.FolderId)!;
            var classifier = new FolderRuleClassifier(NotebookStore.FolderRulesOf(folder), true, Tables.Value);
            var (kind, reason) = classifier.Classify(path, stamp.SizeBytes);
            if (kind == "skipped")
                Store.ObserveFolderFile(_ticket, new FolderObservation(path, stamp, kind, reason, null), at);
            else if (!_verifyAll && Store.FolderFastPath(folder.Id, path, stamp))
                _deferred = new FolderObservation(path, stamp, "eligible", null, null);
            else
                _awaitingRead = path;
        }

        private long ActualJob(long fixtureId) => _jobs.Single(p => p.Value == fixtureId).Key;

        public string Snapshot() => Project(null).GetRawText();

        public void AssertProjection(JsonElement expected, string context) => AssertJson(expected, Project(expected), context);

        private JsonElement Project(JsonElement? expected)
        {
            lock (Store.Gate)
            {
                var c = Store.Connection;
                var sourceIds = c.Query<long>("SELECT id FROM sources ORDER BY id").ToArray();
                var jobIds = c.Query<long>("SELECT id FROM ingest_jobs ORDER BY id").ToArray();
                if (expected is JsonElement e)
                {
                    Bind(_sources, sourceIds, e.GetProperty("sources").EnumerateArray().Select(s => s.GetProperty("id").GetInt64()));
                    Bind(_jobs, jobIds, e.GetProperty("jobs").EnumerateArray().Select(j => j.GetProperty("id").GetInt64()));
                }
                long Src(long id) => _sources.TryGetValue(id, out long f) ? f : -id;
                string Target(string target) => target.StartsWith("source:", StringComparison.Ordinal)
                    ? "source:" + Src(long.Parse(target["source:".Length..], System.Globalization.CultureInfo.InvariantCulture))
                    : target;
                var f = c.QuerySingle("SELECT * FROM folder_sources WHERE id=1");
                var projection = new
                {
                    folder = new
                    {
                        id = (long)f.id, notebookId = (long)f.notebook_id, scanState = (string)f.scan_state,
                        scanGeneration = (long)f.scan_generation, lastFullScanAt = (long?)f.last_full_scan_at,
                        lastScanError = (string?)f.last_scan_error
                    },
                    sources = c.Query("SELECT * FROM sources ORDER BY id").Select(s => new
                    {
                        id = Src((long)s.id), notebookId = (long)s.notebook_id, folderId = (long?)s.folder_id,
                        relPath = (string?)s.rel_path, status = (string)s.status, availability = (string)s.availability,
                        eligible = (long)s.eligible != 0, currentRevision = (long?)s.current_revision,
                        publishedRevisionId = (long?)s.published_revision_id, contentHash = (string?)s.content_hash,
                        mtimeNs = (long?)s.mtime, sizeBytes = (long?)s.size_bytes, error = (string?)s.error
                    }).OrderBy(s => s.id).ToArray(),
                    revisions = c.Query("SELECT * FROM source_revisions ORDER BY id").Select(r => new
                    {
                        id = (long)r.id, sourceId = Src((long)r.source_id), canonicalText = (string)r.canonical_text,
                        chunks = c.Query("SELECT text,char_start,char_end FROM source_chunks WHERE revision_id=$id ORDER BY ord",
                            new { id = (long)r.id }).Select(ch => new
                            {
                                text = (string)ch.text, start = (long?)ch.char_start, end = (long?)ch.char_end
                            }).ToArray()
                    }).ToArray(),
                    inventory = c.Query("SELECT * FROM scan_items ORDER BY CAST(rel_path AS BLOB)").Select(i => new
                    {
                        folderId = (long)i.folder_id, relPath = (string)i.rel_path, kind = (string)i.kind,
                        skipReason = (string?)i.skip_reason, mtimeNs = (long?)i.mtime, sizeBytes = (long?)i.size_bytes,
                        seenGeneration = (long)i.seen_generation
                    }).ToArray(),
                    jobs = c.Query("SELECT * FROM ingest_jobs ORDER BY id").Select(j => new
                    {
                        id = _jobs.TryGetValue((long)j.id, out long fixture) ? fixture : -(long)j.id,
                        kind = (string)j.kind, target = Target((string)j.target), targetRevision = (long?)j.target_revision,
                        state = (string)j.state, attempts = (long)j.attempts, leaseToken = (string?)j.lease_token,
                        leaseUntil = (long?)j.lease_until
                    }).OrderBy(j => j.id).ToArray(),
                    readCalls = _readCalls,
                    listCalls = _listCalls.ToArray()
                };
                return JsonSerializer.SerializeToElement(projection);
            }
        }

        private static void Bind(Dictionary<long, long> map, IEnumerable<long> actual, IEnumerable<long> expected)
        {
            var free = new Queue<long>(expected.Where(id => !map.ContainsValue(id)).Order());
            foreach (long id in actual.Order())
                if (!map.ContainsKey(id) && free.Count > 0) map[id] = free.Dequeue();
        }
    }

    /// <summary>A filesystem scripted from one scan segment: list/deny/stat/read events become native answers.</summary>
    private sealed class EventFS : IFolderFileSystem
    {
        private readonly FolderIdentity _identity;
        private readonly Dictionary<string, FolderEntry[]> _directories = new(StringComparer.Ordinal);
        private readonly Dictionary<string, FileStamp> _stamps = new(StringComparer.Ordinal);
        private readonly Dictionary<string, (FileStamp Stamp, string Hash)> _reads = new(StringComparer.Ordinal);
        private readonly HashSet<string> _denied = new(StringComparer.Ordinal);
        private readonly string? _rootFailure;
        private readonly bool _rootOffline;
        private readonly bool _cancelOnRootList;
        private readonly CancellationTokenSource _cts;
        public int HashCalls { get; private set; }
        public List<string> ListCalls { get; } = [];

        public EventFS(JsonElement row, JsonElement[] segment, CancellationTokenSource cts)
        {
            _cts = cts;
            var root = row.GetProperty("input").GetProperty("root");
            _identity = new FolderIdentity(root.GetProperty("volumeId").GetString()!,
                root.GetProperty("components").EnumerateArray().Select(c => c.GetString()!).ToArray(), root.GetProperty("rootFileId").GetString()!);
            foreach (var e in segment.Where(e => Op(e) == "stat")) _stamps[Str(e, "relPath")!] = Stamp(e.GetProperty("stamp"));
            foreach (var e in segment.Where(e => Op(e) == "read"))
                _reads[Str(e, "relPath")!] = (Stamp(e.GetProperty("stamp")), Str(e, "hash")!);
            foreach (var e in segment)
            {
                switch (Op(e))
                {
                    case "list":
                        _directories[Str(e, "directory")!] = e.GetProperty("entries").EnumerateArray().Select(entry =>
                        {
                            string path = Str(entry, "relPath")!;
                            bool directory = entry.GetProperty("isDirectory").GetBoolean();
                            return new FolderEntry(path, directory, entry.GetProperty("isLink").GetBoolean(),
                                directory ? new FileStamp("dir:" + path, 0, 0) : _stamps[path]);
                        }).ToArray();
                        break;
                    case "deny" when Str(e, "error") == "permissionDenied": _denied.Add(Str(e, "directory")!); break;
                    case "deny": _rootFailure = Str(e, "error"); break;
                    case "rootUnavailable": _rootOffline = true; break;
                    case "cancel": _cancelOnRootList = true; break;
                }
            }
        }

        public FolderIdentity Resolve(string rootPath) => _rootOffline ? throw new UnauthorizedAccessException(rootPath) : _identity;
        public bool CaseSensitive(FolderSource root) => _rootOffline ? throw new UnauthorizedAccessException() : true;

        public IReadOnlyList<FolderEntry> List(FolderSource root, string directory)
        {
            ListCalls.Add(directory);
            if (_denied.Contains(directory)) throw new UnauthorizedAccessException(directory);
            if (directory.Length == 0 && _rootFailure is not null) throw new InvalidOperationException(_rootFailure);
            if (directory.Length == 0 && _cancelOnRootList) _cts.Cancel();
            Assert.True(_directories.ContainsKey(directory), "Unexpected list: " + directory);
            return _directories[directory];
        }

        public FileStamp Stat(FolderSource root, string relativePath) =>
            relativePath.Length == 0 ? new FileStamp(_identity.RootFileId, 0, 0)
            : _stamps.TryGetValue(relativePath, out var stamp) ? stamp : new FileStamp("dir:" + relativePath, 0, 0);

        public FolderRead Hash(FolderSource root, string relativePath, long maxBytes)
        {
            HashCalls++;
            Assert.True(_reads.ContainsKey(relativePath), "Unexpected hash: " + relativePath);
            var (stamp, hash) = _reads[relativePath];
            return new FolderRead([], stamp, hash);
        }

        public FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes)
        { Assert.Fail("Scans never snapshot file bodies"); throw new InvalidOperationException(); }
    }

    /// <summary>Root with flat files; every Hash call is counted.</summary>
    private sealed class MapFS(Dictionary<string, (FileStamp Stamp, string Hash)> files) : IFolderFileSystem
    {
        public int HashCalls { get; private set; }
        public FolderIdentity Resolve(string rootPath) => new Identity().Resolve(rootPath);
        public bool CaseSensitive(FolderSource root) => true;
        public IReadOnlyList<FolderEntry> List(FolderSource root, string directory) =>
            files.Select(p => new FolderEntry(p.Key, false, false, p.Value.Stamp)).ToArray();
        public FileStamp Stat(FolderSource root, string relativePath) =>
            relativePath.Length == 0 ? new FileStamp("root-1", 0, 0) : files[relativePath].Stamp;
        public FolderRead Hash(FolderSource root, string relativePath, long maxBytes)
        {
            HashCalls++;
            return new FolderRead([], files[relativePath].Stamp, files[relativePath].Hash);
        }
        public FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes) => throw new InvalidOperationException();
    }

    /// <summary>Rule application consults only the case policy; any other filesystem call is a bug.</summary>
    private sealed class RulesOnlyFS : IFolderFileSystem
    {
        public FolderIdentity Resolve(string rootPath) => throw new InvalidOperationException("no filesystem access");
        public bool CaseSensitive(FolderSource root) => true;
        public IReadOnlyList<FolderEntry> List(FolderSource root, string directory) => throw new InvalidOperationException();
        public FileStamp Stat(FolderSource root, string relativePath) => throw new InvalidOperationException();
        public FolderRead Hash(FolderSource root, string relativePath, long maxBytes) => throw new InvalidOperationException();
        public FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes) => throw new InvalidOperationException();
    }

    private sealed class FixedIdentity(FolderIdentity identity) : IFolderPathIdentity
    {
        public FolderIdentity Resolve(string rootPath) => identity;
    }

    private sealed class TestClock(long now) : IIngestLeaseClock
    {
        public long Now => now;
        public Task WaitUntilAsync(long deadline, CancellationToken ct) => Task.CompletedTask;
    }

    private static JsonElement[] ScanCases()
    {
        var fixture = SharedFixtures.Json("contracts/ingestion-scan-v1.json");
        Assert.Equal("ingestion-scan", fixture.GetProperty("contract").GetString());
        return fixture.GetProperty("cases").EnumerateArray().ToArray();
    }

    private static string Name(JsonElement row) => row.GetProperty("name").GetString()!;
    private static string Op(JsonElement row) => row.GetProperty("operation").GetString()!;
    private static bool Bool(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.True;
    private static string? Str(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    private static long? Long(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : null;
    private static string[] Strings(JsonElement e, string key) => e.GetProperty(key).EnumerateArray().Select(x => x.GetString()!).ToArray();
    private static long[] Longs(JsonElement e, string key) => e.GetProperty(key).EnumerateArray().Select(x => x.GetInt64()).ToArray();
    private static FileStamp Stamp(JsonElement e) =>
        new(e.GetProperty("identity").GetString()!, e.GetProperty("mtimeNs").GetInt64(), e.GetProperty("sizeBytes").GetInt64());

    private static void AssertJson(JsonElement expected, JsonElement actual, string path)
    {
        if (expected.ValueKind == JsonValueKind.Number)
        {
            Assert.True(actual.ValueKind == JsonValueKind.Number, $"{path}: expected {expected} got {actual}");
            Assert.True(expected.GetInt64() == actual.GetInt64(), $"{path}: expected {expected} got {actual}");
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

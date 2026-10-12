using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

public sealed class FolderGenerationTests
{
    private static readonly string LocalRevision = Hex(Encoding.UTF8.GetBytes("ollama\nhttp://localhost:11434"));

    [Fact]
    public void ReindexDoesNotActivateEmptyBuild()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        long nb = store.CreateNotebook("index").Id!.Value;
        var identity = new GenerationIdentity("local", "1", "m", null, 2, "l2", "1", "1", "2");
        long id = store.RequestReindex(nb, identity, 0);
        Assert.Equal("building", store.Generation(id)!.State);
        Assert.Null(store.ActiveGeneration(nb));
        Assert.Equal(id, store.GenerationProgress(nb).GenerationId);
    }

    [Fact]
    public void ReindexLeavesActiveRevisionAndVectorsAvailable()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long nb = store.CreateNotebook("active").Id!.Value;
        long sid = store.CreateSource(nb, SourceType.Text, "doc", null, null).Id!.Value;
        var revision = store.CommitForegroundRevision(sid, new RevisionDraft("h", "kept", 1, 2), ScalarChunker.Chunk("kept"), 0, "seed");
        var identity = new GenerationIdentity("local", "1", "m", null, 2, "l2", "1", "1", "2");
        var active = store.CreateGeneration(nb, identity, 0);
        store.SetManifest(active.Id, new[] { new ManifestEntry(sid, revision.Id, "pending", null) });
        var chunk = Assert.Single(store.Chunks(sid));
        store.StoreGenerationEmbedding(active.Id, chunk.Id!.Value, new EmbeddingVector(new float[] { 1, 0 }));
        store.SetManifest(active.Id, new[] { new ManifestEntry(sid, revision.Id, "done", null) });
        store.ActivateGeneration(active.Id, 1);
        long build = store.RequestReindex(nb, identity, 2);
        Assert.NotEqual(active.Id, build);
        Assert.Equal(active.Id, store.ActiveGeneration(nb)!.Id);
        Assert.Equal(revision.Id, Assert.Single(store.Manifest(active.Id)).RevisionId);
        Assert.Equal(new[] { "kept" }, store.Chunks(sid).Select(c => c.Text));
        store.DiscardBuildingGeneration(build, 3);
        Assert.Equal(active.Id, store.ActiveGeneration(nb)!.Id);
        Assert.Equal(revision.Id, store.Source(sid)!.PublishedRevisionId);
    }

    [Fact]
    public async Task AllGenerationFixtures()
    {
        var all = SharedFixtures.Json("contracts/ingestion-generations-v1.json");
        Assert.Equal("ingestion-generations", all.GetProperty("contract").GetString());
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in all.GetProperty("cases").EnumerateArray())
        {
            Assert.True(names.Add(Name(row)));
            await Run(row);
        }
        Assert.Equal(36, names.Count);
    }

    [Fact]
    public async Task StaleBatchAndActivationFence()
    {
        foreach (string name in new[] { "stale-batch", "lease-lost-batch", "ingest-during-build", "bootstrap-stale-fence",
            "bootstrap-all-revisions-stale", "activate-atomic", "unknown-dimensions-bootstrap", "empty-bootstrap" })
            await Run(Case(name));

        // The real worker loop: unknown dimensions bootstrap, then build and atomic activation, against a fake provider.
        using var world = new World();
        world.SeedCorpus(("first", "alpha"), ("second", "beta"));
        var provider = new FakeProvider();
        var selection = world.Session(provider).Selection;
        long job = world.Store.RequestEmbeddingBuild(world.Notebook, selection, false, 0);
        Assert.Equal($"notebook:{world.Notebook}", world.Store.Job(job)!.Draft.Target);
        Assert.True(await world.Queue("embed-a").RunOneAsync("embed", 0, (j, f, ct) => world.Coordinator(provider, selection).ExecuteAsync(j, f, ct)));
        var active = world.Store.ActiveGeneration(world.Notebook)!;
        Assert.Equal(2, active.Identity.Dims);
        Assert.Equal(selection.EndpointRevision, active.Identity.EndpointRevision);
        Assert.Equal("done", world.Store.Job(job)!.State);
        Assert.Equal($"generation:{active.Id}", world.Store.Job(job)!.Draft.Target);
        Assert.All(provider.Requests, r => Assert.Equal("http://localhost:11434/api/embed", r.Url));
        Assert.Equal(new[] { "alpha", "beta" }, provider.Requests.Single().Inputs);
        Assert.All(world.Store.Manifest(active.Id), e => Assert.Equal("done", e.State));
        // A stale fence can neither commit nor activate.
        Assert.False(world.Store.CommitEmbeddingBatch(active.Id, [], [], [], new JobFence(job, "embed-a"), 5));
        Assert.False(world.Store.ActivateBuiltGeneration(active.Id, active.Identity, new JobFence(job, "embed-a"), 5));
    }

    [Fact]
    public async Task ChatPausesOnlyNextBatch()
    {
        await Run(Case("chat-pause-between-batches"));

        using var world = new World();
        world.SeedCorpus(("first", "alpha"), ("second", "beta"));
        var provider = new FakeProvider();
        var selection = world.Session(provider).Selection with { Dims = 2 };
        long job = world.Store.RequestEmbeddingBuild(world.Notebook, selection, false, 0);
        var coordinator = world.Coordinator(provider, selection, batchSize: 1);
        var chat = world.Admission.BeginChat();
        var run = world.Queue("embed-a").RunOneAsync("embed", 0, (j, f, ct) => coordinator.ExecuteAsync(j, f, ct));
        await WaitUntil(() => coordinator.ProgressAsync(world.Notebook).Result.PausedForChat);
        Assert.Empty(provider.Requests);
        // Question embeddings are never gated by chat.
        var question = await world.Session(provider).EmbedAsync(["question"]);
        Assert.Single(provider.Requests);
        Assert.Equal("running", world.Store.Job(job)!.State);
        Assert.Equal("building", world.Store.Generation(world.Store.GenerationProgress(world.Notebook).GenerationId!.Value)!.State);
        world.Admission.EndChat(chat);
        Assert.True(await run);
        Assert.Equal(3, provider.Requests.Count);
        Assert.Equal(new[] { "alpha" }, provider.Requests[1].Inputs);
        Assert.Equal(new[] { "beta" }, provider.Requests[2].Inputs);
        Assert.NotNull(world.Store.ActiveGeneration(world.Notebook));
        Assert.False((await coordinator.ProgressAsync(world.Notebook)).PausedForChat);
        Assert.Equal(2, question[0].Length);
    }

    [Fact]
    public async Task RestartAndPeriodicReconcile()
    {
        foreach (string name in new[] { "restart-resumes", "periodic-1800", "watch-disabled-startup" })
            await Run(Case(name));

        // Startup repairs an abandoned scan to partial without missing-marking and never touches last_full_scan_at.
        using var world = new World();
        long sourceId = world.SeedCorpus(("kept", "alpha"))[0];
        lock (world.Store.Gate)
            world.Store.Connection.Execute("UPDATE folder_sources SET scan_state='scanning',scan_generation=4 WHERE id=$id", new { id = world.Folder });
        var clock = new ManualClock(100);
        var requested = new List<(long, bool)>();
        var reconciler = new FolderReconciler(world.Store, clock, (folder, verify) =>
        {
            requested.Add((folder, verify));
            world.Store.RequestFolderScan(folder, verify, clock.Now);
            return Task.CompletedTask;
        });
        await reconciler.StartAsync();
        await reconciler.StartAsync(); // idempotent
        Assert.Equal(new[] { (world.Folder, false) }, requested);
        var folder = world.Store.Folder(world.Folder)!;
        Assert.Equal(("partial", (long?)null), (folder.ScanState, folder.LastFullScanAt));
        Assert.Equal("present", world.Store.Source(sourceId)!.Availability);
        // The injected clock drives exactly one periodic pass per deadline; the queued scan is coalesced.
        clock.Advance(100 + FolderReconciler.Interval);
        await WaitUntil(() => requested.Count == 2);
        Assert.Single(world.Store.DueJobs("scan", clock.Now, 32));
        await reconciler.StopAsync();
        clock.Advance(100 + 3 * FolderReconciler.Interval);
        Assert.Equal(2, requested.Count);
    }

    [Fact]
    public async Task DiscardAndPrivacyFailure()
    {
        foreach (string name in new[] { "discard-keeps-active", "failed-build-keeps-active", "fifth-embed-failure",
            "selected-provider-changed", "endpoint-changed-between-batches", "model-changed-between-batches",
            "bootstrap-selection-changed-in-flight", "no-api-key-serialization", "captured-endpoint-and-model",
            "key-rotation-same-identity", "chat-only-selection-anthropic", "chat-only-selection-openwebui" })
            await Run(Case(name));

        var unacknowledged = new ProviderConfig("cloud", ProviderType.OpenAICompatible, "Cloud", "https://embedding.example/v1", true, false, DateTime.UnixEpoch);
        Assert.Throws<ProviderConsentException>(() => new FolderEmbeddingSession(unacknowledged, "m", "secret", null, "1", "1", new HttpClient()));
        var disabled = unacknowledged with { Enabled = false, PrivacyAcknowledged = true };
        Assert.Equal("providerDisabled", Assert.Throws<ProviderConfigurationException>(() =>
            new FolderEmbeddingSession(disabled, "m", null, null, "1", "1", new HttpClient())).Code);
        var session = new FolderEmbeddingSession(unacknowledged with { PrivacyAcknowledged = true }, "m", "fixture-secret", null, "1", "1", new HttpClient());
        Assert.DoesNotContain("fixture-secret", session.ToString());
        Assert.DoesNotContain("fixture-secret", JsonSerializer.Serialize(session.Selection));

        // A provider failure during a build keeps the active generation and its vectors readable.
        using var world = new World();
        world.SeedCorpus(("kept", "alpha"));
        var provider = new FakeProvider();
        var selection = world.Session(provider).Selection with { Dims = 2 };
        world.Store.RequestEmbeddingBuild(world.Notebook, selection, false, 0);
        Assert.True(await world.Queue("a").RunOneAsync("embed", 0, (j, f, ct) => world.Coordinator(provider, selection).ExecuteAsync(j, f, ct)));
        var active = world.Store.ActiveGeneration(world.Notebook)!;
        long rebuild = world.Store.RequestEmbeddingBuild(world.Notebook, selection, false, 1);
        provider.Fail = true;
        Assert.True(await world.Queue("b").RunOneAsync("embed", 0, (j, f, ct) => world.Coordinator(provider, selection).ExecuteAsync(j, f, ct)));
        Assert.Equal("failed", world.Store.Job(rebuild)!.State);
        Assert.Equal(active.Id, world.Store.ActiveGeneration(world.Notebook)!.Id);
        var progress = world.Store.GenerationProgress(world.Notebook);
        Assert.True(progress.Failed);
        Assert.True(progress.HasActive);
        Assert.Equal(rebuild, progress.JobId);
        Assert.Equal("providerHttp500", progress.ErrorCode);
        var pin = world.Store.PinQuery(world.Notebook, $"{selection.ProviderId}:{selection.Model}");
        Assert.Single(world.Store.PinnedEmbeddings(pin));
        world.Store.ReleaseQuery(pin);
        // Discarding the failed build's job leaves the active index intact.
        await world.Coordinator(provider, selection).DiscardJobAsync(rebuild);
        Assert.Equal(active.Id, world.Store.ActiveGeneration(world.Notebook)!.Id);
        // A later successful build supersedes the old failure in the progress snapshot.
        provider.Fail = false;
        long retried = world.Store.RequestEmbeddingBuild(world.Notebook, selection, false, 2);
        Assert.True(await world.Queue("c").RunOneAsync("embed", 0, (j, f, ct) => world.Coordinator(provider, selection).ExecuteAsync(j, f, ct)));
        Assert.Equal("done", world.Store.Job(retried)!.State);
        // An older terminally failed build (simulated on the discarded row) must not shadow the newer active index.
        lock (world.Store.Gate)
            world.Store.Connection.Execute("UPDATE index_generations SET state='failed' WHERE state='retired' AND id<>$id",
                new { id = active.Id });
        var settled = world.Store.GenerationProgress(world.Notebook);
        Assert.False(settled.Failed);
        Assert.Null(settled.GenerationId);
        Assert.True(settled.HasActive);
    }

    [Fact]
    public void VerifyAllSurvivesRestart()
    {
        using var dir = new TempDir();
        string path = Path.Combine(dir.Path, "db.sqlite");
        long folder, first, second;
        using (var store = new NotebookStore(new StorePath(path), configuredEmbeddingModelKey: null))
        {
            long nb = store.CreateNotebook("scan").Id!.Value;
            folder = store.CreateFolder(nb, new FolderDraft("/docs", "Docs", ["md"], [], "{}", "cp1250", false),
                new FixedIdentity(new FolderIdentity("v", ["docs"], "r")), 0).Id;
            first = store.RequestFolderScan(folder, false, 1);
            Assert.Equal(first, store.RequestFolderScan(folder, true, 2)); // queued upgrade, not a duplicate
            Assert.True(store.ScanOptions(first));
            Assert.Equal(first, store.RequestFolderScan(folder, false, 3)); // never downgraded
            Assert.True(store.ScanOptions(first));
            Assert.NotNull(store.ClaimJob(4, "scan-a", first));
            // A running scan gets exactly one queued successor with the requested mode.
            second = store.RequestFolderScan(folder, false, 5);
            Assert.NotEqual(first, second);
            Assert.Equal(second, store.RequestFolderScan(folder, true, 6));
            Assert.Empty(store.WatchedFolders());
        }
        using (var reopened = new NotebookStore(new StorePath(path), configuredEmbeddingModelKey: null))
        {
            Assert.True(reopened.ScanOptions(first));
            Assert.True(reopened.ScanOptions(second));
            Assert.Equal("{\"verifyAll\":true}", reopened.Job(second)!.Draft.OptionsJson);
            // Options are frozen once claimed.
            Assert.False(reopened.CoalesceQueuedJobOptions(first, "{\"verifyAll\":false}"));
            Assert.True(reopened.ScanOptions(first));
        }
    }

    [Fact]
    public async Task PinnedOldRevisionSurvives()
    {
        foreach (string name in new[] { "pin-keeps-old-vectors", "scope-revocation", "lexical-only" })
            await Run(Case(name));

        using var world = new World();
        long source = world.SeedCorpus(("kept", "alpha"))[0];
        var provider = new FakeProvider();
        var selection = world.Session(provider).Selection with { Dims = 2 };
        world.Store.RequestEmbeddingBuild(world.Notebook, selection, false, 0);
        Assert.True(await world.Queue("a").RunOneAsync("embed", 0, (j, f, ct) => world.Coordinator(provider, selection).ExecuteAsync(j, f, ct)));
        long oldRevision = world.Store.Source(source)!.PublishedRevisionId!.Value;
        var pin = world.Store.PinQuery(world.Notebook, $"{selection.ProviderId}:{selection.Model}");
        world.Store.CommitForegroundRevision(source, new RevisionDraft("h2", "gamma", 1, 2), ScalarChunker.Chunk("gamma"), 10, "refresh");
        world.Store.GarbageCollect(world.Notebook);
        Assert.Equal("alpha", world.Store.Revision(oldRevision)!.Draft.CanonicalText);
        Assert.Equal(oldRevision, pin.VectorRevisions[source]);
        Assert.Single(world.Store.PinnedEmbeddings(pin));
        world.Store.ReleaseQuery(pin);
    }

    // ---------------------------------------------------------------- shared fixture dispatch

    private static async Task Run(JsonElement row)
    {
        switch (Op(row))
        {
            case "generation":
                using (var harness = new GenerationHarness(row)) await harness.ReplayAsync();
                break;
            case "reconcile":
                using (var harness = new ReconcileHarness(row)) await harness.ReplayAsync();
                break;
            case "embedding-session":
                await ReplaySessionAsync(row);
                break;
            default:
                Assert.Fail("Unknown generation fixture operation " + Op(row));
                break;
        }
    }

    private sealed class GenerationHarness : IDisposable
    {
        private static readonly string[] Ops = ["request-build", "claim", "begin-batch", "commit-batch", "activate", "publish-revision",
            "recover-expired", "provider-failure", "discard", "pin", "unpin", "gc", "begin-chat", "end-chat", "query-embedding",
            "change-selection", "invalidate-selection", "set-eligibility", "retrieve", "finish-empty", "renew"];
        private readonly JsonElement _row;
        private readonly TempDir _dir = new();
        private readonly string _path;
        private readonly ManualClock _clock = new(0);
        private readonly IngestionAdmission _admission = new();
        private readonly Dictionary<string, Dictionary<long, long>> _ids = new()
        {
            ["jobs"] = new(), ["generations"] = new(), ["chunks"] = new()
        };
        private readonly Dictionary<string, Guid> _chat = new(StringComparer.Ordinal);
        private readonly List<JsonObject> _inFlight = [];
        private readonly List<JsonObject> _requests = [];
        private readonly Dictionary<string, QueryPin> _pins = new(StringComparer.Ordinal);
        private readonly int _batchSize;
        private JsonElement? _selected;
        private JsonNode? _retrieval;
        private int _providerCalls;
        private int _queryCalls;
        private Task? _waitingBatch;
        private NotebookStore _store;
        private FolderIndexCoordinator _coordinator;

        public GenerationHarness(JsonElement row)
        {
            _row = row;
            var input = row.GetProperty("input");
            Assert.Equal("epoch-seconds", input.GetProperty("clockUnit").GetString());
            _batchSize = input.GetProperty("batchSize").GetInt32();
            Assert.Contains(_batchSize, new[] { 1, FolderIndexCoordinator.DefaultBatchSize });
            _path = Path.Combine(_dir.Path, "db.sqlite");
            _store = new NotebookStore(new StorePath(_path), configuredEmbeddingModelKey: null);
            var seed = input.GetProperty("seed");
            foreach (var nb in input.GetProperty("notebookIds").EnumerateArray()) Assert.Equal(nb.GetInt64(), _store.CreateNotebook("gen").Id);
            foreach (var folder in input.GetProperty("folderIds").EnumerateArray())
                Assert.Equal(folder.GetInt64(), _store.CreateFolder(1, new FolderDraft($"/f{folder}", "F", ["md"], [], "{}", "cp1250", true),
                    new FixedIdentity(new FolderIdentity("v", [$"f{folder}"], "r")), 0).Id);
            lock (_store.Gate)
            {
                var c = _store.Connection;
                using var tx = c.BeginTransaction();
                foreach (var s in seed.GetProperty("sources").EnumerateArray())
                    c.Execute("""
                        INSERT INTO sources(id,notebook_id,type,title,status,ingested_at,folder_id,rel_path,mtime,size_bytes,availability,eligible)
                        VALUES($id,$nb,'text','s',$status,'2026-01-01 00:00:00.000',$folder,$path,10,5,$availability,$eligible)
                        """, new
                    {
                        id = s.GetProperty("id").GetInt64(), nb = s.GetProperty("notebookId").GetInt64(), status = Str(s, "status"),
                        folder = Long(s, "folderId"), path = $"s{s.GetProperty("id").GetInt64()}.md", availability = Str(s, "availability"),
                        eligible = s.GetProperty("eligible").GetBoolean()
                    }, tx);
                foreach (var r in seed.GetProperty("revisions").EnumerateArray())
                {
                    c.Execute("""
                        INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                        VALUES($id,$source,$id,'h',$text,$format,$chunker,'2026-01-01 00:00:00.000')
                        """, new
                    {
                        id = r.GetProperty("id").GetInt64(), source = r.GetProperty("sourceId").GetInt64(), text = Str(r, "canonicalText"),
                        format = r.GetProperty("textFormatVersion").GetInt64(), chunker = r.GetProperty("chunkerVersion").GetInt64()
                    }, tx);
                    int ord = 0;
                    foreach (var ch in r.GetProperty("chunks").EnumerateArray())
                    {
                        _ids["chunks"][ch.GetProperty("id").GetInt64()] = ch.GetProperty("id").GetInt64();
                        c.Execute("""
                            INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count,char_start,char_end)
                            VALUES($id,$source,$revision,$ord,$text,$tokens,$start,$end)
                            """, new
                        {
                            id = ch.GetProperty("id").GetInt64(), source = r.GetProperty("sourceId").GetInt64(), revision = r.GetProperty("id").GetInt64(),
                            ord = ord++, text = Str(ch, "text"), tokens = ch.GetProperty("tokenCount").GetInt64(),
                            start = ch.GetProperty("start").GetInt64(), end = ch.GetProperty("end").GetInt64()
                        }, tx);
                    }
                }
                foreach (var s in seed.GetProperty("sources").EnumerateArray())
                    c.Execute("UPDATE sources SET current_revision=$current,published_revision_id=$published WHERE id=$id", new
                    {
                        id = s.GetProperty("id").GetInt64(), current = Long(s, "currentRevision"), published = Long(s, "publishedRevisionId")
                    }, tx);
                foreach (var g in seed.GetProperty("generations").EnumerateArray())
                {
                    long id = g.GetProperty("id").GetInt64();
                    _ids["generations"][id] = id;
                    var identity = g.GetProperty("identity");
                    c.Execute("""
                        INSERT INTO index_generations(id,notebook_id,provider_id,endpoint_revision,model,model_digest,dims,normalization,
                            query_format_version,doc_format_version,chunker_version,state,created_at,activated_at)
                        VALUES($id,$nb,$provider,$endpoint,$model,$digest,$dims,$normalization,$qfv,$dfv,$chunker,$state,
                            '2026-01-01 00:00:00.000',CASE WHEN $state='active' THEN '2026-01-01 00:00:00.000' END)
                        """, new
                    {
                        id, nb = g.GetProperty("notebookId").GetInt64(), provider = Str(identity, "providerId"),
                        endpoint = Str(identity, "endpointRevision"), model = Str(identity, "model"), digest = Str(identity, "modelDigest"),
                        dims = identity.GetProperty("dims").GetInt64(), normalization = Str(identity, "normalization"),
                        qfv = Str(identity, "queryFormatVersion"), dfv = Str(identity, "docFormatVersion"), chunker = Str(identity, "chunkerVersion"),
                        state = Str(g, "state")
                    }, tx);
                    foreach (var m in g.GetProperty("manifest").EnumerateArray())
                        c.Execute("""
                            INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state,reason) VALUES($id,$source,$revision,$state,$reason)
                            """, new
                        {
                            id, source = m.GetProperty("sourceId").GetInt64(), revision = m.GetProperty("revisionId").GetInt64(),
                            state = Str(m, "state"), reason = Str(m, "reason")
                        }, tx);
                    foreach (var v in g.GetProperty("vectors").EnumerateArray())
                        c.Execute("INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES($chunk,$id,$bytes)", new
                        {
                            chunk = v.GetProperty("chunkId").GetInt64(), id,
                            bytes = new EmbeddingVector(v.GetProperty("values").EnumerateArray().Select(x => x.GetSingle()).ToArray()).ToBytes()
                        }, tx);
                }
                foreach (var j in seed.GetProperty("jobs").EnumerateArray())
                {
                    _ids["jobs"][j.GetProperty("id").GetInt64()] = j.GetProperty("id").GetInt64();
                    InsertJob(c, tx, j, MapTargetToActual(Str(j, "target")!));
                }
                tx.Commit();
            }
            _selected = seed.GetProperty("selectedSelection").ValueKind == JsonValueKind.Null ? null : seed.GetProperty("selectedSelection").Clone();
            foreach (var token in seed.GetProperty("chatTokens").EnumerateArray()) _chat[token.GetString()!] = _admission.BeginChat();
            foreach (var b in seed.GetProperty("inFlightBatches").EnumerateArray()) _inFlight.Add(JsonNode.Parse(b.GetRawText())!.AsObject());
            foreach (var b in seed.GetProperty("providerRequests").EnumerateArray()) _requests.Add(JsonNode.Parse(b.GetRawText())!.AsObject());
            _providerCalls = seed.GetProperty("providerCallCount").GetInt32();
            _queryCalls = seed.GetProperty("queryProviderCallCount").GetInt32();
            _retrieval = seed.GetProperty("retrieval").ValueKind == JsonValueKind.Null ? null : JsonNode.Parse(seed.GetProperty("retrieval").GetRawText());
            Assert.Equal(0, seed.GetProperty("pins").GetArrayLength());
            _coordinator = NewCoordinator();
            AssertJson(Normalize(seed), Project(seed), Name(row) + " seed");
        }

        private FolderIndexCoordinator NewCoordinator() => new(_store, _admission, _clock,
            (_, _) => Task.FromResult<FolderEmbeddingSession?>(null), _ => Task.FromResult(Selected())) { BatchSize = _batchSize };

        private EmbeddingSelection? Selected() => _selected is JsonElement value ? Selection(value) : null;

        public void Dispose()
        {
            foreach (var pin in _pins.Values) _store.ReleaseQuery(pin);
            _store.Dispose();
            _dir.Dispose();
        }

        public async Task ReplayAsync()
        {
            int index = 0;
            foreach (var e in Events(_row))
            {
                string op = Op(e);
                Assert.Contains(op, Ops);
                long at = e.GetProperty("at").GetInt64();
                _clock.Advance(at);
                switch (op)
                {
                    case "request-build":
                        long job = _store.RequestEmbeddingBuild(e.GetProperty("notebookId").GetInt64(), Selection(e.GetProperty("selection")),
                            e.GetProperty("copyExisting").GetBoolean(), at);
                        _ids["jobs"][job] = e.GetProperty("jobId").GetInt64();
                        break;
                    case "claim":
                        _store.ClaimJob(at, Str(e, "leaseToken")!, Actual("jobs", e.GetProperty("jobId").GetInt64()));
                        break;
                    case "begin-batch":
                        var current = _store.Job(Actual("jobs", e.GetProperty("jobId").GetInt64()))!;
                        var batch = _coordinator.SelectBatch(current);
                        Assert.Equal(Longs(e, "chunkIds"), batch.Select(item => Fixture("chunks", item.ChunkId)));
                        Assert.Equal(Longs(e, "revisionIds"), batch.Select(item => item.RevisionId));
                        var gate = _waitingBatch is { IsCompletedSuccessfully: true } ? Task.CompletedTask : _admission.WaitForBackgroundBatchAsync();
                        _waitingBatch = null;
                        if (!gate.IsCompletedSuccessfully)
                        {
                            _waitingBatch = gate; // Chat holds the next background batch; nothing is sent.
                            break;
                        }
                        var options = IngestionGenerationSQL.ReadOptions(current.Draft.OptionsJson)!;
                        var request = Request(Str(e, "batchId")!, "background", options.Selection, Longs(e, "chunkIds"), Longs(e, "revisionIds"),
                            batch.Select(item => item.Text).ToArray());
                        _inFlight.Add(request);
                        _requests.Add((JsonObject)request.DeepClone());
                        _providerCalls++;
                        break;
                    case "commit-batch":
                        var sent = _inFlight.Single(b => (string?)b["batchId"] == Str(e, "batchId"));
                        _inFlight.Remove(sent);
                        var items = sent["chunkIds"]!.AsArray().Select((chunk, i) => new FolderEmbeddingItem(Actual("chunks", (long)chunk!),
                            (long)sent["revisionIds"]![i]!, 0, (string)sent["inputs"]![i]!)).ToArray();
                        var vectors = e.GetProperty("vectors").EnumerateArray().Select(v => v.EnumerateArray()
                            .Select(x => x.ValueKind == JsonValueKind.String ? (Str2(x) == "NaN" ? float.NaN : throw new InvalidOperationException()) : x.GetSingle())
                            .ToArray()).ToArray();
                        long commitJob = Actual("jobs", e.GetProperty("jobId").GetInt64());
                        await _coordinator.CommitBatchAsync(_store.Job(commitJob)!, new JobFence(commitJob, Str(e, "leaseToken")!), items, vectors);
                        break;
                    case "activate":
                        long activateJob = Actual("jobs", e.GetProperty("jobId").GetInt64());
                        await _coordinator.FinishOrActivateAsync(_store.Job(activateJob)!, new JobFence(activateJob, Str(e, "leaseToken")!));
                        break;
                    case "finish-empty":
                        long emptyJob = Actual("jobs", e.GetProperty("jobId").GetInt64());
                        Assert.Empty(_coordinator.SelectBatch(_store.Job(emptyJob)!));
                        Assert.True(await _coordinator.FinishOrActivateAsync(_store.Job(emptyJob)!, new JobFence(emptyJob, Str(e, "leaseToken")!)));
                        break;
                    case "publish-revision":
                        var revision = e.GetProperty("revision");
                        long sourceId = e.GetProperty("sourceId").GetInt64();
                        Assert.Equal(e.GetProperty("expectedCurrentRevision").GetInt64(), _store.Source(sourceId)!.CurrentRevision);
                        var fence = _store.BeginExtraction(sourceId, at, Str(e, "leaseToken")!);
                        _ids["jobs"][fence.JobId] = e.GetProperty("extractJobId").GetInt64();
                        var request2 = _store.ExtractionRequest(sourceId)!;
                        var chunks = revision.GetProperty("chunks").EnumerateArray().Select(ch => new RevisionChunkDraft(Str(ch, "text")!,
                            ch.GetProperty("tokenCount").GetInt32(), null, ch.GetProperty("start").GetInt32(), ch.GetProperty("end").GetInt32(), null, false)).ToArray();
                        var published = _store.PublishFolderExtraction(request2, new RevisionDraft("h-" + revision.GetProperty("id").GetInt64(),
                            Str(revision, "canonicalText")!, 1, 2), chunks, new PublicationMetadata(null, null, null, "{}", []), Selected(), fence, at);
                        Assert.Equal(revision.GetProperty("id").GetInt64(), published!.Id);
                        break;
                    case "recover-expired":
                        if (Str(e, "process") == "replacement")
                        {
                            _store.Dispose();
                            _store = new NotebookStore(new StorePath(_path), configuredEmbeddingModelKey: null);
                            _coordinator = NewCoordinator();
                        }
                        _store.RecoverExpiredJobs(at);
                        break;
                    case "provider-failure":
                        _inFlight.RemoveAll(b => (string?)b["batchId"] == Str(e, "batchId"));
                        long failing = Actual("jobs", e.GetProperty("jobId").GetInt64());
                        _store.FailEmbeddingJob(new JobFence(failing, Str(e, "leaseToken")!), Str(e, "error")!, at);
                        break;
                    case "discard":
                        await _coordinator.DiscardAsync(Actual("generations", e.GetProperty("generationId").GetInt64()));
                        break;
                    case "pin":
                        var pin = _store.PinQuery(1, ModelKey());
                        Assert.Equal(Actual("generations", e.GetProperty("generationId").GetInt64()), pin.GenerationId);
                        _pins[Str(e, "token")!] = pin;
                        break;
                    case "unpin":
                        _store.ReleaseQuery(_pins[Str(e, "token")!]);
                        _pins.Remove(Str(e, "token")!);
                        break;
                    case "gc":
                        _store.GarbageCollect(1);
                        break;
                    case "begin-chat":
                        _chat[Str(e, "token")!] = _admission.BeginChat();
                        break;
                    case "end-chat":
                        _admission.EndChat(_chat[Str(e, "token")!]);
                        _chat.Remove(Str(e, "token")!);
                        break;
                    case "query-embedding":
                        // A question embedding is never gated by the chat/background admission.
                        _requests.Add(Request(Str(e, "batchId")!, "query", Selected()!, [], [], [Str(e, "text")!]));
                        _providerCalls++;
                        _queryCalls++;
                        break;
                    case "change-selection":
                        _selected = e.GetProperty("selection").Clone();
                        break;
                    case "invalidate-selection":
                        long invalid = Actual("jobs", e.GetProperty("jobId").GetInt64());
                        Assert.True(_store.InvalidateEmbeddingSelection(new JobFence(invalid, Str(e, "leaseToken")!), at));
                        break;
                    case "set-eligibility":
                        lock (_store.Gate)
                            _store.Connection.Execute("UPDATE sources SET eligible=$eligible WHERE id=$id",
                                new { id = e.GetProperty("sourceId").GetInt64(), eligible = e.GetProperty("eligible").GetBoolean() });
                        break;
                    case "retrieve":
                        Assert.Equal("all", e.GetProperty("scope").GetProperty("kind").GetString());
                        var query = _store.PinQuery(e.GetProperty("notebookId").GetInt64(), ModelKey());
                        try
                        {
                            long[] lexical;
                            lock (_store.Gate)
                                lexical = query.LexicalRevisions.Values.SelectMany(r => _store.Connection.Query<long>(
                                    "SELECT id FROM source_chunks WHERE revision_id=$r ORDER BY ord", new { r })).Order().ToArray();
                            _retrieval = JsonSerializer.SerializeToNode(new
                            {
                                lexicalChunkIds = lexical.Select(id => Fixture("chunks", id)).ToArray(),
                                vectorChunkIds = _store.PinnedEmbeddings(query).Select(v => Fixture("chunks", v.ChunkId)).Order().ToArray(),
                                sourceRevisionPairs = query.LexicalRevisions.OrderBy(p => p.Key).Select(p => new { sourceId = p.Key, revisionId = p.Value }).ToArray()
                            });
                        }
                        finally { _store.ReleaseQuery(query); }
                        break;
                    case "renew":
                        long renewJob = Actual("jobs", e.GetProperty("jobId").GetInt64());
                        Assert.True(_store.RenewJob(new JobFence(renewJob, Str(e, "leaseToken")!), at));
                        break;
                }
                var expected = Normalize(e.GetProperty("expected"));
                AssertJson(expected, Project(expected), $"{Name(_row)} event {index++} ({op})");
            }
            AssertJson(Normalize(_row.GetProperty("expected")), Project(_row.GetProperty("expected")), Name(_row) + " final");
        }

        /// <summary>Fixture traces append revisions in creation order; the projection lists them by ID.</summary>
        private static JsonElement Normalize(JsonElement expected)
        {
            var node = JsonNode.Parse(expected.GetRawText())!;
            var revisions = node["revisions"]!.AsArray().Select(r => r!.DeepClone()).OrderBy(r => (long)r["id"]!).ToArray();
            node["revisions"] = new JsonArray(revisions);
            return JsonSerializer.SerializeToElement(node);
        }

        private string ModelKey() => Selected() is { } selection ? selection.ProviderId + ":" + selection.Model : "";

        private static JsonObject Request(string batchId, string kind, EmbeddingSelection selection, long[] chunkIds, long[] revisionIds, string[] inputs)
        {
            Assert.Equal(LocalRevision, selection.EndpointRevision);
            return JsonSerializer.SerializeToNode(new
            {
                batchId, kind, providerId = selection.ProviderId, endpointRevision = selection.EndpointRevision, model = selection.Model,
                url = "http://localhost:11434/api/embed", chunkIds, revisionIds, inputs
            })!.AsObject();
        }

        private long Actual(string table, long fixture) => _ids[table].Single(p => p.Value == fixture).Key;
        private long Fixture(string table, long actual) => _ids[table].TryGetValue(actual, out long f) ? f : -actual;

        private string MapTargetToActual(string target) => target;

        private void Bind(string table, IEnumerable<long> actual, IEnumerable<long> expected)
        {
            var map = _ids[table];
            var free = new Queue<long>(expected.Where(id => !map.ContainsValue(id)).Distinct().Order());
            foreach (long id in actual.Order())
                if (!map.ContainsKey(id) && free.Count > 0) map[id] = free.Dequeue();
        }

        private JsonElement Project(JsonElement expected)
        {
            lock (_store.Gate)
            {
                var c = _store.Connection;
                Bind("generations", c.Query<long>("SELECT id FROM index_generations"),
                    expected.GetProperty("generations").EnumerateArray().Select(g => g.GetProperty("id").GetInt64()));
                Bind("jobs", c.Query<long>("SELECT id FROM ingest_jobs"), expected.GetProperty("jobs").EnumerateArray().Select(j => j.GetProperty("id").GetInt64()));
                Bind("chunks", c.Query<long>("SELECT id FROM source_chunks"), expected.GetProperty("revisions").EnumerateArray()
                    .SelectMany(r => r.GetProperty("chunks").EnumerateArray().Select(ch => ch.GetProperty("id").GetInt64())));
                string Target(string target) => target.StartsWith("generation:", StringComparison.Ordinal)
                    ? "generation:" + Fixture("generations", long.Parse(target["generation:".Length..])) : target;
                long? active = c.QuerySingleOrDefault<long?>("SELECT id FROM index_generations WHERE notebook_id=1 AND state='active'");
                var state = new
                {
                    activeGenerationId = active is long a ? Fixture("generations", a) : (long?)null,
                    selectedSelection = _selected,
                    sources = c.Query("SELECT * FROM sources ORDER BY id").Select(s => new
                    {
                        availability = (string)s.availability, currentRevision = (long?)s.current_revision, eligible = (long)s.eligible != 0,
                        folderId = (long?)s.folder_id, id = (long)s.id, notebookId = (long)s.notebook_id,
                        publishedRevisionId = (long?)s.published_revision_id, status = (string)s.status
                    }).ToArray(),
                    revisions = c.Query("SELECT * FROM source_revisions ORDER BY id").Select(r => new
                    {
                        canonicalText = (string)r.canonical_text, chunkerVersion = (long)r.chunker_version, id = (long)r.id,
                        sourceId = (long)r.source_id, textFormatVersion = (long)r.text_format_version,
                        chunks = c.Query("SELECT * FROM source_chunks WHERE revision_id=$id ORDER BY ord", new { id = (long)r.id }).Select(ch => new
                        {
                            end = (long?)ch.char_end, id = Fixture("chunks", (long)ch.id), start = (long?)ch.char_start, text = (string)ch.text,
                            tokenCount = (long)ch.token_count
                        }).ToArray()
                    }).ToArray(),
                    generations = c.Query<long>("SELECT id FROM index_generations ORDER BY id").Select(id =>
                    {
                        var g = GenerationSQL.Read(c, null, id)!;
                        var manifest = GenerationSQL.ReadManifest(c, null, id);
                        return new
                        {
                            id = Fixture("generations", id), notebookId = g.NotebookId, state = g.State,
                            identity = new
                            {
                                chunkerVersion = g.Identity.ChunkerVersion, dims = g.Identity.Dims, docFormatVersion = g.Identity.DocFormatVersion,
                                endpointRevision = g.Identity.EndpointRevision, model = g.Identity.Model, modelDigest = g.Identity.ModelDigest,
                                normalization = g.Identity.Normalization, providerId = g.Identity.ProviderId, queryFormatVersion = g.Identity.QueryFormatVersion
                            },
                            manifest = manifest.Select(m => new { reason = m.Reason, revisionId = m.RevisionId, sourceId = m.SourceId, state = m.State }).ToArray(),
                            // Vectors attached to this generation's manifest revisions (stale rows are unreachable garbage).
                            vectors = c.Query("""
                                SELECT e.chunk_id,ch.revision_id,e.embedding FROM chunk_embeddings e JOIN source_chunks ch ON ch.id=e.chunk_id
                                JOIN index_generation_manifest m ON m.generation_id=e.generation_id AND m.source_id=ch.source_id AND m.revision_id=ch.revision_id
                                WHERE e.generation_id=$id ORDER BY e.chunk_id
                                """, new { id }).Select(v => new
                            {
                                chunkId = Fixture("chunks", (long)v.chunk_id), revisionId = (long)v.revision_id,
                                values = EmbeddingVector.FromBytes((byte[])v.embedding).Values.ToArray()
                            }).ToArray()
                        };
                    }).ToArray(),
                    jobs = c.Query("SELECT * FROM ingest_jobs ORDER BY id").Select(j => new
                    {
                        attempts = (long)j.attempts, error = (string?)j.error, id = Fixture("jobs", (long)j.id), kind = (string)j.kind,
                        leaseToken = (string?)j.lease_token, leaseUntil = (long?)j.lease_until, nextRetryAt = (long?)j.next_retry_at,
                        options = JsonDocument.Parse((string)j.options_json).RootElement.Clone(), state = (string)j.state,
                        target = Target((string)j.target), targetRevision = (long?)j.target_revision
                    }).OrderBy(j => j.id).ToArray(),
                    pins = _pins.Select(p => new
                    {
                        token = p.Key, generationId = p.Value.GenerationId is long g ? Fixture("generations", g) : (long?)null,
                        sourceRevisions = p.Value.VectorRevisions.OrderBy(v => v.Key).Select(v => new { sourceId = v.Key, revisionId = v.Value }).ToArray()
                    }).ToArray(),
                    chatTokens = _admission.ChatTokens.Select(t => _chat.Single(p => p.Value == t).Key).ToArray(),
                    inFlightBatches = _inFlight,
                    providerRequests = _requests,
                    providerCallCount = _providerCalls,
                    queryProviderCallCount = _queryCalls,
                    retrieval = _retrieval
                };
                return JsonSerializer.SerializeToElement(state);
            }
        }

        private static void InsertJob(System.Data.IDbConnection c, System.Data.IDbTransaction tx, JsonElement j, string target) => c.Execute("""
            INSERT INTO ingest_jobs(id,kind,target,target_revision,attempts,next_retry_at,state,lease_until,lease_token,error,options_json)
            VALUES($id,$kind,$target,$revision,$attempts,$retry,$state,$until,$token,$error,$options)
            """, new
        {
            id = j.GetProperty("id").GetInt64(), kind = Str(j, "kind"), target, revision = Long(j, "targetRevision"),
            attempts = j.GetProperty("attempts").GetInt64(), retry = Long(j, "nextRetryAt"), state = Str(j, "state"),
            until = Long(j, "leaseUntil"), token = Str(j, "leaseToken"), error = Str(j, "error"), options = j.GetProperty("options").GetRawText()
        }, tx);
    }

    private sealed class ReconcileHarness : IDisposable
    {
        private readonly JsonElement _row;
        private readonly NotebookStore _store = new(StorePath.InMemory, configuredEmbeddingModelKey: null);
        private readonly ManualClock _clock = new(0);
        private readonly FolderReconciler _reconciler;
        private readonly Dictionary<long, long> _jobs = new();

        public ReconcileHarness(JsonElement row)
        {
            _row = row;
            var input = row.GetProperty("input");
            Assert.Equal("epoch-seconds", input.GetProperty("clockUnit").GetString());
            var seed = input.GetProperty("seed");
            foreach (var nb in seed.GetProperty("notebookIds").EnumerateArray()) Assert.Equal(nb.GetInt64(), _store.CreateNotebook("r").Id);
            foreach (var f in seed.GetProperty("folders").EnumerateArray())
                Assert.Equal(f.GetProperty("id").GetInt64(), _store.CreateFolder(f.GetProperty("notebookId").GetInt64(),
                    new FolderDraft($"/f{f.GetProperty("id").GetInt64()}", "F", ["md"], [], "{}", "cp1250", f.GetProperty("watchEnabled").GetBoolean()),
                    new FixedIdentity(new FolderIdentity("v", [$"f{f.GetProperty("id").GetInt64()}"], "r")), 0).Id);
            Assert.Equal(0, seed.GetProperty("jobs").GetArrayLength());
            Assert.Equal(0, seed.GetProperty("sources").GetArrayLength());
            _reconciler = new FolderReconciler(_store, _clock, (folder, verify) =>
            {
                _store.RequestFolderScan(folder, verify, _clock.Now);
                return Task.CompletedTask;
            });
            AssertJson(seed, Project(seed), Name(row) + " seed");
        }

        public void Dispose()
        {
            _reconciler.StopAsync().GetAwaiter().GetResult();
            _store.Dispose();
        }

        public async Task ReplayAsync()
        {
            int index = 0;
            foreach (var e in Events(_row))
            {
                long at = e.GetProperty("at").GetInt64();
                _clock.Set(at);
                switch (Op(e))
                {
                    case "start": await _reconciler.StartAsync(); break;
                    case "tick": await _reconciler.ReconcileAsync(at); break;
                    case "manual-scan":
                        long manual = _store.RequestFolderScan(e.GetProperty("folderId").GetInt64(), e.GetProperty("verifyAll").GetBoolean(), at);
                        _jobs[manual] = e.GetProperty("jobId").GetInt64();
                        break;
                    case "complete-scan":
                        long job = Actual(e.GetProperty("jobId").GetInt64());
                        Assert.NotNull(_store.ClaimJob(at, Str(e, "leaseToken")!, job));
                        Assert.False(_store.ScanOptions(job));
                        Assert.Equal(0, e.GetProperty("entries").GetArrayLength());
                        var fs = new EmptyFS(_store.Folder(e.GetProperty("folderId").GetInt64())!.Identity);
                        await new FolderScanner(_store, fs, UnicodeTables.LoadBundled(), _clock)
                            .ScanAsync(e.GetProperty("folderId").GetInt64(), false, new JobFence(job, Str(e, "leaseToken")!), at);
                        break;
                    case "stop": await _reconciler.StopAsync(); break;
                    default: Assert.Fail("Unknown reconcile operation " + Op(e)); break;
                }
                AssertJson(e.GetProperty("expected"), Project(e.GetProperty("expected")), $"{Name(_row)} event {index++}");
            }
        }

        private long Actual(long fixture) => _jobs.Single(p => p.Value == fixture).Key;

        private JsonElement Project(JsonElement expected)
        {
            lock (_store.Gate)
            {
                var c = _store.Connection;
                var free = new Queue<long>(expected.GetProperty("jobs").EnumerateArray().Select(j => j.GetProperty("id").GetInt64())
                    .Where(id => !_jobs.ContainsValue(id)).Order());
                foreach (long id in c.Query<long>("SELECT id FROM ingest_jobs ORDER BY id"))
                    if (!_jobs.ContainsKey(id) && free.Count > 0) _jobs[id] = free.Dequeue();
                return JsonSerializer.SerializeToElement(new
                {
                    folders = c.Query("SELECT * FROM folder_sources ORDER BY id").Select(f => new
                    {
                        id = (long)f.id, lastFullScanAt = (long?)f.last_full_scan_at, notebookId = (long)f.notebook_id,
                        scanGeneration = (long)f.scan_generation, scanState = (string)f.scan_state, watchEnabled = (long)f.watch_enabled != 0
                    }).ToArray(),
                    jobs = c.Query("SELECT * FROM ingest_jobs ORDER BY id").Select(j => new
                    {
                        attempts = (long)j.attempts, error = (string?)j.error, id = _jobs.TryGetValue((long)j.id, out long f) ? f : -(long)j.id,
                        kind = (string)j.kind, leaseToken = (string?)j.lease_token, leaseUntil = (long?)j.lease_until,
                        nextRetryAt = (long?)j.next_retry_at, options = JsonDocument.Parse((string)j.options_json).RootElement.Clone(),
                        state = (string)j.state, target = (string)j.target, targetRevision = (long?)j.target_revision
                    }).OrderBy(j => j.id).ToArray(),
                    nextReconcileAt = _reconciler.NextReconcileAt,
                    notebookIds = c.Query<long>("SELECT id FROM notebooks ORDER BY id").ToArray(),
                    providerCallCount = 0,
                    running = _reconciler.Running,
                    sources = c.Query<long>("SELECT id FROM sources").ToArray()
                });
            }
        }
    }

    private static async Task ReplaySessionAsync(JsonElement row)
    {
        var input = row.GetProperty("input");
        var config = input.GetProperty("config");
        var providerConfig = new ProviderConfig(Str(config, "id")!, ProviderTypeExtensions.FromStorageString(Str(config, "type")!), "P",
            Str(config, "baseURL")!, config.GetProperty("enabled").GetBoolean(), config.GetProperty("privacyAcknowledged").GetBoolean(), DateTime.UnixEpoch);
        string model = Str(input, "model")!;
        string? key = Str(input, "apiKey");
        var handler = new CaptureHandler();
        using var http = new HttpClient(handler);
        if (Str(input, "httpClientBaseAddress") is string wrong) http.BaseAddress = new Uri(wrong);
        FolderEmbeddingSession? session = null;
        string? error = null;
        JsonNode? durable = null;
        var expectedSecret = key;
        int index = 0;
        foreach (var e in Events(row))
        {
            switch (Op(e))
            {
                case "capture":
                    try { session = new FolderEmbeddingSession(providerConfig, model, key, Str(input, "modelDigest"), Str(input, "queryFormatVersion")!, Str(input, "docFormatVersion")!, http); }
                    catch (ProviderConfigurationException failure) { error = failure.Code; }
                    break;
                case "mutate-config":
                    // A configuration edit after capture never redirects the captured session.
                    providerConfig = providerConfig with { BaseUrl = Str(e, "baseURL")! };
                    model = Str(e, "model")!;
                    break;
                case "embed":
                    handler.Response = e.GetProperty("responseVectors").Clone();
                    await session!.EmbedAsync(e.GetProperty("inputs").EnumerateArray().Select(x => x.GetString()!).ToArray());
                    break;
                case "serialize":
                    string json = IngestionGenerationSQL.SerializeOptions(session!.Selection, e.GetProperty("copyExisting").GetBoolean());
                    if (expectedSecret is not null) Assert.DoesNotContain(expectedSecret, json);
                    Assert.DoesNotContain(expectedSecret ?? "\u0000", session.ToString());
                    durable = JsonNode.Parse(json);
                    break;
                case "rotate-key":
                    var rotated = new FolderEmbeddingSession(providerConfig, model, Str(e, "apiKey"), Str(input, "modelDigest"),
                        Str(input, "queryFormatVersion")!, Str(input, "docFormatVersion")!, http);
                    Assert.Equal(session!.Selection, rotated.Selection);
                    session = rotated;
                    break;
                default: Assert.Fail("Unknown session operation " + Op(e)); break;
            }
            var projection = JsonSerializer.SerializeToElement(new
            {
                durableOptions = durable,
                error,
                identity = session?.VerifiedIdentity is { } identity ? SelectionNode(IdentitySelection(identity)) : null,
                requests = handler.Requests,
                selection = session is null ? null : SelectionNode(session.Selection)
            });
            AssertJson(e.GetProperty("expected"), projection, $"{Name(row)} event {index++}");
        }
    }

    private static EmbeddingSelection IdentitySelection(GenerationIdentity g) => new(g.ProviderId, g.EndpointRevision, g.Model, g.ModelDigest,
        g.Dims, g.Normalization, g.QueryFormatVersion, g.DocFormatVersion, g.ChunkerVersion);

    private static JsonNode SelectionNode(EmbeddingSelection s) => JsonSerializer.SerializeToNode(s, Camel)!;

    // ---------------------------------------------------------------- end-to-end helpers

    private sealed class World : IDisposable
    {
        public NotebookStore Store { get; } = new(StorePath.InMemory, configuredEmbeddingModelKey: null);
        public IngestionAdmission Admission { get; } = new();
        public ManualClock Clock { get; } = new(0);
        public long Notebook { get; }
        public long Folder { get; }
        private readonly HttpClient _http;

        public World()
        {
            Notebook = Store.CreateNotebook("world").Id!.Value;
            Folder = Store.CreateFolder(Notebook, new FolderDraft("/docs", "Docs", ["md"], [], "{}", "cp1250", true),
                new FixedIdentity(new FolderIdentity("v", ["docs"], "r")), 0).Id;
            _http = new HttpClient(Handler);
        }

        public CaptureHandler Handler { get; } = new();

        public long[] SeedCorpus(params (string Title, string Text)[] documents) => documents.Select(d =>
        {
            long id = Store.CreateSource(Notebook, SourceType.Text, d.Title, null, null).Id!.Value;
            Store.CommitForegroundRevision(id, new RevisionDraft("h-" + d.Title, d.Text, 1, 2), ScalarChunker.Chunk(d.Text), 0, "seed-" + d.Title);
            return id;
        }).ToArray();

        public FolderEmbeddingSession Session(FakeProvider provider)
        {
            Handler.Provider = provider;
            return new FolderEmbeddingSession(new ProviderConfig("local", ProviderType.Ollama, "Local", "http://localhost:11434", true, false, DateTime.UnixEpoch),
                "embed-a", null, null, "1", "1", _http);
        }

        public FolderIndexCoordinator Coordinator(FakeProvider provider, EmbeddingSelection selected, int batchSize = 16) =>
            new(Store, Admission, Clock, (_, _) => Task.FromResult<FolderEmbeddingSession?>(Session(provider)),
                _ => Task.FromResult<EmbeddingSelection?>(selected)) { BatchSize = batchSize };

        public JobQueue Queue(string token) => new(Store, Clock, Admission, () => token);

        public void Dispose()
        {
            _http.Dispose();
            Store.Dispose();
        }
    }

    /// <summary>Deterministic embedding provider: one-hot 2D vectors by input order, or HTTP 500.</summary>
    private sealed class FakeProvider
    {
        public bool Fail { get; set; }
        public List<(string Url, string[] Inputs)> Requests { get; } = [];
    }

    private sealed class CaptureHandler : HttpMessageHandler
    {
        public FakeProvider? Provider { get; set; }
        public JsonElement? Response { get; set; }
        public List<object> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(ct));
            string url = request.RequestUri!.AbsoluteUri;
            string[] inputs = body.RootElement.GetProperty("input").EnumerateArray().Select(x => x.GetString()!).ToArray();
            if (Provider is { } provider)
            {
                lock (provider) provider.Requests.Add((url, inputs));
                if (provider.Fail) return new HttpResponseMessage(HttpStatusCode.InternalServerError) { Content = new StringContent("{}") };
                var vectors = inputs.Select((_, i) => i % 2 == 0 ? new[] { 1.0, 0.0 } : new[] { 0.0, 1.0 }).ToArray();
                return Json(new { embeddings = vectors });
            }
            Requests.Add(new
            {
                authorization = request.Headers.Authorization?.ToString(), inputs,
                model = body.RootElement.GetProperty("model").GetString(), url
            });
            var data = Response!.Value.EnumerateArray().Select(v => new { embedding = v.EnumerateArray().Select(x => x.GetDouble()).ToArray() }).ToArray();
            return Json(new { data });
        }

        private static HttpResponseMessage Json(object value) =>
            new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(value), Encoding.UTF8, "application/json") };
    }

    private sealed class EmptyFS(FolderIdentity identity) : IFolderFileSystem
    {
        public FolderIdentity Resolve(string rootPath) => identity;
        public bool CaseSensitive(FolderSource root) => true;
        public IReadOnlyList<FolderEntry> List(FolderSource root, string directory) => [];
        public FileStamp Stat(FolderSource root, string relativePath) => new(identity.RootFileId, 0, 0);
        public FolderRead Hash(FolderSource root, string relativePath, long maxBytes) => throw new InvalidOperationException();
        public FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes) => throw new InvalidOperationException();
    }

    /// <summary>Waits complete only when the test advances time.</summary>
    private sealed class ManualClock(long now) : IIngestLeaseClock
    {
        private readonly object _gate = new();
        private readonly List<(long Deadline, TaskCompletionSource Completion)> _waits = [];
        private long _now = now;
        public long Now { get { lock (_gate) return _now; } }

        public void Set(long value) { lock (_gate) _now = value; }

        public Task WaitUntilAsync(long deadline, CancellationToken ct)
        {
            var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (_gate)
            {
                if (deadline <= _now) return Task.CompletedTask;
                _waits.Add((deadline, completion));
            }
            ct.Register(() =>
            {
                lock (_gate) _waits.RemoveAll(w => w.Completion == completion);
                completion.TrySetCanceled(ct);
            });
            return completion.Task;
        }

        public void Advance(long to)
        {
            (long, TaskCompletionSource)[] due;
            lock (_gate)
            {
                _now = Math.Max(_now, to);
                due = _waits.Where(w => w.Deadline <= _now).ToArray();
                _waits.RemoveAll(w => w.Deadline <= _now);
            }
            foreach (var (_, completion) in due) completion.TrySetResult();
        }
    }

    private sealed class FixedIdentity(FolderIdentity identity) : IFolderPathIdentity
    {
        public FolderIdentity Resolve(string rootPath) => identity;
    }

    private sealed class TempDir : IDisposable
    {
        public string Path { get; } = Directory.CreateDirectory(System.IO.Path.Combine(System.IO.Path.GetTempPath(),
            "wp6-generation-" + Guid.NewGuid().ToString("N"))).FullName;
        public void Dispose()
        {
            try { Directory.Delete(Path, true); } catch (IOException) { }
        }
    }

    private static async Task WaitUntil(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "condition not reached");
            await Task.Delay(1);
        }
    }

    private static readonly JsonSerializerOptions Camel = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private static EmbeddingSelection Selection(JsonElement e) => JsonSerializer.Deserialize<EmbeddingSelection>(e.GetRawText(), Camel)!;
    private static string Hex(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    private static JsonElement Case(string name) => SharedFixtures.Json("contracts/ingestion-generations-v1.json").GetProperty("cases")
        .EnumerateArray().Single(c => Name(c) == name);
    private static IEnumerable<JsonElement> Events(JsonElement row) => row.GetProperty("input").GetProperty("events").EnumerateArray().ToArray();
    private static string Name(JsonElement row) => row.GetProperty("name").GetString()!;
    private static string Op(JsonElement row) => row.GetProperty("operation").GetString()!;
    private static string? Str(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    private static string? Str2(JsonElement e) => e.ValueKind == JsonValueKind.String ? e.GetString() : null;
    private static long? Long(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : null;
    private static long[] Longs(JsonElement e, string key) => e.GetProperty(key).EnumerateArray().Select(x => x.GetInt64()).ToArray();

    private static void AssertJson(JsonElement expected, JsonElement actual, string path)
    {
        if (expected.ValueKind == JsonValueKind.Number)
        {
            Assert.True(actual.ValueKind == JsonValueKind.Number && Math.Abs(expected.GetDouble() - actual.GetDouble()) < 1e-6,
                $"{path}: expected {expected} got {actual}");
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

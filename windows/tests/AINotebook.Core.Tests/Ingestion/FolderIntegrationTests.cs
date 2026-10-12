using System.Net;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Extractors;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

public sealed class FolderIntegrationTests
{
    private sealed class WebText : ITextExtractor
    {
        public string Value = "first";
        public Task<ExtractedText> ExtractAsync(Uri url, SourceType kind) => Task.FromResult(new ExtractedText("web", Value));
    }

    [Fact]
    public async Task RecrawlPreservesIdentityAndPublishedEvidence()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        long nb = store.CreateNotebook("E2").Id!.Value;
        var web = new WebText();
        var service = new IngestionService(store, web: web);
        var old = await service.IngestUrlAsync(new Uri("https://example.invalid/doc"), nb);
        long oldRevision = store.Source(old.Id!.Value)!.PublishedRevisionId!.Value;
        web.Value = "second";
        var refreshed = await service.ReIngestAsync(old.Id.Value);
        Assert.Equal(old.Id, refreshed.Id); Assert.Equal(old.Uri, refreshed.Uri);
        Assert.Single(store.Sources(nb));
        Assert.Equal(new[] { "second" }, store.Chunks(old.Id.Value).Select(c => c.Text));
        Assert.NotEqual(oldRevision, refreshed.PublishedRevisionId);
        Assert.Equal("first", store.Revision(oldRevision)!.Draft.CanonicalText);
    }

    [Fact]
    public void EventPolicyForcesChangedRenamedAndOverflow()
    {
        Assert.True(FolderWatchEventPolicy.ForceHash("changed"));
        Assert.True(FolderWatchEventPolicy.ForceHash("renamed"));
        Assert.True(FolderWatchEventPolicy.ForceHash("overflow"));
        Assert.False(FolderWatchEventPolicy.ForceHash("created"));
        var rows = UiCases().Where(c => Op(c) == "watch").ToArray();
        Assert.Equal(5, rows.Length);
        foreach (var row in rows)
            Assert.Equal(row.GetProperty("expected").GetProperty("forceHash").GetBoolean(),
                FolderWatchEventPolicy.ForceHash(row.GetProperty("input").GetProperty("kind").GetString()!));
        // Every runtime fixture case is executed by exactly one Fact below.
        Assert.Equal(new[] { "runtime-two-notebooks-disabled-and-stop", "runtime-callback-after-remove", "runtime-one-trailing-scan",
            "runtime-loose-source", "runtime-url-refresh" }, UiCases().Where(c => Op(c) == "runtime").Select(Name));
    }

    [Fact]
    public async Task StartRestoresAllNotebooks()
    {
        await using (var harness = new RuntimeHarness(Case("runtime-two-notebooks-disabled-and-stop"))) await harness.ReplayAsync();

        // Native watches are created through the factory only for enabled folders, and stop joins cleanly.
        await using var dir = new TempTree();
        var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long nb = store.CreateNotebook("native").Id!.Value;
        var runtime = Runtime(store, new NativeFolderFileSystem(), new NativeFolderWatchFactory());
        var folder = await runtime.AddFolderAsync(nb, dir.Root);
        await runtime.StartAsync();
        Assert.Equal(new[] { folder.Id }, runtime.WatchedFolderIds);
        await File.WriteAllTextAsync(Path.Combine(dir.Root, "a.md"), "# Title\nbody");
        await runtime.ScanNowAsync(folder.Id, false);
        await runtime.WaitForFolderIdleAsync(folder.Id).WaitAsync(TimeSpan.FromSeconds(20));
        var source = Assert.Single(store.SourcesIncludingShadow(nb));
        Assert.NotNull(store.Source(source.Id!.Value)!.PublishedRevisionId);
        await runtime.StopAsync();
        Assert.Empty(runtime.WatchedFolderIds);
        await runtime.StopAsync(); // idempotent
        store.Dispose();
    }

    [Fact]
    public async Task DisableAndRemoveInvalidateCallbacks()
    {
        await using (var harness = new RuntimeHarness(Case("runtime-callback-after-remove"))) await harness.ReplayAsync();

        // Removal deletes database rows only; the native files stay on disk.
        await using var dir = new TempTree();
        File.WriteAllText(Path.Combine(dir.Root, "keep.md"), "keep");
        var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long nb = store.CreateNotebook("remove").Id!.Value;
        var runtime = Runtime(store, new NativeFolderFileSystem(), new NativeFolderWatchFactory());
        await runtime.StartAsync();
        var folder = await runtime.AddFolderAsync(nb, dir.Root);
        await runtime.WaitForFolderIdleAsync(folder.Id).WaitAsync(TimeSpan.FromSeconds(20));
        Assert.Single(store.SourcesIncludingShadow(nb));
        await runtime.RemoveFolderAsync(folder.Id);
        Assert.Empty(store.SourcesIncludingShadow(nb));
        Assert.Empty(store.Folders(nb));
        Assert.True(File.Exists(Path.Combine(dir.Root, "keep.md")));
        Assert.Empty(runtime.WatchedFolderIds);
        await runtime.StopAsync();
        store.Dispose();
    }

    [Fact]
    public async Task OneTrailingScan()
    {
        await using var harness = new RuntimeHarness(Case("runtime-one-trailing-scan"));
        await harness.ReplayAsync();
    }

    [Fact]
    public async Task ChatErrorAndCancellationReleaseAdmission()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long nb = store.CreateNotebook("chat").Id!.Value;
        long session = store.CreateChatSession(nb, "T").Id!.Value;
        var admission = new IngestionAdmission();
        var retriever = new Retriever(store, new MockEmbeddingClient(_ => new[] { 1f, 0f }), "emb");
        var chat = new ScriptedChat();
        var engine = new ChatEngine(store, retriever, chat, "m", retryAttempts: 0, admission: admission);

        // While the turn streams, the next background batch waits; it resumes when the turn ends.
        chat.Gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var turn = engine.SendAsync(session, nb, "hello");
        await WaitUntil(() => admission.ChatTokens.Count == 1);
        var batch = admission.WaitForBackgroundBatchAsync();
        Assert.False(batch.IsCompleted);
        chat.Gate.SetResult();
        await turn;
        await batch.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Empty(admission.ChatTokens);

        // Provider error.
        chat.Gate = null;
        chat.Fail = new ProviderAuthException("denied");
        await Assert.ThrowsAsync<ProviderAuthException>(() => engine.SendAsync(session, nb, "again"));
        Assert.Empty(admission.ChatTokens);

        // Callback failure.
        chat.Fail = null;
        await Assert.ThrowsAsync<InvalidOperationException>(() => engine.SendAsync(session, nb, "cb", onToken: _ => throw new InvalidOperationException()));
        Assert.Empty(admission.ChatTokens);

        // Cancellation during streaming.
        using var cancel = new CancellationTokenSource();
        chat.Gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cancelled = engine.SendAsync(session, nb, "stop", ct: cancel.Token);
        await WaitUntil(() => admission.ChatTokens.Count == 1);
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cancelled);
        Assert.Empty(admission.ChatTokens);
        Assert.True(admission.WaitForBackgroundBatchAsync().IsCompletedSuccessfully);
    }

    [Fact]
    public async Task TypedScopeNeverWidensAnEmptySelection()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long nb = store.CreateNotebook("scope").Id!.Value;
        long other = store.CreateNotebook("other").Id!.Value;
        var service = new IngestionService(store);
        var loose = await service.IngestRawTextAsync("loose", "the sky is blue", nb);
        var foreign = await service.IngestRawTextAsync("foreign", "the sky is green", other);
        var folder = store.CreateFolder(nb, new FolderDraft("/docs", "Docs", ["md"], [], "{}", "cp1250", true),
            new FixedIdentity(Identity("/docs")), 0);
        var member = await service.IngestRawTextAsync("member", "the sea is blue", nb);
        store.AttachSource(member.Id!.Value, folder.Id, "member.md");
        var none = new HashSet<long>();
        Assert.Null(store.ChatSourceIds(nb, new RetrievalScope.All()));
        Assert.Empty(store.ChatSourceIds(nb, new RetrievalScope.Selection(none, none))!);
        Assert.Equal(new[] { member.Id.Value }, store.ChatSourceIds(nb, new RetrievalScope.Selection(none, new HashSet<long> { folder.Id }))!);
        // Foreign and ineligible sources never enter a selection.
        Assert.Equal(new[] { loose.Id!.Value }, store.ChatSourceIds(nb,
            new RetrievalScope.Selection(new HashSet<long> { loose.Id.Value, foreign.Id!.Value }, none))!.Order());
        lock (store.Gate) store.Connection.Execute("UPDATE sources SET eligible=0 WHERE id=$id", new { id = member.Id.Value });
        Assert.Empty(store.ChatSourceIds(nb, new RetrievalScope.Selection(none, new HashSet<long> { folder.Id }))!);

        long session = store.CreateChatSession(nb, "T").Id!.Value;
        var chat = new CapturingChat();
        var engine = new ChatEngine(store, new Retriever(store, new MockEmbeddingClient(_ => new[] { 1f, 0f }), "emb"), chat, "m");
        await engine.SendAsync(session, nb, "sky", new RetrievalScope.Selection(none, none));
        Assert.DoesNotContain("the sky is blue", chat.Final);
        await engine.SendAsync(session, nb, "sky", new RetrievalScope.Selection(new HashSet<long> { loose.Id.Value }, none));
        Assert.Contains("the sky is blue", chat.Final);
        Assert.DoesNotContain("the sky is blue", chat.System);
        Assert.DoesNotContain("the sky is green", chat.Final);
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => engine.SendAsync(session, nb, "sky", new RetrievalScope.All(), mode: "draft"));
    }

    private sealed class CapturingChat : IChatStreaming
    {
        public string System = "";
        // WP8: evidence is part of the final user turn, never the system prompt.
        public string Final = "";
        public async IAsyncEnumerable<string> StreamAsync(string model, IReadOnlyList<ChatTurn> messages,
            [EnumeratorCancellation] CancellationToken ct = default)
        {
            System = messages[0].Content;
            Final = messages[^1].Content;
            await Task.Yield();
            yield return "ok";
        }
    }

    [Fact]
    public async Task LooseOfficeUsesCanonicalExtractor()
    {
        foreach (string name in new[] { "runtime-loose-source", "runtime-url-refresh" })
            await using (var harness = new RuntimeHarness(Case(name))) await harness.ReplayAsync();

        // Production default: bounded canonical Office extraction, scalar chunker v2 and fenced metadata.
        var office = SharedFixtures.Json("contracts/ingestion-office-v1.json").GetProperty("cases").EnumerateArray()
            .First(c => c.GetProperty("input").TryGetProperty("asset", out var asset) && asset.GetString() == "ingestion/paragraphs.docx"
                && c.GetProperty("expected").TryGetProperty("text", out _));
        await using var dir = new TempTree();
        string path = Path.Combine(dir.Root, "paragraphs.docx");
        File.Copy(SharedFixtures.Path("ingestion/paragraphs.docx"), path);
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long nb = store.CreateNotebook("loose").Id!.Value;
        var service = new IngestionService(store, detector: LanguageDetector.Unavailable);
        var source = await service.IngestFileAsync(new Uri(path), nb);
        var revision = store.Revision(source.PublishedRevisionId!.Value)!;
        Assert.Equal(2, revision.Draft.ChunkerVersion);
        Assert.Equal(office.GetProperty("expected").GetProperty("text").GetString(), revision.Draft.CanonicalText);
        Assert.All(store.Chunks(source.Id!.Value), c => Assert.Equal(c.Text,
            string.Concat(revision.Draft.CanonicalText.EnumerateRunes().Skip(c.CharStart!.Value).Take(c.CharEnd!.Value - c.CharStart.Value))));
        using var descriptor = JsonDocument.Parse(store.Source(source.Id.Value)!.Descriptor!);
        Assert.Equal("docx", descriptor.RootElement.GetProperty("type").GetString());
        Assert.Equal(new FileInfo(path).Length, descriptor.RootElement.GetProperty("sizeBytes").GetInt64());
        Assert.NotNull(store.Source(source.Id.Value)!.LastSyncedAt);
    }

    [Fact]
    public async Task LegacyKickDoesNotDoubleEmbed()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long nb = store.CreateNotebook("kick").Id!.Value;
        var service = new IngestionService(store);
        await service.IngestRawTextAsync("note", "alpha", nb);
        var legacy = new MockEmbeddingClient(_ => new[] { 1f, 0f });
        var handler = new OllamaEmbedHandler();
        using var http = new HttpClient(handler);
        var session = new FolderEmbeddingSession(new ProviderConfig("local", ProviderType.Ollama, "Local", "http://localhost:11434",
            true, false, DateTime.UnixEpoch), "embed-a", null, null, "1", "1", http);
        var runtime = Runtime(store, new EmptyFS(), new RecordingWatchFactory(), session: session);
        var worker = new EmbeddingWorker(ct => runtime.RequestEmbeddingWorkAsync(ct));
        worker.Kick();
        await worker.WaitUntilIdleAsync();
        Assert.Equal(1, worker.TotalEmbedded); // one durable build requested, no legacy embedding
        while (await runtime.DrainOnceAsync()) { }
        var active = store.ActiveGeneration(nb)!;
        Assert.Equal(session.Selection.EndpointRevision, active.Identity.EndpointRevision);
        Assert.Equal(1, handler.Calls);
        Assert.Empty(legacy.Calls);
        // A second kick finds nothing to do: no duplicate build, no extra provider call.
        worker.Kick();
        await worker.WaitUntilIdleAsync();
        Assert.False(await runtime.DrainOnceAsync());
        Assert.Equal(1, handler.Calls);
        Assert.Equal(active.Id, store.ActiveGeneration(nb)!.Id);
    }

    // ---------------------------------------------------------------- runtime fixture harness

    private sealed class RuntimeHarness : IAsyncDisposable
    {
        private static readonly string[] Ops = ["start", "stop", "watch", "remove", "signal", "tick", "start-scan", "finish-scan",
            "drain", "ingest-source", "refresh-source", "refresh-url"];
        private readonly JsonElement _row;
        private readonly NotebookStore _store = new(StorePath.InMemory, configuredEmbeddingModelKey: null);
        private readonly RecordingWatchFactory _watches = new();
        private readonly GatedFS _fs;
        private readonly FolderIngestionRuntime _runtime;
        private readonly Dictionary<long, long> _jobs = new();
        private readonly Dictionary<long, long> _sources = new();
        private readonly Dictionary<long, long> _revisions = new();
        private readonly List<long> _scanStarts = [];
        private readonly WebText _web = new();
        private readonly TempTree _files = new();
        private long _now;
        private Task<bool>? _drain;

        public RuntimeHarness(JsonElement row)
        {
            _row = row;
            var input = row.GetProperty("input");
            var seed = input.GetProperty("seed");
            Assert.Equal(JsonValueKind.Null, input.GetProperty("embeddingSelection").ValueKind);
            Assert.Equal(new[] { "scan" }, input.GetProperty("projectJobKinds").EnumerateArray().Select(k => k.GetString()));
            foreach (var nb in seed.GetProperty("notebooks").EnumerateArray()) Assert.Equal(nb.GetInt64(), _store.CreateNotebook("rt").Id);
            foreach (var f in seed.GetProperty("folders").EnumerateArray())
                Assert.Equal(f.GetProperty("id").GetInt64(), _store.CreateFolder(f.GetProperty("notebookId").GetInt64(),
                    new FolderDraft(f.GetProperty("rootPath").GetString()!, "F", ["md"], [], "{}", "cp1250", f.GetProperty("watchEnabled").GetBoolean()),
                    new FixedIdentity(Identity(f.GetProperty("rootPath").GetString()!)), 0).Id);
            _fs = new GatedFS(this);
            _runtime = Runtime(_store, _fs, _watches, milliseconds: () => Volatile.Read(ref _now), autoDispatch: false);
        }

        public async ValueTask DisposeAsync()
        {
            _fs.Release();
            if (_drain is not null) await _drain;
            await _runtime.StopAsync();
            _store.Dispose();
            await _files.DisposeAsync();
        }

        public async Task ReplayAsync()
        {
            int index = 0;
            foreach (var e in _row.GetProperty("input").GetProperty("events").EnumerateArray())
            {
                string op = e.GetProperty("operation").GetString()!;
                Assert.Contains(op, Ops);
                Volatile.Write(ref _now, e.GetProperty("at").GetInt64());
                switch (op)
                {
                    case "start":
                        await _runtime.StartAsync();
                        if (e.TryGetProperty("watchTokens", out var tokens))
                            foreach (var p in tokens.EnumerateObject())
                                Assert.Equal(p.Value.GetString(), _watches.TokenFor(long.Parse(p.Name)));
                        break;
                    case "stop": await _runtime.StopAsync(); break;
                    case "watch": await _runtime.SetWatchingAsync(e.GetProperty("folderId").GetInt64(), e.GetProperty("enabled").GetBoolean()); break;
                    case "remove": await _runtime.RemoveFolderAsync(e.GetProperty("folderId").GetInt64()); break;
                    case "signal":
                        _watches.Fire(e.GetProperty("watchToken").GetString()!, e.GetProperty("forceHash").GetBoolean() ? "changed" : "created");
                        break;
                    case "tick": await _runtime.TickAsync(e.GetProperty("at").GetInt64()); break;
                    case "start-scan":
                        _fs.Gate(e.GetProperty("folderId").GetInt64());
                        _drain = _runtime.DrainOnceAsync();
                        await _fs.Entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
                        break;
                    case "finish-scan":
                        _fs.Release();
                        Assert.True(await _drain!.WaitAsync(TimeSpan.FromSeconds(10)));
                        _drain = null;
                        break;
                    case "drain":
                        bool ran = await _runtime.DrainOnceAsync();
                        Assert.Equal(e.GetProperty("jobId").ValueKind != JsonValueKind.Null, ran);
                        break;
                    case "ingest-source":
                        var service = Service();
                        string kind = e.GetProperty("kind").GetString()!;
                        Source created;
                        if (kind == "url")
                        {
                            _web.Value = e.GetProperty("text").GetString()!;
                            created = await service.IngestUrlAsync(new Uri(e.GetProperty("uri").GetString()!), e.GetProperty("notebookId").GetInt64());
                        }
                        else
                        {
                            string file = Path.Combine(_files.Root, "loose.txt");
                            await File.WriteAllTextAsync(file, e.GetProperty("text").GetString()!);
                            created = await service.IngestFileAsync(new Uri(file), e.GetProperty("notebookId").GetInt64());
                        }
                        _sources[created.Id!.Value] = e.GetProperty("sourceId").GetInt64();
                        break;
                    case "refresh-source":
                        await File.WriteAllTextAsync(Path.Combine(_files.Root, "loose.txt"), e.GetProperty("text").GetString()!);
                        await Service().ReIngestAsync(_sources.Single(p => p.Value == e.GetProperty("sourceId").GetInt64()).Key);
                        break;
                    case "refresh-url":
                        _web.Value = e.GetProperty("text").GetString()!;
                        await Service().ReIngestAsync(_sources.Single(p => p.Value == e.GetProperty("sourceId").GetInt64()).Key);
                        break;
                }
                AssertJson(e.GetProperty("expected"), Project(e.GetProperty("expected")), $"{Name(_row)} event {index++} ({op})");
            }
            AssertJson(_row.GetProperty("expected"), Project(_row.GetProperty("expected")), Name(_row) + " final");
        }

        private IngestionService Service() => new(_store, web: _web, detector: LanguageDetector.Unavailable);

        internal void RecordScanStart(long folderId)
        {
            lock (_store.Gate)
            {
                long job = _store.Connection.QuerySingle<long>(
                    "SELECT id FROM ingest_jobs WHERE kind='scan' AND state='running' AND target=$target", new { target = $"folder:{folderId}" });
                lock (_scanStarts) _scanStarts.Add(job);
            }
        }

        private JsonElement Project(JsonElement expected)
        {
            lock (_store.Gate)
            {
                var c = _store.Connection;
                var free = new Queue<long>(expected.GetProperty("jobs").EnumerateArray().Select(j => j.GetProperty("id").GetInt64())
                    .Where(id => !_jobs.ContainsValue(id)).Order());
                foreach (long id in c.Query<long>("SELECT id FROM ingest_jobs WHERE kind='scan' ORDER BY id"))
                    if (!_jobs.ContainsKey(id) && free.Count > 0) _jobs[id] = free.Dequeue();
                var freeRevisions = new Queue<long>(expected.GetProperty("sources").EnumerateArray()
                    .SelectMany(s => s.GetProperty("retainedRevisionIds").EnumerateArray().Select(r => r.GetInt64()))
                    .Where(id => !_revisions.ContainsValue(id)).Distinct().Order());
                foreach (long id in c.Query<long>("SELECT id FROM source_revisions ORDER BY id"))
                    if (!_revisions.ContainsKey(id) && freeRevisions.Count > 0) _revisions[id] = freeRevisions.Dequeue();
                long Job(long id) => _jobs.TryGetValue(id, out long f) ? f : -id;
                var jobs = c.Query("SELECT * FROM ingest_jobs WHERE kind='scan' ORDER BY id").Select(j => new
                {
                    id = Job((long)j.id), kind = (string)j.kind, folderId = long.Parse(((string)j.target)["folder:".Length..]),
                    state = (string)j.state, verifyAll = JsonDocument.Parse((string)j.options_json).RootElement.GetProperty("verifyAll").GetBoolean()
                }).OrderBy(j => j.id).ToArray();
                long[] starts;
                lock (_scanStarts) starts = _scanStarts.Select(Job).ToArray();
                return JsonSerializer.SerializeToElement(new
                {
                    watchedFolderIds = _watches.ActiveFolders(),
                    queuedJobIds = jobs.Where(j => j.state == "queued").Select(j => j.id).ToArray(),
                    providerCallCount = 0,
                    jobs,
                    folderIds = c.Query<long>("SELECT id FROM folder_sources ORDER BY id").ToArray(),
                    sources = c.Query("SELECT * FROM sources ORDER BY id").Select(s => new
                    {
                        id = _sources.TryGetValue((long)s.id, out long f) ? f : -(long)s.id, notebookId = (long)s.notebook_id,
                        type = (string)s.type == "web" ? "url" : (string)s.type, uri = (string?)s.uri,
                        publishedRevisionId = s.published_revision_id is null ? (long?)null : _revisions.GetValueOrDefault((long)s.published_revision_id, -1),
                        canonicalText = c.QuerySingleOrDefault<string>("SELECT canonical_text FROM source_revisions WHERE id=$id", new { id = (long?)s.published_revision_id }),
                        retainedRevisionIds = c.Query<long>("SELECT id FROM source_revisions WHERE source_id=$id ORDER BY id", new { id = (long)s.id })
                            .Select(r => _revisions.GetValueOrDefault(r, -1)).ToArray()
                    }).ToArray(),
                    scanStarts = starts,
                    diskDeleteCalls = _fs.DeleteCalls
                });
            }
        }

        /// <summary>Empty roots; one folder's root listing can be held at a barrier while signals arrive.</summary>
        private sealed class GatedFS(RuntimeHarness owner) : IFolderFileSystem
        {
            private readonly ManualResetEventSlim _release = new(true);
            private long _gated = -1;
            public TaskCompletionSource Entered { get; private set; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
            public int DeleteCalls => 0; // The adapter exposes no delete operation; removal must never need one.

            public void Gate(long folderId)
            {
                Entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                Volatile.Write(ref _gated, folderId);
                _release.Reset();
            }

            public void Release() => _release.Set();

            public FolderIdentity Resolve(string rootPath) => Identity(rootPath);
            public bool CaseSensitive(FolderSource root) => true;

            public IReadOnlyList<FolderEntry> List(FolderSource root, string directory)
            {
                if (directory.Length == 0)
                {
                    owner.RecordScanStart(root.Id);
                    if (Volatile.Read(ref _gated) == root.Id)
                    {
                        Volatile.Write(ref _gated, -1);
                        Entered.TrySetResult();
                        Assert.True(_release.Wait(TimeSpan.FromSeconds(10)));
                    }
                }
                return [];
            }

            public FileStamp Stat(FolderSource root, string relativePath) => new(root.Identity.RootFileId, 0, 0);
            public FolderRead Hash(FolderSource root, string relativePath, long maxBytes) => throw new InvalidOperationException();
            public FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes) => throw new InvalidOperationException();
        }
    }

    private sealed class RecordingWatchFactory : IFolderWatchFactory
    {
        private readonly object _gate = new();
        private readonly Dictionary<string, (long FolderId, Action<string> Callback)> _callbacks = new(StringComparer.Ordinal);
        private readonly HashSet<long> _active = [];

        public IFolderWatchHandle Create(FolderSource folder, Action<string> onEvent)
        {
            lock (_gate) _callbacks["watch-" + folder.Id] = (folder.Id, onEvent);
            return new Handle(this, folder.Id);
        }

        public string? TokenFor(long folderId)
        {
            lock (_gate) return _callbacks.Where(p => p.Value.FolderId == folderId).Select(p => p.Key).SingleOrDefault();
        }

        /// <summary>Delivers an event through the captured callback, even after the handle was disposed.</summary>
        public void Fire(string token, string kind)
        {
            Action<string> callback;
            lock (_gate) callback = _callbacks[token].Callback;
            callback(kind);
        }

        public long[] ActiveFolders()
        {
            lock (_gate) return _active.Order().ToArray();
        }

        private sealed class Handle(RecordingWatchFactory owner, long folderId) : IFolderWatchHandle
        {
            public void Start() { lock (owner._gate) owner._active.Add(folderId); }
            public void Dispose() { lock (owner._gate) owner._active.Remove(folderId); }
        }
    }

    private static FolderIngestionRuntime Runtime(NotebookStore store, IFolderFileSystem fs, IFolderWatchFactory watches,
        Func<long>? milliseconds = null, bool autoDispatch = true, FolderEmbeddingSession? session = null)
    {
        var clock = new SystemIngestLeaseClock();
        var admission = new IngestionAdmission();
        var tables = UnicodeTables.LoadBundled();
        var extractor = new BoundedDocumentExtractor();
        Func<long, Task<EmbeddingSelection?>> selected = _ => Task.FromResult(session?.Selection);
        return new FolderIngestionRuntime(store, new FolderScanner(store, fs, tables, clock),
            new FolderExtractionWorker(store, fs, LanguageDetector.Unavailable, clock, selected, (uri, type, rules, ct) => extractor.ExtractAsync(uri, type, rules, ct)),
            new FolderIndexCoordinator(store, admission, clock, (_, _) => Task.FromResult(session), selected),
            new JobQueue(store, clock, admission), clock, admission, watches, milliseconds, identity: fs, selectedSelection: selected)
        { AutoDispatch = autoDispatch };
    }

    private sealed class ScriptedChat : IChatStreaming
    {
        public TaskCompletionSource? Gate;
        public Exception? Fail;

        public async IAsyncEnumerable<string> StreamAsync(string model, IReadOnlyList<ChatTurn> messages,
            [EnumeratorCancellation] CancellationToken ct = default)
        {
            if (Fail is not null) throw Fail;
            if (Gate is not null) await Gate.Task.WaitAsync(ct);
            yield return "ok";
        }
    }

    private sealed class OllamaEmbedHandler : HttpMessageHandler
    {
        public int Calls;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Interlocked.Increment(ref Calls);
            Assert.Equal("http://localhost:11434/api/embed", request.RequestUri!.AbsoluteUri);
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(ct));
            var vectors = body.RootElement.GetProperty("input").EnumerateArray().Select(_ => new[] { 1.0, 0.0 }).ToArray();
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(JsonSerializer.Serialize(new { embeddings = vectors }), Encoding.UTF8, "application/json")
            };
        }
    }

    private sealed class EmptyFS : IFolderFileSystem
    {
        public FolderIdentity Resolve(string rootPath) => Identity(rootPath);
        public bool CaseSensitive(FolderSource root) => true;
        public IReadOnlyList<FolderEntry> List(FolderSource root, string directory) => [];
        public FileStamp Stat(FolderSource root, string relativePath) => new(root.Identity.RootFileId, 0, 0);
        public FolderRead Hash(FolderSource root, string relativePath, long maxBytes) => throw new InvalidOperationException();
        public FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes) => throw new InvalidOperationException();
    }

    private sealed class FixedIdentity(FolderIdentity identity) : IFolderPathIdentity
    {
        public FolderIdentity Resolve(string rootPath) => identity;
    }

    private sealed class TempTree : IAsyncDisposable
    {
        public string Root { get; } = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "wp6-runtime-" + Guid.NewGuid().ToString("N"))).FullName;
        public ValueTask DisposeAsync()
        {
            try { Directory.Delete(Root, true); } catch (IOException) { }
            return ValueTask.CompletedTask;
        }
    }

    private static FolderIdentity Identity(string rootPath) =>
        new("fixture", rootPath.Split('/', StringSplitOptions.RemoveEmptyEntries), "root:" + rootPath);

    private static async Task WaitUntil(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "condition not reached");
            await Task.Delay(1);
        }
    }

    private static IEnumerable<JsonElement> UiCases() =>
        SharedFixtures.Json("contracts/ingestion-ui-v1.json").GetProperty("cases").EnumerateArray().ToArray();
    private static JsonElement Case(string name) => UiCases().Single(c => Name(c) == name);
    private static string Name(JsonElement row) => row.GetProperty("name").GetString()!;
    private static string Op(JsonElement row) => row.GetProperty("operation").GetString()!;

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

using System.Net;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
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

namespace AINotebook.Core.Tests.Integration;

// WP9 release integration support. Test infrastructure only: real file-backed store (v18 fixture upgraded
// through the ordinary constructor), native filesystem, bounded extractors, bundled detector/Unicode tables,
// durable queue, generation coordinator, retriever, context-pack coordinator and ChatEngine. Only embeddings,
// the chat transport, watches and the clock are controlled doubles.

internal sealed record ReleaseExpected(
    int? Files, int? Searchable, int? RefreshPending, int? RefreshError, int[]? SavedMarkers, int? CitationVersion,
    bool? SameSource, bool? NewRevision, string? CancelledState, bool? OldRevisionRetained, bool? NewJob,
    string? Before, string? After, int? Missing, bool? OldCitationReadable, bool? Eligible, string? Availability,
    bool? VectorIncludes, bool? LexicalIncludes, bool? MapIncludes, bool? OverviewIncludes, int? Citations,
    int? QueryEmbeddingCalls, int? EvidenceSections);

internal sealed record ReleaseCase(string Name, string? RelPath, string? Append, string? Pattern, int? Cap,
    ReleaseExpected Expected);

internal sealed record ReleaseAsset(string Kind, string RepoPath, string RelPath, string RawSha256,
    string CanonicalText, string? Encoding, string? Language);

internal sealed record ReleaseEndpointCase(string Type, string Root, string Expected);

internal sealed record ReleaseFixture(string Contract, int Version, ReleaseAsset[] Assets,
    ReleaseEndpointCase[] EndpointCases, string RulesText, string Question, string Answer, string Instructions,
    string DbFixture, string DbSha256, int RuntimeContext, int MaxOutputTokens, int FetchK, int TopK,
    ReleaseCase[] Cases)
{
    internal static readonly string[] SupportedCases =
    [
        "upgrade-chat", "restart-reconcile", "cancel-resume", "delete-completed-scan",
        "rules-restrict", "empty-selection", "zero-evidence",
    ];

    /// <summary>The workbook asset's canonical text is superseded by ingestion-xlsx-v2.</summary>
    internal static ReleaseFixture Load()
    {
        var fixture = JsonSerializer.Deserialize<ReleaseFixture>(
            File.ReadAllBytes(SharedFixtures.Path("contracts/release-integration-v1.json")),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new InvalidDataException("release fixture");
        var superseded = AINotebook.Core.Tests.Ingestion.SpreadsheetSupersession.Map().GetProperty("release-integration-v1.json");
        return fixture with
        {
            Assets = fixture.Assets.Select(asset => superseded.TryGetProperty(asset.RelPath, out var replacement)
                ? asset with { CanonicalText = replacement.GetProperty("canonicalText").GetString()! }
                : asset).ToArray(),
        };
    }

    internal ReleaseCase CaseNamed(string name) => Cases.Single(c => c.Name == name);

    /// <summary>Maps a repository path to its copy in the test output; any other prefix is rejected.</summary>
    internal static string AssetPath(string repoPath)
    {
        const string eval = "eval/multilingual/", fixtures = "Tests/fixtures/";
        if (repoPath.StartsWith(eval, StringComparison.Ordinal))
            return System.IO.Path.Combine(AppContext.BaseDirectory, "EvalMultilingual", repoPath[eval.Length..]);
        if (repoPath.StartsWith(fixtures, StringComparison.Ordinal))
            return SharedFixtures.Path(repoPath[fixtures.Length..]);
        throw new InvalidDataException("unsupported asset prefix: " + repoPath);
    }
}

/// <summary>Serves only POST https://wp9.invalid/v1/embeddings for model wp9-2d; nothing reaches the network.</summary>
internal sealed class ReleaseEmbeddingHandler : HttpMessageHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        Assert.Equal("https://wp9.invalid/v1/embeddings", request.RequestUri!.AbsoluteUri);
        using var json = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(ct));
        Assert.Equal("wp9-2d", json.RootElement.GetProperty("model").GetString());
        int count = json.RootElement.GetProperty("input").GetArrayLength();
        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(JsonSerializer.Serialize(new
            {
                data = Enumerable.Range(0, count).Select(i => new { index = i, embedding = new[] { 1, 0 } }),
            }), Encoding.UTF8, "application/json"),
        };
    }
}

/// <summary>Query-side embedding: counts calls and checks the pinned generation's endpoint identity.</summary>
internal sealed class ReleaseQueryEmbedding(string expectedEndpoint) : IEmbeddingProducing, IEmbeddingSessionPreparing
{
    private int _calls;
    internal int Calls => Volatile.Read(ref _calls);

    public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        Interlocked.Increment(ref _calls);
        return Task.FromResult(inputs.Select(_ => new float[] { 1, 0 }).ToArray());
    }

    public Task<ProviderEmbeddingSession> PrepareEmbeddingAsync(GenerationIdentity identity, CancellationToken ct = default)
    {
        Assert.Equal(expectedEndpoint, identity.EndpointRevision);
        return Task.FromResult(new ProviderEmbeddingSession(this, identity.Model,
            identity.ProviderId + ":" + identity.Model, identity.EndpointRevision));
    }
}

/// <summary>Fixed time; a wait for a future deadline ends only when cancelled.</summary>
internal sealed class ReleaseClock : IIngestLeaseClock
{
    public long Now => 1_800_000_000;
    public Task WaitUntilAsync(long deadline, CancellationToken ct) => deadline <= Now
        ? Task.CompletedTask
        : new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously).Task.WaitAsync(ct);
}

internal sealed class ReleaseSilentWatches : IFolderWatchFactory
{
    private sealed class Handle : IFolderWatchHandle
    {
        public void Start() { }
        public void Dispose() { }
    }

    public IFolderWatchHandle Create(FolderSource folder, Action<string> onEvent) => new Handle();
}

/// <summary>Captures the exact prepared request at the provider boundary.</summary>
internal sealed class ReleaseTransport(PackModel model, string answer) : IPreparedPackTransport
{
    private readonly List<byte[]> _requests = [];
    public PackModel Model { get; } = model;

    internal IReadOnlyList<byte[]> Requests
    {
        get { lock (_requests) return _requests.ToArray(); }
    }

    public async IAsyncEnumerable<string> StreamAsync(PreparedContextRequest request,
        [EnumeratorCancellation] CancellationToken ct)
    {
        lock (_requests) _requests.Add(PreparedContextRequestJson.Encode(request));
        await Task.Yield();
        ct.ThrowIfCancellationRequested();
        yield return answer;
    }
}

internal sealed class ReleaseTransportFactory(ReleaseTransport transport) : IPackTransportFactory
{
    public Task<IPreparedPackTransport> FreezeAsync(PackIntent intent, CancellationToken ct) =>
        Task.FromResult<IPreparedPackTransport>(transport);

    public Task<PackTransportDescription> DescribeAsync(string? requestedModel, CancellationToken ct) =>
        Task.FromResult(new PackTransportDescription(transport.Model, 0));
}

/// <summary>Barrier after the real bounded extractor and before language/chunk publication.</summary>
internal sealed class ReleaseExtractionGate
{
    private int _armed;
    private TaskCompletionSource _entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private TaskCompletionSource _released = new(TaskCreationOptions.RunContinuationsAsynchronously);

    internal void Arm()
    {
        _entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        _released = new(TaskCreationOptions.RunContinuationsAsynchronously);
        Interlocked.Exchange(ref _armed, 1);
    }

    internal async Task AfterExtractionAsync(CancellationToken ct)
    {
        if (Interlocked.Exchange(ref _armed, 0) == 1)
        {
            _entered.TrySetResult();
            await _released.Task.WaitAsync(ct).ConfigureAwait(false);
        }
        ct.ThrowIfCancellationRequested();
    }

    internal Task WaitUntilEnteredAsync() => _entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
    internal void Release() => _released.TrySetResult();
}

internal sealed class ReleaseGraph : IDisposable
{
    internal required NotebookStore Store { get; init; }
    internal required HttpClient Http { get; init; }
    internal required FolderEmbeddingSession Embedding { get; init; }
    internal required FolderScanner Scanner { get; init; }
    internal required FolderExtractionWorker Worker { get; init; }
    internal required JobQueue Queue { get; init; }
    internal required FolderIngestionRuntime Runtime { get; init; }
    internal required Retriever Retriever { get; init; }
    internal required ReleaseQueryEmbedding QueryEmbedding { get; init; }
    internal required ReleaseTransport Transport { get; init; }
    internal required ContextPreviewSession Previews { get; init; }
    internal required ChatEngine Engine { get; init; }

    public void Dispose()
    {
        Http.Dispose();
        Store.Dispose();
    }
}

internal sealed class ReleaseHarness
{
    internal const string ProviderRoot = "https://wp9.invalid/v1";
    private ReleaseGraph? _graph;

    private ReleaseHarness(ReleaseFixture fixture, string root)
    {
        Fixture = fixture;
        Root = root;
        FolderPath = System.IO.Path.Combine(root, "Folder");
        DatabasePath = System.IO.Path.Combine(root, "db.sqlite");
    }

    internal ReleaseFixture Fixture { get; }
    internal string Root { get; }
    internal string FolderPath { get; }
    internal string DatabasePath { get; }
    internal ReleaseClock Clock { get; } = new();
    internal ReleaseExtractionGate Gate { get; } = new();
    internal long NotebookId { get; private set; }
    internal long SessionId { get; private set; }
    internal long FolderId { get; private set; }

    private ReleaseGraph G => _graph ?? throw new InvalidOperationException("harness is closed");
    internal NotebookStore Store => G.Store;
    internal FolderScanner Scanner => G.Scanner;
    internal FolderExtractionWorker Worker => G.Worker;
    internal JobQueue Queue => G.Queue;
    internal FolderIngestionRuntime Runtime => G.Runtime;
    internal Retriever Retriever => G.Retriever;
    internal ReleaseQueryEmbedding QueryEmbedding => G.QueryEmbedding;
    internal ReleaseTransport Transport => G.Transport;
    internal ContextPreviewSession Previews => G.Previews;
    internal ChatEngine Engine => G.Engine;

    /// <summary>
    /// Copies the v18 fixture and six assets into a unique temporary tree, upgrades through the ordinary store
    /// constructor, adds the folder once through the runtime and drains the durable queue.
    /// </summary>
    internal static async Task<ReleaseHarness> OpenAsync()
    {
        var fixture = ReleaseFixture.Load();
        string root = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ainotebook-wp9-" + Guid.NewGuid().ToString("N"));
        var h = new ReleaseHarness(fixture, root);
        try
        {
            h.Materialize();
            h.MakeGraph();
            var notebook = h.Store.CreateNotebook("WP9 integration");
            h.NotebookId = notebook.Id ?? throw new InvalidOperationException("notebook id");
            h.SessionId = h.Store.CreateChatSession(h.NotebookId, "Release chat").Id
                ?? throw new InvalidOperationException("session id");
            var folder = await h.Runtime.AddFolderAsync(h.NotebookId, h.FolderPath);
            h.FolderId = folder.Id;
            await h.DrainAsync();
            return h;
        }
        catch
        {
            await h.CloseAsync();
            h.RemoveTemporaryFiles();
            throw;
        }
    }

    private void Materialize()
    {
        Directory.CreateDirectory(FolderPath);
        byte[] db = File.ReadAllBytes(SharedFixtures.Path(Fixture.DbFixture));
        Assert.Equal(Fixture.DbSha256, Sha(db));
        File.WriteAllBytes(DatabasePath, db);
        foreach (var asset in Fixture.Assets)
        {
            var parts = asset.RelPath.Split('/');
            if (asset.RelPath.Length == 0 || System.IO.Path.IsPathRooted(asset.RelPath)
                || parts.Any(p => p.Length == 0 || p == "." || p == ".."))
                throw new InvalidDataException("unsafe relPath " + asset.RelPath);
            byte[] bytes = File.ReadAllBytes(ReleaseFixture.AssetPath(asset.RepoPath));
            Assert.Equal(asset.RawSha256, Sha(bytes));
            string destination = System.IO.Path.Combine([FolderPath, .. parts]);
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(destination)!);
            File.WriteAllBytes(destination, bytes);
        }
    }

    private void MakeGraph()
    {
        var store = new NotebookStore(new StorePath(DatabasePath), AppLanguage.English, null);
        var config = new ProviderConfig("wp9", ProviderType.OpenAICompatible, "WP9", ProviderRoot, true, true,
            DateTime.UnixEpoch);
        if (store.Provider("wp9") is null) store.SaveProvider(config);
        var http = new HttpClient(new ReleaseEmbeddingHandler());
        var embedding = new FolderEmbeddingSession(config, "wp9-2d", null, null, "1", "1", http);
        var fs = new NativeFolderFileSystem();
        var clock = Clock;
        var gate = Gate;
        var admission = new IngestionAdmission();
        var scanner = new FolderScanner(store, fs, UnicodeTables.LoadBundled(), clock);
        var extractor = new BoundedDocumentExtractor();
        var worker = new FolderExtractionWorker(store, fs, LanguageDetector.LoadBundled(), clock,
            _ => Task.FromResult<EmbeddingSelection?>(embedding.Selection),
            async (url, kind, rules, ct) =>
            {
                var document = await extractor.ExtractAsync(url, kind, rules, ct);
                await gate.AfterExtractionAsync(ct);
                return document;
            });
        var index = new FolderIndexCoordinator(store, admission, clock,
            (_, _) => Task.FromResult<FolderEmbeddingSession?>(embedding),
            _ => Task.FromResult<EmbeddingSelection?>(embedding.Selection));
        var queue = new JobQueue(store, clock, admission);
        var runtime = new FolderIngestionRuntime(store, scanner, worker, index, queue, clock, admission,
            new ReleaseSilentWatches(), identity: fs,
            selectedSelection: _ => Task.FromResult<EmbeddingSelection?>(embedding.Selection))
        { AutoDispatch = false };
        var queryEmbedding = new ReleaseQueryEmbedding(embedding.Selection.EndpointRevision);
        var retriever = new Retriever(store, queryEmbedding, () => "wp9:wp9-2d", new VectorMatrixCache(), null);
        var transport = new ReleaseTransport(new PackModel("wp9", "wp9-chat", Fixture.RuntimeContext,
            Fixture.MaxOutputTokens, true, "openai_compatible"), Fixture.Answer);
        var previews = new ContextPreviewSession();
        var coordinator = new ContextPackCoordinator(new CompatibilityPackDataSource(store, retriever),
            new ReleaseTransportFactory(transport));
        var engine = new ChatEngine(store, coordinator, previews, "wp9-chat");
        _graph = new ReleaseGraph
        {
            Store = store, Http = http, Embedding = embedding, Scanner = scanner, Worker = worker, Queue = queue,
            Runtime = runtime, Retriever = retriever, QueryEmbedding = queryEmbedding, Transport = transport,
            Previews = previews, Engine = engine,
        };
    }

    /// <summary>Stops and joins runtime and queue, then disposes the whole graph (store included).</summary>
    internal async Task CloseAsync()
    {
        Gate.Release();
        var graph = _graph;
        if (graph is null) return;
        _graph = null;
        await graph.Runtime.StopAsync();
        await graph.Queue.StopAsync();
        graph.Dispose();
    }

    /// <summary>A new graph over the same database; never re-adds the folder.</summary>
    internal Task ReopenAsync()
    {
        if (_graph is not null) throw new InvalidOperationException("CloseAsync before ReopenAsync");
        MakeGraph();
        return Task.CompletedTask;
    }

    internal void RemoveTemporaryFiles()
    {
        Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
        if (Directory.Exists(Root)) Directory.Delete(Root, true);
    }

    internal async Task DrainAsync()
    {
        for (int i = 0; i < 256; i++)
            if (!await Runtime.DrainOnceAsync()) return;
        throw new InvalidOperationException("durable queue did not quiesce in 256 attempts");
    }

    internal Source Source(string relPath) =>
        Store.Sources(NotebookId).Single(s => s.FolderId == FolderId && s.RelPath == relPath);

    internal Task<PreparedPackHandle> PrepareAsync(RetrievalScope? scope = null, string mode = "answer", int? cap = null)
    {
        var selected = scope ?? new RetrievalScope.Selection(new HashSet<long>(), new HashSet<long> { FolderId });
        var intent = new PackIntent(NotebookId, SessionId, Fixture.Question, mode, selected, "wp9", "wp9-chat", 0,
            Fixture.RuntimeContext, Fixture.MaxOutputTokens, cap, Fixture.FetchK, Fixture.TopK, "", Fixture.Instructions,
            null, false, Store.ContextHistoryFingerprint(SessionId), Store.ContextScopeFingerprint(NotebookId, selected),
            null, null);
        return Engine.PrepareAsync(intent);
    }

    internal Task<ChatMessage> SendAsync(PreparedPackHandle handle) => Engine.SendPreparedAsync(handle, handle.Key, null, null);

    internal int Integer(string sql)
    {
        lock (Store.Gate) return Store.Connection.ExecuteScalar<int>(sql);
    }

    internal string RawCitations(long assistantId)
    {
        lock (Store.Gate)
            return Store.Connection.QuerySingle<string>("SELECT citations_json FROM messages WHERE id=$id",
                new { id = assistantId });
    }

    // Lifecycle operations

    /// <summary>Requests a verify-all scan and runs exactly that scan job (no extraction).</summary>
    internal async Task ScanOnlyAsync()
    {
        Store.RequestFolderScan(FolderId, true, Clock.Now);
        var scanner = Scanner;
        long folderId = FolderId, now = Clock.Now;
        Assert.True(await Queue.RunOneAsync("scan", 0, (_, fence, ct) => scanner.ScanAsync(folderId, true, fence, now, ct)));
    }

    /// <summary>The production startup operation: the runtime's reconciler recovers and schedules watched folders.</summary>
    internal Task ReconcileAsync() => Runtime.StartAsync();

    internal void Append(string caseName)
    {
        var row = Fixture.CaseNamed(caseName);
        File.AppendAllText(System.IO.Path.Combine(FolderPath, row.RelPath!), row.Append!, new UTF8Encoding(false, true));
    }

    internal void Delete(string relPath) => File.Delete(System.IO.Path.Combine(FolderPath, relPath));

    internal Task<PinnedRetrievalCandidates> PoolAsync(string query, bool includeVectors = true) =>
        Retriever.SearchAsync(NotebookId, query,
            new RetrievalScope.Selection(new HashSet<long>(), new HashSet<long> { FolderId }), Fixture.FetchK, includeVectors);

    // Assertions

    /// <summary>Shared expected counts plus real DB observations for one prepared pack.</summary>
    internal async Task AssertPackAsync(PreparedContextRequest request, string caseName)
    {
        var e = Fixture.CaseNamed(caseName).Expected;
        var corpus = request.Coverage.Corpus;
        Assert.Equal(e.Files, corpus.FilesInScope);
        Assert.Equal(e.Searchable, corpus.Searchable);
        Assert.Equal(e.RefreshPending, corpus.RefreshPending);
        Assert.Equal(e.RefreshError, corpus.RefreshError);
        Assert.False(corpus.Partial);
        Assert.NotNull(request.GenerationId);
        Assert.Equal(Store.ActiveGeneration(NotebookId)?.Id, request.GenerationId);
        Assert.Equal(new[] { "rules", "instructions" }, request.Messages[0].Sections.Select(s => s.Kind));
        Assert.Equal(Fixture.RulesText, request.Messages[0].Sections[0].Text);
        Assert.Equal(Fixture.Instructions, request.Messages[0].Sections[1].Text);
        var sections = request.Messages[^1].Sections;
        Assert.Equal(new[] { "scope", "map" }.Concat(Enumerable.Repeat("evidence", 6)).Append("question"),
            sections.Select(s => s.Kind));
        Assert.Equal("[QUESTION]\n" + Fixture.Question + "\n[/QUESTION]", sections[^1].Text);
        string scope = sections[0].Text;
        Assert.Contains("Scope: Folder", scope);
        Assert.Contains("Scan: idle; last complete:", scope);
        Assert.DoesNotContain("last complete: unknown", scope);
        Assert.Contains("Corpus: 6 files; 6 searchable", scope);
        Assert.Contains("Freshness: 0 refresh pending; 0 refresh error", scope);
        Assert.Contains("Turn: 6 passages from 6 files", scope);
        var documentLabels = new HashSet<string>();
        foreach (var asset in Fixture.Assets)
        {
            var source = Source(asset.RelPath);
            Assert.Equal("present", source.Availability);
            Assert.True(source.Eligible);
            long revisionId = Assert.IsType<long>(source.PublishedRevisionId);
            Assert.Equal(asset.CanonicalText, Store.Revision(revisionId)!.Draft.CanonicalText);
            Assert.Contains(asset.RelPath, sections[1].Text);
            var citation = Assert.Single(request.CitationMap.Where(c => c.SourceId == source.Id));
            Assert.Equal(FolderId, citation.FolderId);
            Assert.Equal(asset.RelPath, citation.RelPath);
            Assert.Equal(revisionId, citation.RevisionId);
            Assert.NotEmpty(citation.Spans);
            Assert.Equal(citation.ChunkIds[0], citation.ChunkId);
            Assert.False(string.IsNullOrEmpty(citation.Text));
            var scalars = asset.CanonicalText.EnumerateRunes().ToArray();
            foreach (var span in citation.Spans)
            {
                Assert.InRange(span.Start, 0, span.End - 1);
                Assert.InRange(span.End, span.Start + 1, scalars.Length);
                Assert.Equal(string.Concat(scalars.Skip(checked((int)span.Start)).Take(checked((int)(span.End - span.Start))).Select(r => r.ToString())),
                    citation.Text);
            }
            if (asset.Language is { } language)
            {
                // Labels come from the REAL bundled detector through extraction; the model-visible passage label
                // must equal the gold language.
                Assert.Contains(sections, s => s.Kind == "evidence"
                    && s.Text.Contains(asset.RelPath + " · " + language, StringComparison.Ordinal));
                // Document label (lang-detector-v1 document mode): gold iff its share reaches mixedDominanceBp
                // (7000), else und; no other target language may receive any share.
                using var coverage = JsonDocument.Parse(source.LangCoverage!);
                int goldShare = 0;
                foreach (var share in coverage.RootElement.GetProperty("sharesBp").EnumerateObject())
                {
                    if (share.Name == language) goldShare = share.Value.GetInt32();
                    else Assert.Equal(0, share.Value.GetInt32());
                }
                Assert.Equal(goldShare >= 7000 ? language : "und", source.Lang);
                if (source.Lang is { } label && label != "und") documentLabels.Add(label);
            }
        }
        Assert.Equal(Fixture.Assets.Where(a => a.Language is not null).Select(a => a.Language!).ToHashSet(), documentLabels);
        Assert.Equal("windows-1250", Source("cs/terminal.txt").Encoding);
        Assert.DoesNotContain(Root, Encoding.UTF8.GetString(PreparedContextRequestJson.Encode(request)));
        var pairs = request.SourceRevisions.Select(p => (p.SourceId, p.RevisionId)).ToArray();
        Assert.Equal(pairs.Length, pairs.Distinct().Count());
        Assert.Equal(pairs.OrderBy(p => p.SourceId).ThenBy(p => p.RevisionId), pairs);
        foreach (var citation in request.CitationMap) Assert.Contains((citation.SourceId, citation.RevisionId!.Value), pairs);
        int charged = request.Messages.SelectMany(m => m.Sections).Sum(s => s.Tokens);
        Assert.True(charged + (request.Options.MaxTokens ?? 0) <= Fixture.RuntimeContext);
        using (var pool = await PoolAsync(Fixture.Question))
        {
            Assert.Equal("used", pool.Diagnostics.VectorStatus);
            Assert.Equal(Fixture.Assets.Select(a => Assert.IsType<long>(Source(a.RelPath).Id)).Order(),
                pool.Vector.Select(p => p.Reference.SourceId).Distinct().Order());
        }
        lock (Store.Gate) Assert.Empty(Store.Connection.Query("PRAGMA foreign_key_check"));
    }

    internal static string Sha(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
}

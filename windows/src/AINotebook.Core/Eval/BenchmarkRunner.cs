using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Eval;

public sealed record BenchmarkRevision(long SourceId, long RevisionId, string DocumentId, string ContentHash, string Text,
    IReadOnlyList<ChunkReference> Chunks);

public sealed record BenchmarkCitationAudit(IReadOnlyList<EvalSpan> Packed, int SnapshotsCorrect, int SnapshotsTotal,
    int AnswerMarkersCorrect, int AnswerMarkersTotal, int AnswerGoldSupported, int AnswerMarkersJudged);

/// <summary>One phase event (benchmark-v1 §8 <c>phase</c>): candidate-level phases carry no chunk count.</summary>
public sealed record BenchmarkPhaseEvent(string Phase, string ProfileId, int? Chunks);

/// <summary>A captured candidate: exact identity, frozen effective limit and its strict transport.</summary>
public sealed record BenchmarkCapture(GenerationIdentity Identity, int EffectiveLimit, IStrictEmbeddingTransport Transport,
    IExactTokenCounter? Counter = null);

/// <summary>Observable run counters (fixtures assert them; reports never contain them).</summary>
public sealed class BenchmarkRunCounters
{
    public int Candidates, PerformanceRows, HttpCalls, EmbeddingCalls, ChatCalls, RetrievalCalls, NeighbourCalls;
    public int OpenedPins, ReleasedPins, CompletedMeasuredQueries, WarmupQueriesPerRow, MeasuredQueriesPerRow;
    public bool WriterAwaited, SamplerAwaited, PrivateDatabasesRemoved = true;
    public int LeakedPins => OpenedPins - ReleasedPins;
}

/// <summary>
/// Everything a run takes from the outside world. Live mode wires the captured Ollama adapters;
/// fixture mode wires deterministic fakes and never constructs an HttpClient.
/// </summary>
public sealed class BenchmarkRunEnvironment
{
    public required string Platform { get; init; }
    public required BenchmarkEnvironment Host { get; init; }
    public required Func<EmbeddingProfile, CancellationToken, Task<BenchmarkCapture>> CaptureAsync { get; init; }
    public required Func<EmbeddingProfile, BenchmarkCapture, CancellationToken, Task> VerifyAsync { get; init; }
    public required Func<IReadOnlyList<ChatTurn>, CancellationToken, Task<ChatTokenObservation>> ObserveChatAsync { get; init; }
    /// <summary>Raw-prompt body count observation (calibration only; <c>/api/generate</c> with raw:true).</summary>
    public Func<string, CancellationToken, Task<ChatTokenObservation>>? ObserveRawAsync { get; init; }
    public required Func<long> NowUs { get; init; }
    public required Func<ProcessMemorySampler?> StartSampler { get; init; }
    public required string MemoryMethod { get; init; }
    public int SampleIntervalMs { get; init; } = 100;
    public required string? ChatDigest { get; init; }
    public required string? TokenFamily { get; init; }
    public required string? ShowTemplateSha256 { get; init; }
    public required TokenEstimatorV2 Estimator { get; init; }
    public required string CalibrationHash { get; init; }
    public required string WorkDirectory { get; init; }
    /// <summary>Fixture mode only: each concurrent measured query waits for one more writer completion.</summary>
    public bool PaceConcurrentQueries { get; init; }
    public Action<BenchmarkPhaseEvent>? Trace { get; init; }
    /// <summary>Called before every measured query with (phase, chunks, index); tests inject cancellation here.</summary>
    public Action<string, int, int>? BeforeMeasuredQuery { get; init; }
    public BenchmarkRunCounters Counters { get; } = new();
}

/// <summary>
/// Production retrieval/packing benchmark and chat-token calibration (benchmark-v1 §6, §5; plan Task 9c).
/// Each candidate runs in a private file-backed store that is always removed afterwards.
/// </summary>
public static class BenchmarkRunner
{
    private const int CacheBudgetBytes = 536_870_912;

    public static async Task<BenchmarkReportV1> RunAsync(BenchmarkOptions options, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (options.Command != "benchmark") throw new BenchmarkException("invalidArguments");
        var (corpus, hash) = EvalRunner.Load(options.Root);
        if (options.Mode == "fixture") return await RunAsync(options, corpus, hash, FixtureEnvironment(options), ct).ConfigureAwait(false);
        using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        var env = await LiveEnvironmentAsync(options, http, ct).ConfigureAwait(false);
        return await RunAsync(options, corpus, hash, env, ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Chat-token calibration (benchmark-v1 §5): raw body observations on the chat model fit train rates only;
    /// holdout bodies and complete rendered prompts validate them. Embedding counts never train chat rates.
    /// </summary>
    public static async Task<TokenCalibrationReportV1> CalibrateAsync(BenchmarkOptions options, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (options.Command != "calibrate") throw new BenchmarkException("invalidArguments");
        var (corpus, hash) = EvalRunner.Load(options.Root);
        if (options.Mode == "fixture") return await CalibrateAsync(options, corpus, hash, FixtureEnvironment(options), ct).ConfigureAwait(false);
        using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        var env = await LiveEnvironmentAsync(options, http, ct).ConfigureAwait(false);
        return await CalibrateAsync(options, corpus, hash, env, ct).ConfigureAwait(false);
    }

    internal static async Task<TokenCalibrationReportV1> CalibrateAsync(BenchmarkOptions options, EvalCorpus corpus, string corpusHash,
        BenchmarkRunEnvironment env, CancellationToken ct)
    {
        var observeRaw = env.ObserveRawAsync ?? throw new BenchmarkException("invalidArguments");
        string digest = env.ChatDigest ?? throw new EmbeddingProfileException("embeddingModelUnavailable");
        string family = "ollama:" + digest;
        var documents = corpus.Documents.Select(d => new CalibrationDocument(d.Metadata.DocumentId, d.Metadata.Language, d.Text)).ToArray();
        var queries = corpus.Questions.Select(q => new CalibrationQuery(q.QueryId, q.Language, q.CaseType, q.Text,
            corpus.Gold[q.QueryId].Select(g => g.DocumentId).Distinct(StringComparer.Ordinal).ToArray())).ToArray();
        var plan = TokenCalibration.SamplePlan(documents, queries);
        var docs = documents.ToDictionary(d => d.DocumentId, StringComparer.Ordinal);
        var byQuery = queries.ToDictionary(q => q.QueryId, StringComparer.Ordinal);
        var samples = new List<CalibrationReportSample>();
        foreach (var sample in plan)
        {
            ct.ThrowIfCancellationRequested();
            var observed = await observeRaw(sample.Text(docs, byQuery), ct).ConfigureAwait(false);
            if (observed.PromptTokens < 0) throw new EmbeddingProfileException("invalidTokenCount");
            samples.Add(new(sample.Id, sample.Language, sample.Split, sample.DocumentId, sample.Start, sample.End, sample.Scalars,
                sample.Utf8Bytes, observed.PromptTokens));
        }
        bool counted = samples.All(x => x.Tokens is not null);
        var rates = counted
            ? TokenCalibration.Fit(samples.Where(x => x.Split == "train")
                .Select(x => new TokenSample(x.Id, family, x.Language, "train", x.Scalars, x.Tokens!.Value)).ToArray())
            : [];
        var estimator = rates.Count > 0 ? new TokenEstimatorV2(family, rates) : new TokenEstimatorV2(TokenEstimatorV2.UnverifiedFamily, []);
        var checks = await PromptChecksAsync(options, corpus, plan, estimator, env, ct).ConfigureAwait(false);
        bool complete = counted && checks.All(c => c.ActualTokens is not null);
        var (body, prompt, maxOver, calibrated) = TokenCalibrationReportV1.Summaries(complete, family, samples, rates, checks);
        var report = new TokenCalibrationReportV1("token-calibration-report", 1, complete ? "complete" : "incomplete", corpusHash,
            env.Platform, options.ChatModel, digest, env.Host.OllamaVersion, env.ShowTemplateSha256 ?? new string('0', 64), family,
            ChatMethodNames.OllamaRawPrompt, null, null, null, samples, rates, TokenEstimatorV2.HeadroomBp, checks,
            complete ? body : null, complete ? prompt : null, complete ? maxOver : null, complete && calibrated,
            complete ? null : "tokenCountUnavailable");
        report.Validate();
        return report;
    }

    private static void RemoveEmptyWorkDirectory(BenchmarkRunEnvironment env)
    {
        try
        {
            if (Directory.Exists(env.WorkDirectory) && !Directory.EnumerateFileSystemEntries(env.WorkDirectory).Any())
                Directory.Delete(env.WorkDirectory);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    /// <summary>
    /// Complete rendered-prompt checks for answer/exact-identifier questions. Retrieval here is lexical-only
    /// (no candidate embedder is part of chat calibration); the request is the real WP8 builder output.
    /// </summary>
    private static async Task<IReadOnlyList<CalibrationPromptCheck>> PromptChecksAsync(BenchmarkOptions options, EvalCorpus corpus,
        IReadOnlyList<CalibrationPlanSample> plan, TokenEstimatorV2 estimator, BenchmarkRunEnvironment env, CancellationToken ct)
    {
        string dbPath = Path.Combine(env.WorkDirectory, "wp7-calibration-" + Guid.NewGuid().ToString("N") + ".sqlite");
        Directory.CreateDirectory(env.WorkDirectory);
        try
        {
            using var store = new NotebookStore(new StorePath(dbPath));
            var world = Materialize(store, corpus, ct);
            var splits = plan.Where(p => p.Kind == "query").ToDictionary(p => p.DocumentId!["query:".Length..], p => p.Split, StringComparer.Ordinal);
            var checks = new List<CalibrationPromptCheck>();
            var retriever = new Retriever(store, new NoQueryEmbedding(), () => "calibration");
            var hydrator = new EvidenceHydrator(store.MakeRetrievalReader());
            foreach (var q in corpus.Questions.Where(q => splits.ContainsKey(q.QueryId)).OrderBy(q => q.QueryId, ScalarComparer.Instance))
            {
                ct.ThrowIfCancellationRequested();
                var snapshot = ScopeResolver.Resolve(store, world.Notebooks[q.NotebookId], MapScope(q.Scope, world), "calibration");
                if (snapshot is null) continue;
                using var pool = await retriever.SearchEmbeddedAsync(snapshot, q.Text, null, options.FetchK, ct).ConfigureAwait(false);
                var fused = pool.Fused.Select(c => c.Reference).ToArray();
                var evidence = fused.Length == 0 ? [] : hydrator.Hydrate(pool.Snapshot!, fused, 1);
                var rrf = pool.Fused.ToDictionary(c => c.Reference.ChunkId, c => c.RrfMicro);
                var input = PackInput(options, q, "answer", pool.Snapshot!, world,
                    Passages(evidence.Where(e => !e.IsNeighbour).ToArray(), world, pool.Snapshot!, rrf),
                    Passages(evidence.Where(e => e.IsNeighbour).ToArray(), world, pool.Snapshot!, null), []);
                var request = ContextPackBuilder.Build(input, estimator, Tuning(options));
                var wire = WireMessages(request);
                var observed = await env.ObserveChatAsync(wire, ct).ConfigureAwait(false);
                if (observed.PromptTokens < 0) throw new EmbeddingProfileException("invalidTokenCount");
                long estimated = request.Messages.Sum(m => 4L + m.Sections.Sum(x => (long)x.Tokens));
                string wireHash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(CanonicalJson.Serialize(
                    System.Text.Json.JsonSerializer.SerializeToElement(wire.Select(m => new { role = m.Role.RawValue(), content = m.Content }))))));
                checks.Add(new(q.QueryId, splits[q.QueryId], PreparedHash(request), wireHash, observed.PromptTokens,
                    checked((int)estimated)));
            }
            return checks;
        }
        finally
        {
            foreach (var suffix in new[] { "", "-wal", "-shm", "-journal" })
                try { File.Delete(dbPath + suffix); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            RemoveEmptyWorkDirectory(env);
        }
    }

    internal static async Task<BenchmarkReportV1> RunAsync(BenchmarkOptions options, EvalCorpus corpus, string corpusHash,
        BenchmarkRunEnvironment env, CancellationToken ct)
    {
        var candidates = new List<BenchmarkCandidate>();
        try
        {
            foreach (var id in options.ProfileIds)
            {
                ct.ThrowIfCancellationRequested();
                candidates.Add(await RunCandidateAsync(options, corpus, EmbeddingProfiles.Require(id), env, ct).ConfigureAwait(false));
            }
        }
        finally { RemoveEmptyWorkDirectory(env); }
        var report = new BenchmarkReportV1(BenchmarkReportV1.ContractName, 1, "complete", BenchmarkReportV1.BackendName,
            options.Mode, env.Platform, env.Host,
            new BenchmarkCorpus(corpus.CorpusId, corpusHash, corpus.Documents.Count, corpus.Questions.Count, "2"),
            env.CalibrationHash,
            new BenchmarkParameters(options.FetchK, options.TopK, options.EvidenceShareBp, options.RuntimeContext, options.MaxOutput, options.Seed),
            new BenchmarkChat(options.ChatModel, env.ChatDigest, env.TokenFamily, env.ShowTemplateSha256), candidates);
        try { report.Validate(); }
        catch (BenchmarkException error) when (error.Code == "incompleteMeasurement")
        {
            report = report with { Status = "incomplete" };
            report.Validate();
        }
        return report;
    }

    private static async Task<BenchmarkCandidate> RunCandidateAsync(BenchmarkOptions options, EvalCorpus corpus,
        EmbeddingProfile profile, BenchmarkRunEnvironment env, CancellationToken ct)
    {
        var counters = env.Counters;
        counters.Candidates++;
        void Trace(string phase, int? chunks = null) => env.Trace?.Invoke(new(phase, profile.Id, chunks));
        string dbPath = Path.Combine(env.WorkDirectory, "wp7-" + profile.Id + "-" + Guid.NewGuid().ToString("N") + ".sqlite");
        Directory.CreateDirectory(env.WorkDirectory);
        try
        {
            Trace("inspect");
            BenchmarkCapture capture;
            try { capture = await env.CaptureAsync(profile, ct).ConfigureAwait(false); }
            catch (EmbeddingProfileException error) { return Failed(profile, error.Code, null); }
            var identity = capture.Identity;
            using var store = new NotebookStore(new StorePath(dbPath));
            var world = Materialize(store, corpus, ct);
            var telemetry = new BenchmarkEmbeddingTelemetry();
            var session = new ProviderEmbeddingSession(ProviderConfig.OllamaId + ":" + profile.Model, identity.EndpointRevision,
                identity, profile, new StrictEmbeddingPipeline(capture.Transport, capture.Counter, telemetry), capture.EffectiveLimit);
            try
            {
                Trace("ingest");
                var ingest = await IngestAsync(store, world, identity, session, telemetry, env, ct).ConfigureAwait(false);
                Trace("quality");
                var rows = new List<BenchmarkQualityQuery>();
                var counts = new int[6];
                foreach (var q in corpus.Questions.OrderBy(q => q.QueryId, ScalarComparer.Instance))
                {
                    ct.ThrowIfCancellationRequested();
                    var (row, audit) = await QualityRowAsync(options, corpus, world, store, session, q, env, ct).ConfigureAwait(false);
                    rows.Add(row);
                    counts[0] += audit.SnapshotsCorrect; counts[1] += audit.SnapshotsTotal; counts[2] += audit.AnswerMarkersCorrect;
                    counts[3] += audit.AnswerMarkersTotal; counts[4] += audit.AnswerGoldSupported; counts[5] += audit.AnswerMarkersJudged;
                }
                var performance = new List<BenchmarkPerformance>();
                foreach (int chunks in options.ChunkCounts)
                    performance.AddRange(await PerformanceRowsAsync(options, store, session, profile, chunks, env, ct).ConfigureAwait(false));
                Trace("verifyModels");
                string? error = null;
                try { await env.VerifyAsync(profile, capture, ct).ConfigureAwait(false); }
                catch (EmbeddingProfileException changed) { error = changed.Code; }
                Trace("report");
                return new BenchmarkCandidate(profile.Id, identity, error is null ? "complete" : "failed", error,
                    BenchmarkQuality.Assemble(rows),
                    new BenchmarkCitationCounts(counts[0], counts[1], counts[2], counts[3], counts[4], counts[5], "not_measured"),
                    ingest, performance);
            }
            catch (Exception error) when (error is EmbeddingProfileException or EmbeddingGenerationException or RetrievalException
                                          or ContextPackException or StorageV19Exception && !ct.IsCancellationRequested)
            {
                return Failed(profile, error switch
                {
                    EmbeddingProfileException e => e.Code,
                    EmbeddingGenerationException e => e.Code,
                    RetrievalException e => e.Code,
                    ContextPackException e => e.Code,
                    StorageV19Exception e => e.Code,
                    _ => "providerError",
                }, identity);
            }
        }
        finally
        {
            foreach (var suffix in new[] { "", "-wal", "-shm", "-journal" })
                try { File.Delete(dbPath + suffix); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            counters.PrivateDatabasesRemoved &= !File.Exists(dbPath);
        }
    }

    private static BenchmarkCandidate Failed(EmbeddingProfile profile, string code, GenerationIdentity? identity) => new(profile.Id,
        identity ?? new GenerationIdentity(ProviderConfig.OllamaId, EmbeddingEndpointRevision.Make(ProviderType.Ollama, BenchmarkOptions.DefaultHost),
            profile.Model, null, profile.Dims, "l2", profile.FormatVersion(EmbeddingPurpose.Query),
            profile.FormatVersion(EmbeddingPurpose.Document), "2"),
        "failed", code, BenchmarkQuality.Assemble([]),
        new BenchmarkCitationCounts(0, 0, 0, 0, 0, 0, "not_measured"),
        new BenchmarkIngest(null, null, null, null, null, null, null, null, null, "not_available", 0, null, null), []);

    // ------------------------------------------------------------------ corpus

    internal sealed class World
    {
        public readonly Dictionary<long, long> Notebooks = [];
        public readonly Dictionary<long, long> Folders = [];
        public readonly Dictionary<long, long> Sources = [];
        public readonly Dictionary<long, LoadedEvalDocument> DocumentBySource = [];
        public readonly Dictionary<(long, long), BenchmarkRevision> Revisions = [];
        public readonly Dictionary<long, (BenchmarkRevision Revision, int Start, int End)> Chunks = [];
    }

    private sealed class EvalFolderIdentity(long folderId) : IFolderPathIdentity
    {
        public FolderIdentity Resolve(string rootPath) =>
            new("eval", ["folder", folderId.ToString(CultureInfo.InvariantCulture)], "eval-folder-" + folderId.ToString(CultureInfo.InvariantCulture));
    }

    internal static World Materialize(NotebookStore store, EvalCorpus corpus, CancellationToken ct)
    {
        var world = new World();
        foreach (long id in corpus.Documents.Select(d => d.Metadata.NotebookId).Concat(corpus.Questions.Select(q => q.NotebookId)).Distinct().Order())
            world.Notebooks[id] = store.CreateNotebook("eval-" + id.ToString(CultureInfo.InvariantCulture)).Id!.Value;
        foreach (var (notebookId, folderId) in corpus.Documents.Where(d => d.Metadata.FolderId is not null)
                     .Select(d => (d.Metadata.NotebookId, d.Metadata.FolderId!.Value)).Distinct().OrderBy(x => x.NotebookId).ThenBy(x => x.Item2))
        {
            string name = "folder-" + folderId.ToString(CultureInfo.InvariantCulture);
            world.Folders[folderId] = store.CreateFolder(world.Notebooks[notebookId],
                new FolderDraft("eval://" + name, name, [], [], "{}", "none", false), new EvalFolderIdentity(folderId), 0).Id;
        }
        foreach (var loaded in corpus.Documents.OrderBy(d => d.Metadata.DocumentId, StringComparer.Ordinal))
        {
            ct.ThrowIfCancellationRequested();
            var d = loaded.Metadata;
            var source = store.CreateSource(world.Notebooks[d.NotebookId],
                d.Path.EndsWith(".txt", StringComparison.Ordinal) ? SourceType.Text : SourceType.Markdown, DisplayName(d), null, null);
            long sourceId = source.Id!.Value;
            world.Sources[d.SourceId] = sourceId;
            world.DocumentBySource[sourceId] = loaded;
            if (d.FolderId is long folder) store.AttachSource(sourceId, world.Folders[folder], d.RelPath);
            // Controlled corpus: chunk language comes from the corpus label (a mixed document stays unlabelled).
            string? chunkLanguage = d.Language is "cs" or "sk" or "en" or "de" ? d.Language : null;
            var drafts = ScalarChunker.Chunk(loaded.Text).Select(c => c with { Lang = chunkLanguage, LangInherited = chunkLanguage is not null }).ToArray();
            var revision = store.CommitForegroundRevision(sourceId, new RevisionDraft(d.ContentHash, loaded.Text, 1, 2), drafts, 0,
                "wp7-benchmark");
            var stored = store.Chunks(sourceId);
            var benchmark = new BenchmarkRevision(sourceId, revision.Id, d.DocumentId, d.ContentHash, loaded.Text,
                stored.Select(c => new ChunkReference(c.Id!.Value, sourceId, revision.Id, c.Ord)).ToArray());
            world.Revisions[(sourceId, revision.Id)] = benchmark;
            foreach (var c in stored)
                world.Chunks[c.Id!.Value] = (benchmark, c.CharStart ?? 0, c.CharEnd ?? EmbeddingInput.ScalarCount(c.Text));
        }
        return world;
    }

    private static string DisplayName(EvalDocument d)
    {
        string name = d.RelPath.Contains('/') ? d.RelPath[(d.RelPath.LastIndexOf('/') + 1)..] : d.RelPath;
        return name.Length == 0 ? d.DocumentId : name;
    }

    private static RetrievalScope MapScope(RetrievalScope scope, World world) => scope switch
    {
        RetrievalScope.Selection s => new RetrievalScope.Selection(
            s.SourceIds.Select(id => world.Sources.TryGetValue(id, out var v) ? v : throw new EvalFailure("source_mapping")).ToHashSet(),
            s.FolderIds.Select(id => world.Folders.TryGetValue(id, out var v) ? v : throw new EvalFailure("source_mapping")).ToHashSet()),
        _ => new RetrievalScope.All(),
    };

    /// <summary>Maps a reference through its own revision (never the source's current revision).</summary>
    internal static EvalSpan SpanFor(ChunkReference reference, int start, int end,
        IReadOnlyDictionary<(long, long), BenchmarkRevision> revisions)
    {
        if (!revisions.TryGetValue((reference.SourceId, reference.RevisionId), out var revision))
            throw new EvalFailure("evidence_mapping");
        return new EvalSpan(revision.DocumentId, revision.ContentHash, start, end);
    }

    private static EvalSpan SpanFor(ChunkReference reference, World world)
    {
        if (!world.Chunks.TryGetValue(reference.ChunkId, out var chunk) || chunk.Revision.RevisionId != reference.RevisionId)
            throw new EvalFailure("evidence_mapping");
        return SpanFor(reference, chunk.Start, chunk.End, world.Revisions);
    }

    // ------------------------------------------------------------------ ingestion

    private static async Task<BenchmarkIngest> IngestAsync(NotebookStore store, World world, GenerationIdentity identity,
        ProviderEmbeddingSession session, BenchmarkEmbeddingTelemetry telemetry, BenchmarkRunEnvironment env, CancellationToken ct)
    {
        var sampler = env.StartSampler();
        long start = env.NowUs();
        IReadOnlyList<ProcessMemorySample>? samples = null;
        try
        {
            foreach (long notebookId in world.Notebooks.Values.Order())
            {
                ct.ThrowIfCancellationRequested();
                var generation = await EmbeddingGenerationBuilder.StageAsync(store, notebookId, identity, session, () => 1, ct: ct)
                    .ConfigureAwait(false);
                // Explicit activation only after a complete stage.
                store.ActivateGeneration(generation.Id, 2);
            }
        }
        finally
        {
            if (sampler is not null)
            {
                try { samples = await sampler.StopAsync().ConfigureAwait(false); }
                catch (BenchmarkException) { samples = null; }
                env.Counters.SamplerAwaited = true;
            }
        }
        long elapsed = Math.Max(0, env.NowUs() - start);
        var snapshot = telemetry.Snapshot(EmbeddingPurpose.Document);
        ProcessMemoryPeaks? peaks = samples is { Count: > 0 } ? BenchmarkTelemetry.Peaks(samples) : null;
        return new BenchmarkIngest(snapshot.ServiceTokens, snapshot.SuccessfulTokens, snapshot.RejectedRequests, snapshot.SplitParts,
            elapsed, BenchmarkMath.TokensPerSecondMilli(snapshot.SuccessfulTokens, elapsed), peaks?.RunnerBytes, peaks?.ServerBytes,
            peaks?.CombinedBytes, snapshot.ServiceTokenStatus, snapshot.UncountedRequests, env.MemoryMethod, env.SampleIntervalMs);
    }

    // ------------------------------------------------------------------ quality

    private static readonly IReadOnlyDictionary<string, EvalMetric> NotApplicable =
        EvalMetrics.Names.ToDictionary(n => n, _ => EvalMetric.NotApplicable, StringComparer.Ordinal);

    internal static async Task<(BenchmarkQualityQuery Row, BenchmarkCitationAudit Audit)> QualityRowAsync(BenchmarkOptions options,
        EvalCorpus corpus, World world, NotebookStore store, ProviderEmbeddingSession session, EvalQuestion q,
        BenchmarkRunEnvironment env, CancellationToken ct)
    {
        var counters = env.Counters;
        var selected = corpus.SelectedDocuments(q);
        int filesInScope = selected.Count, withChunks = selected.Count(d => d.Text.Length > 0);
        var scope = MapScope(q.Scope, world);
        var gold = corpus.Gold[q.QueryId];
        var emptyAudit = new BenchmarkCitationAudit([], 0, 0, 0, 0, 0, 0);
        if (scope.IsEmptySelection || q.CaseType == "empty_selection")
        {
            // No retrieval, embedding or chat call; zero evidence creates no citation.
            var row = new EvalQueryRow(q.QueryId, q.Text, q.Language, q.CaseType, "measured", 0, 0, [], [], [], NotApplicable);
            return (new BenchmarkQualityQuery(row, [], [], null, null, null, null), emptyAudit);
        }
        long notebookId = world.Notebooks[q.NotebookId];
        var snapshot = ScopeResolver.Resolve(store, notebookId, scope, session.StorageKey) ?? throw new EvalFailure("source_mapping");
        counters.OpenedPins++;
        var hydrator = new EvidenceHydrator(store.MakeRetrievalReader());
        try
        {
            if (q.CaseType == "overview")
            {
                // Overview bypasses retrieval and embedding: first published chunk per scoped source, no neighbours.
                var firsts = snapshot.Sources.Where(s => s.PublishedRevisionId is not null)
                    .Select(s => world.Revisions[(s.SourceId, s.PublishedRevisionId!.Value)].Chunks.OrderBy(c => c.Ord).FirstOrDefault())
                    .Where(c => c is not null).Select(c => c!).ToArray();
                var passages = hydrator.Hydrate(snapshot, firsts, 0);
                var input = PackInput(options, q, "overview", snapshot, world, [], [], Passages(passages, world, snapshot, null));
                var request = ContextPackBuilder.Build(input, env.Estimator, Tuning(options));
                var answer = await ChatAsync(request, env, ct).ConfigureAwait(false);
                var audit = Audit(request.CitationMap, answer, world.Revisions.Values.ToArray(), gold);
                var row = new EvalQueryRow(q.QueryId, q.Text, q.Language, q.CaseType, "measured", filesInScope, withChunks, [], [], [], NotApplicable);
                return (new BenchmarkQualityQuery(row, audit.Packed, request.CitationMap.Select(BenchmarkCitation.From).ToArray(), answer,
                    PreparedHash(request), null,
                    new BenchmarkOverview(snapshot.FilesInScope, firsts.Length, request.Coverage.Turn.FilesIncluded)), audit);
            }

            long t0 = env.NowUs();
            var vector = (await session.EmbedAsync([q.Text], ct).ConfigureAwait(false))[0];
            counters.EmbeddingCalls++;
            long t1 = env.NowUs();
            var retriever = new Retriever(store, new NoQueryEmbedding(), () => session.StorageKey);
            var owned = snapshot;
            snapshot = null!; // ownership transfers to the pool on success and is closed on failure
            using var pool = await retriever.SearchEmbeddedAsync(owned, q.Text, vector, options.FetchK, ct).ConfigureAwait(false);
            counters.RetrievalCalls++;
            long t2 = env.NowUs();
            var fused = pool.Fused.Select(c => c.Reference).ToArray();
            var evidence = fused.Length == 0 ? [] : hydrator.Hydrate(pool.Snapshot!, fused, 1);
            if (fused.Length > 0) counters.NeighbourCalls++;
            long t3 = env.NowUs();
            var rrf = pool.Fused.ToDictionary(c => c.Reference.ChunkId, c => c.RrfMicro);
            var direct = Passages(evidence.Where(e => !e.IsNeighbour).ToArray(), world, pool.Snapshot!, rrf);
            var neighbours = Passages(evidence.Where(e => e.IsNeighbour).ToArray(), world, pool.Snapshot!, null);
            var packInput = PackInput(options, q, "answer", pool.Snapshot!, world, direct, neighbours, []);
            var prepared = ContextPackBuilder.Build(packInput, env.Estimator, Tuning(options));
            var text = await ChatAsync(prepared, env, ct).ConfigureAwait(false);
            long t4 = env.NowUs();
            var result = Audit(prepared.CitationMap, text, world.Revisions.Values.ToArray(), gold);
            var lexical = pool.Lexical.Select(c => SpanFor(c.Reference, world)).ToArray();
            var vectorSpans = pool.Vector.Select(c => SpanFor(c.Reference, world)).ToArray();
            var fusedSpans = fused.Select(r => SpanFor(r, world)).ToArray();
            var metrics = EvalMetrics.Measure(gold, lexical, fusedSpans, options.TopK, true, result.Packed);
            var evalRow = new EvalQueryRow(q.QueryId, q.Text, q.Language, q.CaseType, "measured", filesInScope, withChunks,
                lexical, vectorSpans, fusedSpans, metrics);
            var timing = new BenchmarkTiming(t1 - t0, t2 - t1, t3 - t2, Math.Max(t4 - t0, (t1 - t0) + (t2 - t1) + (t3 - t2)));
            return (new BenchmarkQualityQuery(evalRow, result.Packed, prepared.CitationMap.Select(BenchmarkCitation.From).ToArray(),
                text, PreparedHash(prepared), timing, null), result);
        }
        finally
        {
            // Either this method still owns the snapshot, or the disposed pool released it.
            if (snapshot is not null) snapshot.Dispose();
            counters.ReleasedPins++;
        }
    }

    private static RagRuntimeTuning Tuning(BenchmarkOptions o) => new(o.FetchK, o.TopK, o.EvidenceShareBp);

    private static string PreparedHash(PreparedContextRequest request) =>
        Convert.ToHexStringLower(SHA256.HashData(PreparedContextRequestJson.Encode(request)));

    /// <summary>Production section transport: each message's ordered section texts joined with a blank line.</summary>
    internal static IReadOnlyList<ChatTurn> WireMessages(PreparedContextRequest request) => request.Messages.Select(m => new ChatTurn(
        m.Role switch { "system" => ChatRole.System, "assistant" => ChatRole.Assistant, _ => ChatRole.User },
        string.Join("\n\n", m.Sections.Select(s => s.Text)))).ToArray();

    private static async Task<string> ChatAsync(PreparedContextRequest request, BenchmarkRunEnvironment env, CancellationToken ct)
    {
        var observed = await env.ObserveChatAsync(WireMessages(request), ct).ConfigureAwait(false);
        env.Counters.ChatCalls++;
        return observed.Text;
    }

    private static PackPassage[] Passages(IReadOnlyList<EvidencePassage> evidence, World world, ResolvedRetrievalScope snapshot,
        IReadOnlyDictionary<long, long>? rrf)
    {
        var scoped = snapshot.Sources.ToDictionary(s => s.SourceId);
        var result = new List<PackPassage>();
        foreach (var e in evidence)
        {
            if (e.Spans.Count != 1 || !scoped.TryGetValue(e.Reference.SourceId, out var source)) continue;
            var d = world.DocumentBySource[e.Reference.SourceId].Metadata;
            result.Add(new PackPassage(e.Reference.ChunkId, e.Reference.SourceId, e.Reference.RevisionId, source.FolderId,
                d.RelPath, DisplayName(d), Language(d.Language), e.Text, e.Reference.Ord, e.Spans[0].Start, e.Spans[0].End,
                e.Spans[0].PageFrom, e.Spans[0].PageTo, rrf is not null && rrf.TryGetValue(e.Reference.ChunkId, out var micro) ? micro : 0, []));
        }
        return result.ToArray();
    }

    private static string Language(string value) => value is "cs" or "de" or "en" or "sk" or "und" or "mixed" ? value : "und";

    private static ContextPackInput PackInput(BenchmarkOptions options, EvalQuestion q, string mode, ResolvedRetrievalScope snapshot,
        World world, PackPassage[] candidates, PackPassage[] neighbours, PackPassage[] overview)
    {
        var sources = snapshot.Sources;
        var files = sources.Select(s =>
        {
            var d = world.DocumentBySource[s.SourceId].Metadata;
            return new PackFile(s.SourceId, s.FolderId, d.RelPath, DisplayName(d), DisplayName(d), false, s.PublishedRevisionId);
        }).ToArray();
        var revisions = sources.Where(s => s.PublishedRevisionId is not null)
            .ToDictionary(s => s.SourceId.ToString(CultureInfo.InvariantCulture), s => s.PublishedRevisionId!.Value, StringComparer.Ordinal);
        var languages = sources.Select(s => Language(world.DocumentBySource[s.SourceId].Metadata.Language)).Distinct().Order(StringComparer.Ordinal).ToArray();
        var scope = snapshot.Scope switch
        {
            RetrievalScope.Selection s => new PackScopeSnapshot("selection", "Selection", s.SourceIds.Order().ToArray(), s.FolderIds.Order().ToArray(),
                languages, null, "idle"),
            _ => new PackScopeSnapshot("all", "Notebook", [], [], languages, null, "idle"),
        };
        return new ContextPackInput(q.Text, mode, "", [], [], candidates, neighbours, overview, files, scope,
            new PackCorpusCoverage(sources.Count, sources.Count, 0, 0, 0, 0, 0, 0, 0, false),
            new PackModel(ProviderConfig.OllamaId, options.ChatModel, options.RuntimeContext, options.MaxOutput, false, "ollama"),
            snapshot.Generation?.Id, revisions, null, options.FetchK, options.TopK);
    }

    private sealed class NoQueryEmbedding : IEmbeddingProducing
    {
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default) =>
            throw new InvalidOperationException("The benchmark embeds queries through its captured session.");
    }

    // ------------------------------------------------------------------ citation audit

    /// <summary>
    /// Structural citation audit (benchmark-v1 §8 <c>audit</c>): a snapshot is correct only with matching
    /// source/revision, one span, exact scalar text, content hash, ordered chunk membership, first chunk,
    /// 240-scalar snippet and a unique marker. Invalid entries stay in the total and leave <c>Packed</c>.
    /// </summary>
    public static BenchmarkCitationAudit Audit(IReadOnlyList<Citation> citations, string answer,
        IReadOnlyList<BenchmarkRevision> revisions, IReadOnlyList<EvalSpan> gold)
    {
        ArgumentNullException.ThrowIfNull(citations);
        ArgumentNullException.ThrowIfNull(answer);
        var duplicates = citations.GroupBy(c => c.Marker).Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet();
        var packed = new List<EvalSpan>();
        var validMarkers = new Dictionary<int, EvalSpan>();
        foreach (var citation in citations)
        {
            if (duplicates.Contains(citation.Marker)) continue;
            if (citation.RevisionId is not long revisionId || citation.Spans.Count != 1 || citation.Text is null) continue;
            var revision = revisions.FirstOrDefault(x => x.SourceId == citation.SourceId && x.RevisionId == revisionId);
            if (revision is null) continue;
            var span = citation.Spans[0];
            var scalars = revision.Text.EnumerateRunes().ToArray();
            if (span.Start < 0 || span.End <= span.Start || span.End > scalars.Length) continue;
            string expected = string.Concat(scalars.Skip(checked((int)span.Start)).Take(checked((int)(span.End - span.Start))).Select(x => x.ToString()));
            if (!string.Equals(expected, citation.Text, StringComparison.Ordinal)
                || EvalCorpus.Sha256(Encoding.UTF8.GetBytes(revision.Text)) != revision.ContentHash) continue;
            var references = revision.Chunks.Where(x => citation.ChunkIds.Contains(x.ChunkId)).OrderBy(x => x.Ord).ThenBy(x => x.ChunkId).ToArray();
            if (citation.ChunkIds.Count == 0 || citation.ChunkIds.Distinct().Count() != citation.ChunkIds.Count
                || !references.Select(x => x.ChunkId).SequenceEqual(citation.ChunkIds)
                || citation.ChunkId != citation.ChunkIds[0]
                || references.Any(x => x.SourceId != citation.SourceId || x.RevisionId != revisionId)
                || !citation.Snippet.EnumerateRunes().SequenceEqual(citation.Text.EnumerateRunes().Take(240))) continue;
            var retained = new EvalSpan(revision.DocumentId, revision.ContentHash, checked((int)span.Start), checked((int)span.End));
            packed.Add(retained);
            validMarkers[citation.Marker] = retained;
        }
        var markers = CitationParser.Markers(answer);
        int correct = 0, supported = 0;
        foreach (int marker in markers)
        {
            if (!validMarkers.TryGetValue(marker, out var retained)) continue;
            correct++;
            if (gold.Count > 0 && EvalMetrics.Recall(gold, [retained]).Found > 0) supported++;
        }
        int valid = packed.Count;
        return new BenchmarkCitationAudit(packed, valid, citations.Count, correct, markers.Count, supported,
            gold.Count > 0 ? markers.Count : 0);
    }

    // ------------------------------------------------------------------ performance

    private static async Task<IReadOnlyList<BenchmarkPerformance>> PerformanceRowsAsync(BenchmarkOptions options, NotebookStore store,
        ProviderEmbeddingSession session, EmbeddingProfile profile, int chunks, BenchmarkRunEnvironment env, CancellationToken ct)
    {
        var rows = new List<BenchmarkPerformance>();
        var handle = SyntheticRetrievalCorpus.Populate(store, chunks, profile.Dims, options.Seed);
        var warmCache = new VectorMatrixCache(CacheBudgetBytes);
        var retriever = new Retriever(store, new NoQueryEmbedding(), () => SyntheticRetrievalCorpus.Model, warmCache, null);
        var hydrator = new EvidenceHydrator(store.MakeRetrievalReader());
        long writerNotebook = store.CreateNotebook("wp7-concurrent-writer-" + chunks.ToString(CultureInfo.InvariantCulture)).Id!.Value;
        int writes = 0;
        if (options.Concurrent is "both" or "off")
            rows.Add(await RowAsync(false).ConfigureAwait(false));
        if (options.Concurrent is "both" or "on")
            rows.Add(await RowAsync(true).ConfigureAwait(false));
        env.Counters.PerformanceRows += rows.Count;
        return rows;

        async Task<BenchmarkPerformance> RowAsync(bool concurrent)
        {
            string phase = concurrent ? "concurrent" : "measure";
            if (concurrent) env.Trace?.Invoke(new("concurrent", profile.Id, chunks));
            ColdCacheMeasurement? cold = null;
            int calls = 0, measured = 0, completedWrites = 0;
            long peakPage = 0;
            env.Counters.WarmupQueriesPerRow = options.Warmup;
            env.Counters.MeasuredQueriesPerRow = options.Queries;
            env.Counters.CompletedMeasuredQueries = 0;
            async Task<long?> Cold()
            {
                if (!concurrent) env.Trace?.Invoke(new("cold", profile.Id, chunks));
                cold = await ColdLoadAsync(store, handle, env, ct).ConfigureAwait(false);
                return cold.ColdCacheLoadUs;
            }
            async Task<BenchmarkTimingSample> Query(int i)
            {
                bool warm = calls++ < options.Warmup;
                if (!concurrent && warm && calls == 1) env.Trace?.Invoke(new("warmup", profile.Id, chunks));
                if (!concurrent && !warm && measured == 0) env.Trace?.Invoke(new("measure", profile.Id, chunks));
                if (!warm)
                {
                    env.BeforeMeasuredQuery?.Invoke(phase, chunks, measured);
                    ct.ThrowIfCancellationRequested();
                    if (concurrent && env.PaceConcurrentQueries)
                    {
                        int before = Volatile.Read(ref completedWrites);
                        while (Volatile.Read(ref completedWrites) == before) { ct.ThrowIfCancellationRequested(); await Task.Yield(); }
                    }
                }
                var sample = await SyntheticQueryAsync(store, handle, retriever, hydrator, session, i, options, env, ct, p => peakPage = Math.Max(peakPage, p))
                    .ConfigureAwait(false);
                if (!warm) { measured++; env.Counters.CompletedMeasuredQueries = measured; }
                return sample;
            }
            Task Write(int batch, CancellationToken token)
            {
                token.ThrowIfCancellationRequested();
                // Real publication in another notebook of the same database (SQL/cache contention only).
                long sourceId = store.CreateSource(writerNotebook, SourceType.Text,
                    "writer-" + Interlocked.Increment(ref writes).ToString(CultureInfo.InvariantCulture) + ".txt", null, null).Id!.Value;
                string text = "concurrent writer batch " + batch.ToString(CultureInfo.InvariantCulture);
                store.CommitForegroundRevision(sourceId, new RevisionDraft(EvalCorpus.Sha256(Encoding.UTF8.GetBytes(text)), text, 1, 2),
                    ScalarChunker.Chunk(text), 3, "wp7-writer");
                Interlocked.Increment(ref completedWrites);
                return Task.CompletedTask;
            }
            BenchmarkPhaseMeasurement phaseResult;
            try
            {
                phaseResult = await BenchmarkMeasurements.RunAsync(options.Queries, options.Warmup, concurrent, env.NowUs, Cold, Query,
                    Write, ct).ConfigureAwait(false);
            }
            finally { if (concurrent) env.Counters.WriterAwaited = true; }
            var statistics = warmCache.Statistics();
            return BenchmarkPerformance.FromSamples(chunks, concurrent, options.Warmup, phaseResult.Samples,
                cold!.ColdCacheLoadUs, cold.CacheMode, cold.CacheMode == "cached" ? statistics.ResidentBytes : 0, peakPage,
                phaseResult.CompletedWrites, phaseResult.OverlapUs);
        }
    }

    private static async Task<ColdCacheMeasurement> ColdLoadAsync(NotebookStore store, SyntheticRetrievalHandle handle,
        BenchmarkRunEnvironment env, CancellationToken ct)
    {
        // A fresh application cache; the timed region is the first pinned search that admits and fills
        // it (no OS cache flush, no query embedding). A refused admission is "streamed" with no cold time.
        var cache = new VectorMatrixCache(CacheBudgetBytes);
        return await BenchmarkMeasurements.ColdCacheLoadAsync(handle.ChunkCount, handle.Dims, CacheBudgetBytes, env.NowUs, async () =>
        {
            var retriever = new Retriever(store, new NoQueryEmbedding(), () => SyntheticRetrievalCorpus.Model, cache, null);
            var owned = ScopeResolver.Resolve(store, handle.NotebookId, new RetrievalScope.All(), SyntheticRetrievalCorpus.Model)
                ?? throw new EvalFailure("source_mapping");
            env.Counters.OpenedPins++;
            try
            {
                using var pool = await retriever.SearchEmbeddedAsync(owned, "needle0", SyntheticRetrievalCorpus.Row(0, handle.Dims).Vector, 1, ct)
                    .ConfigureAwait(false);
            }
            finally { env.Counters.ReleasedPins++; }
        }).ConfigureAwait(false);
    }

    private static async Task<BenchmarkTimingSample> SyntheticQueryAsync(NotebookStore store, SyntheticRetrievalHandle handle,
        Retriever retriever, EvidenceHydrator hydrator, ProviderEmbeddingSession session, int index, BenchmarkOptions options,
        BenchmarkRunEnvironment env, CancellationToken ct, Action<long> peakPage)
    {
        ct.ThrowIfCancellationRequested();
        string query = "needle" + (index % 97).ToString(CultureInfo.InvariantCulture);
        var snapshot = ScopeResolver.Resolve(store, handle.NotebookId, new RetrievalScope.All(), SyntheticRetrievalCorpus.Model)
            ?? throw new EvalFailure("source_mapping");
        env.Counters.OpenedPins++;
        try
        {
            var sample = await RetrievalPerformance.MeasureAsync(snapshot,
                async () => (await session.EmbedAsync([query], ct).ConfigureAwait(false))[0],
                vector => retriever.SearchEmbeddedAsync(snapshot, query, vector, options.FetchK, ct),
                pool =>
                {
                    peakPage(pool.Diagnostics.PeakPageBytes);
                    var top = pool.Fused.Take(options.TopK).Select(c => c.Reference).ToArray();
                    if (top.Length > 0) hydrator.Hydrate(pool.Snapshot!, top, 1);
                    return Task.CompletedTask;
                }, 1_000_000, env.NowUs).ConfigureAwait(false);
            long e = BenchmarkMeasurements.MillisecondsToMicroseconds(sample.QueryEmbeddingMs);
            long r = BenchmarkMeasurements.MillisecondsToMicroseconds(sample.WarmRetrievalMs);
            long h = BenchmarkMeasurements.MillisecondsToMicroseconds(sample.HydrationMs);
            return new BenchmarkTimingSample(index, e, r, h, e + r + h);
        }
        finally { env.Counters.ReleasedPins++; }
    }

    // ------------------------------------------------------------------ environments

    /// <summary>
    /// Fixture mode: unit vector at <c>FNV1a32(formatted UTF-8) mod nativeDims</c>, prompt count = scalar count,
    /// chat answer <c>[1]</c> only when an evidence marker exists, fixed digests and a counter clock.
    /// </summary>
    internal static BenchmarkRunEnvironment FixtureEnvironment(BenchmarkOptions options, string? workDirectory = null)
    {
        long tick = 0;
        long sampleTick = 0;
        var pending = TokenEstimateResource.Bundled();
        return new BenchmarkRunEnvironment
        {
            Platform = OperatingSystem.IsWindows() ? "windows" : "macos",
            Host = new BenchmarkEnvironment("fixture", 17_179_869_184, "fixture", RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant(),
                new string('f', 40), "0.0.0-fixture", "fixture"),
            CaptureAsync = (profile, ct) =>
            {
                ct.ThrowIfCancellationRequested();
                int index = EmbeddingProfiles.Ids.ToList().IndexOf(profile.Id) + 1;
                string digest = "sha256:" + new string("0123456789abcdef"[index % 16], 64);
                int limit = profile.MaxInputTokens;
                var identity = new GenerationIdentity(ProviderConfig.OllamaId,
                    EmbeddingEndpointRevision.Make(ProviderType.Ollama, ProviderApiRoot.Normalize(options.Host)), profile.Model, digest,
                    profile.Dims, "l2", profile.FormatVersion(EmbeddingPurpose.Query, limit), profile.FormatVersion(EmbeddingPurpose.Document, limit), "2");
                return Task.FromResult(new BenchmarkCapture(identity, limit, new FixtureTransport(profile.Dims)));
            },
            VerifyAsync = (_, _, ct) => { ct.ThrowIfCancellationRequested(); return Task.CompletedTask; },
            ObserveChatAsync = (messages, ct) =>
            {
                ct.ThrowIfCancellationRequested();
                bool evidence = messages.Any(m => m.Content.Contains("[1]", StringComparison.Ordinal));
                int prompt = messages.Sum(m => EmbeddingInput.ScalarCount(m.Content));
                return Task.FromResult(new ChatTokenObservation(evidence ? "[1]" : "Not found.", prompt, 1));
            },
            ObserveRawAsync = (text, ct) =>
            {
                ct.ThrowIfCancellationRequested();
                // Synthetic count only (never a measurement): ceil(3/10 per scalar) plus one BOS-like token.
                int n = EmbeddingInput.ScalarCount(text);
                return Task.FromResult(new ChatTokenObservation("x", (n * 3 + 9) / 10 + 1, 1));
            },
            NowUs = () => Interlocked.Add(ref tick, 100),
            StartSampler = () => BenchmarkTelemetry.StartSampler(() => new ProcessMemorySample(Interlocked.Increment(ref sampleTick), 1_000_000, 2_000_000),
                TimeSpan.FromHours(1)),
            MemoryMethod = "fixture",
            ChatDigest = "sha256:" + new string('a', 64),
            TokenFamily = TokenEstimatorV2.UnverifiedFamily,
            ShowTemplateSha256 = new string('e', 64),
            Estimator = new TokenEstimatorV2(TokenEstimatorV2.UnverifiedFamily, []),
            CalibrationHash = pending.PayloadHash,
            WorkDirectory = workDirectory ?? Path.Combine(Path.GetTempPath(), "ainotebook-wp7-" + Guid.NewGuid().ToString("N")),
            PaceConcurrentQueries = true,
        };
    }

    /// <summary>
    /// Deviation from the plan text: the unit lands at <c>FNV1a32 mod outputDims</c> (inside the native vector),
    /// because a unit beyond a Matryoshka prefix would project to the zero vector and fail as invalidEmbedding.
    /// </summary>
    private sealed class FixtureTransport(int outputDims) : IStrictEmbeddingTransport
    {
        public Task<StrictEmbeddingResult> EmbedAsync(string model, string input, int nativeDims, int inputLimit, CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested();
            var vector = new float[nativeDims];
            vector[(int)(BenchmarkMeasurements.Fnv1a32(input) % (uint)Math.Min(outputDims, nativeDims))] = 1;
            return Task.FromResult(new StrictEmbeddingResult(vector, EmbeddingInput.ScalarCount(input), null, null));
        }
    }

    private static async Task<BenchmarkRunEnvironment> LiveEnvironmentAsync(BenchmarkOptions options, HttpClient http, CancellationToken ct)
    {
        var client = new OllamaBenchmarkClient(new Uri(options.Host), http);
        var snapshot = new EmbeddingProviderSnapshot(ProviderConfig.OllamaId, ProviderType.Ollama, client.Root, true, true, true);
        string? chatDigest = EmbeddingProfileCapture.ExactDigest(await client.TagsAsync(ct).ConfigureAwait(false), options.ChatModel);
        string? template = await client.TemplateSha256Async(options.ChatModel, ct).ConfigureAwait(false);
        string? version = await client.VersionAsync(ct).ConfigureAwait(false);
        // The benchmark takes its estimator from the supplied exact-digest calibration; calibration itself starts unverified.
        var resource = options.Calibration is null ? TokenEstimateResource.Bundled()
            : TokenEstimateResource.Parse(await File.ReadAllBytesAsync(options.Calibration, ct).ConfigureAwait(false), production: true);
        string? family = TokenEstimatorV2.ResolveFamily(options.ChatModel, chatDigest, resource.Bindings);
        var estimator = family is null ? new TokenEstimatorV2(TokenEstimatorV2.UnverifiedFamily, []) : new TokenEstimatorV2(family, resource.Rates);
        int? pid = options.OllamaPid;
        var countOptions = new ChatRequestOptions(8192, 1);
        return new BenchmarkRunEnvironment
        {
            Platform = OperatingSystem.IsWindows() ? "windows" : "macos",
            Host = new BenchmarkEnvironment(Environment.GetEnvironmentVariable("PROCESSOR_IDENTIFIER") ?? RuntimeInformation.ProcessArchitecture.ToString(),
                GC.GetGCMemoryInfo().TotalAvailableMemoryBytes, RuntimeInformation.OSDescription,
                RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant(), Environment.GetEnvironmentVariable("AINOTEBOOK_BUILD_COMMIT"),
                version, OperatingSystem.IsMacOS() ? "metal" : "cpu"),
            CaptureAsync = async (profile, token) =>
            {
                var captured = await EmbeddingProfileCapture.CaptureAsync(snapshot, profile, http, token).ConfigureAwait(false);
                return new BenchmarkCapture(captured.Identity, captured.EffectiveLimit, captured.Client);
            },
            VerifyAsync = async (profile, capture, token) =>
            {
                var c = (OllamaBenchmarkClient)capture.Transport;
                await EmbeddingProfileCapture.VerifyDigestAsync(c, capture.Identity, token).ConfigureAwait(false);
                int context = await c.ContextLengthAsync(profile.Model, token).ConfigureAwait(false);
                if (Math.Min(profile.MaxInputTokens, context) != capture.EffectiveLimit) throw new EmbeddingProfileException("embeddingModelChanged");
            },
            // Count-only observations: num_ctx 8192, num_predict 1, temperature 0 (benchmark-v1 §5.3).
            ObserveChatAsync = (messages, token) => client.ObserveChatAsync(options.ChatModel, messages, countOptions, token),
            ObserveRawAsync = (text, token) => client.ObserveRawAsync(options.ChatModel, text, countOptions, token),
            NowUs = () => BenchmarkMeasurements.TicksToMicroseconds(Stopwatch.GetTimestamp(), Stopwatch.Frequency),
            StartSampler = () => pid is int root
                ? BenchmarkTelemetry.StartSampler(() => BenchmarkTelemetry.SampleProcesses(root), TimeSpan.FromMilliseconds(100))
                : null,
            MemoryMethod = OperatingSystem.IsWindows() ? "toolhelp-workingset" : "ps-rss",
            ChatDigest = chatDigest,
            TokenFamily = family,
            ShowTemplateSha256 = template,
            Estimator = estimator,
            CalibrationHash = resource.PayloadHash,
            WorkDirectory = Path.Combine(Path.GetTempPath(), "ainotebook-wp7-" + Guid.NewGuid().ToString("N")),
        };
    }
}

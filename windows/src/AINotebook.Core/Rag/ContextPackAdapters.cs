using System.Globalization;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

// MARK: - Provider transport (WP2)

/// <summary>
/// Freezes the merged WP2 provider session (endpoint, model, limits, adapter) per turn.
/// A plain <see cref="IChatStreaming"/> without session preparation (legacy direct clients
/// and test doubles) receives the flattened logical turns with the frozen model and the
/// request's options, which such a client may ignore.
/// </summary>
public sealed class CompatibilityPackTransportFactory : IPackTransportFactory
{
    /// <summary>Provider ID recorded for clients without provider sessions.</summary>
    public const string DirectProviderId = "direct";

    private readonly IChatStreaming _chat;
    private readonly string _model;
    private readonly NotebookStore? _store;

    public CompatibilityPackTransportFactory(IChatStreaming chat, string model) : this(chat, model, null) { }

    /// <param name="store">Supplies the frozen provider's type and configuration revision.</param>
    public CompatibilityPackTransportFactory(IChatStreaming chat, string model, NotebookStore? store)
    {
        _chat = chat ?? throw new ArgumentNullException(nameof(chat));
        _model = model ?? throw new ArgumentNullException(nameof(model));
        _store = store;
    }

    public async Task<PackTransportDescription> DescribeAsync(string? requestedModel, CancellationToken ct) =>
        (await CaptureAsync(requestedModel, ct).ConfigureAwait(false)).Description;

    public async Task<IPreparedPackTransport> FreezeAsync(PackIntent intent, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(intent);
        string requested = intent.ProviderId == DirectProviderId ? intent.Model : intent.ProviderId + ":" + intent.Model;
        var captured = await CaptureAsync(requested, ct).ConfigureAwait(false);
        var frozen = captured.Description;
        // The intent was captured from an older selection or limits: the caller must recapture.
        if (frozen.Model.ProviderId != intent.ProviderId || frozen.Model.Model != intent.Model
            || frozen.Model.RuntimeContext != intent.RuntimeContext || frozen.Model.MaxOutputTokens != intent.MaxOutputTokens
            || frozen.ConfigurationRevision != intent.ProviderConfigurationRevision)
            throw new StalePreparedRequestException();
        return captured.Transport;
    }

    private async Task<(PackTransportDescription Description, ProviderPackTransport Transport)> CaptureAsync(
        string? requested, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (_chat is IChatSessionPreparing preparing)
        {
            var session = await preparing.PrepareChatAsync(requested, ct).ConfigureAwait(false);
            // The session's adapter is already frozen; type/revision describe that capture.
            var config = _store?.Provider(session.ProviderId);
            var limits = session.Limits;
            var model = new PackModel(session.ProviderId, session.Model, limits.RuntimeContext, limits.MaxOutputTokens,
                !limits.IsAssumed, config?.Type.ToStorageString() ?? ProviderType.Ollama.ToStorageString());
            return (new(model, config is null ? 0 : Revision(config)),
                new ProviderPackTransport(model, session.StorageKey, session, _chat));
        }
        string name = requested ?? _model;
        var defaults = ChatRequestOptions.Defaults;
        var direct = new PackModel(DirectProviderId, name, defaults.RuntimeContext, defaults.MaxOutputTokens,
            false, ProviderType.Ollama.ToStorageString());
        return (new(direct, 0), new ProviderPackTransport(direct, name, null, _chat));
    }

    /// <summary>A JSON-safe digest of the non-secret endpoint configuration.</summary>
    internal static long Revision(ProviderConfig config)
    {
        string text = string.Join('\0', config.Id, config.Type.ToStorageString(), config.BaseUrl,
            config.Enabled ? "1" : "0", config.PrivacyAcknowledged ? "1" : "0");
        byte[] digest = SHA256.HashData(Encoding.UTF8.GetBytes(text));
        return digest.Take(6).Aggregate(0L, (value, b) => (value << 8) | b);
    }
}

internal sealed class ProviderPackTransport(PackModel model, string storageModel,
    ProviderChatSession? session, IChatStreaming chat) : IPreparedPackTransport
{
    public PackModel Model { get; } = model;
    public string StorageModel { get; } = storageModel;

    public IAsyncEnumerable<string> StreamAsync(PreparedContextRequest request, CancellationToken ct)
    {
        var turns = ContextPackRendering.LogicalTurns(request);
        // The frozen session's limits equal request.Model (checked at freeze).
        return session is not null
            ? session.StreamAsync(turns, ct)
            : chat.StreamAsync(Model.Model, turns,
                new ChatRequestOptions(request.Model.RuntimeContext, request.Model.MaxOutputTokens), ct);
    }
}

// MARK: - Pinned data (WP5 retrieval + WP6 coverage/map)

/// <summary>
/// Maps the merged WP5 scoped candidate pool and evidence hydrator plus the WP6 coverage
/// snapshot onto the pinned-read port. Answer mode embeds only the current question;
/// Overview pins the scope without embedding; an empty selection reads nothing.
/// </summary>
public sealed class CompatibilityPackDataSource : IPackDataSource
{
    private readonly NotebookStore _store;
    private readonly Retriever _retriever;
    private readonly IWebSearch? _webSearch;

    public CompatibilityPackDataSource(NotebookStore store, Retriever retriever) : this(store, retriever, null) { }

    /// <param name="webSearch">Existing provider service used once per prepare, only on explicit opt-in.</param>
    public CompatibilityPackDataSource(NotebookStore store, Retriever retriever, IWebSearch? webSearch)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _retriever = retriever ?? throw new ArgumentNullException(nameof(retriever));
        _webSearch = webSearch;
    }

    private sealed record Materialized(PackHistoryTurn[] History, string NotebookName, CoverageSnapshot Coverage,
        IReadOnlyDictionary<long, ContextFolderDetail> Folders);

    public async Task<IPackReadSession> PinAsync(PackIntent intent, PackModel model, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(intent);
        ArgumentNullException.ThrowIfNull(model);
        ct.ThrowIfCancellationRequested();
        Materialized materialized;
        // One gate scope (the store gate is reentrant): validation and the materialized
        // history/coverage/folders observe the same state.
        lock (_store.Gate)
        {
            _store.ContextValidateSession(intent.NotebookId, intent.SessionId);
            var notebook = _store.ContextNotebook(intent.NotebookId);
            // Reject stale captures; never rebuild from a different state.
            if (_store.ContextHistoryFingerprint(intent.SessionId) != intent.HistoryFingerprint
                || _store.ContextScopeFingerprint(intent.NotebookId, intent.Scope) != intent.ScopeFingerprint
                || notebook.Instructions != intent.NotebookInstructions)
                throw new StalePreparedRequestException();
            materialized = new(
                ContextHistory.Turns(_store.Messages(intent.SessionId), intent.RegenerateUserId, intent.ReplacesAssistantId),
                notebook.Name,
                intent.Scope.IsEmptySelection ? new(0, 0, 0, 0, 0, 0, 0, 0, false) : _store.Coverage(intent.NotebookId, intent.Scope),
                _store.ContextFolders(intent.NotebookId));
        }

        var external = new List<PackExternal>();
        if (intent.CurrentNoteContent is { } note && !ContextPackRendering.IsBlank(note))
            external.Add(new("note", "note", note, "und"));
        if (intent.UseWebSearch && _webSearch is not null)
        {
            // Explicit opt-in only, once per prepare, through the existing provider service.
            IReadOnlyList<WebSearchResult> results;
            try { results = await _webSearch.SearchAsync(intent.Question, 5, ct).ConfigureAwait(false); }
            catch (Exception) when (!ct.IsCancellationRequested) { results = []; }
            ct.ThrowIfCancellationRequested();
            external.AddRange(ContextPackLabels.Web(results));
        }

        PinnedRetrievalCandidates? pool = null;
        if (!intent.Scope.IsEmptySelection)
            pool = await _retriever.SearchAsync(intent.NotebookId, intent.Question, intent.Scope, intent.FetchK,
                includeVectors: intent.Mode != "overview", ct).ConfigureAwait(false);
        try
        {
            var snapshot = pool?.Snapshot;
            var sources = snapshot?.Sources ?? [];
            var details = _store.ContextSourceDetails(sources.Select(s => s.SourceId));
            var input = Input(intent, model, materialized, external.ToArray(), snapshot, details, pool?.PathMatches ?? [],
                pool?.PathInventory ?? false);
            return new CompatibilityPackReadSession(_store, pool, input, details);
        }
        catch
        {
            pool?.Dispose();
            throw;
        }
    }

    private static ContextPackInput Input(PackIntent intent, PackModel model, Materialized materialized,
        PackExternal[] external, ResolvedRetrievalScope? snapshot, IReadOnlyDictionary<long, ContextSourceDetail> details,
        IReadOnlyList<PathMatch> pathMatches, bool pathInventory = false)
    {
        var pathRanks = new Dictionary<long, (int Rank, int Date, string Project)>();
        for (int i = 0; i < pathMatches.Count; i++)
            pathRanks.TryAdd(pathMatches[i].SourceId, (i + 1, pathMatches[i].Date, pathMatches[i].Project));
        var sources = snapshot?.Sources ?? [];
        var published = sources.Where(s => s.PublishedRevisionId is not null).ToArray();
        var questionTokens = Tokens(intent.Question);
        var folderMap = published.Select(source =>
        {
            details.TryGetValue(source.SourceId, out var detail);
            var label = ContextPackLabels.Identity(source, detail);
            string haystack = (label.RelPath + "\n" + (detail?.Title ?? "")).ToLowerInvariant();
            return new PackFile(source.SourceId, source.FolderId, label.RelPath, label.DisplayName,
                ContextPackLabels.Descriptor(detail), questionTokens.Any(t => haystack.Contains(t, StringComparison.Ordinal)),
                source.PublishedRevisionId,
                pathRanks.TryGetValue(source.SourceId, out var match) ? match.Rank : null,
                pathRanks.TryGetValue(source.SourceId, out var dated) && dated.Date != 0 ? dated.Date : null,
                pathRanks.TryGetValue(source.SourceId, out var grouped) ? grouped.Project : null);
        }).ToArray();

        int pinnedFiles = sources.Where(s => s.PublishedRevisionId is not null || s.VectorRevisionId is not null)
            .Select(s => s.SourceId).Distinct().Count();
        var coverage = NormalizedCoverage(materialized.Coverage, pinnedFiles);

        var scope = ContextPackLabels.Scope(intent.Scope, materialized.NotebookName, materialized.Folders, sources, details);
        var revisions = published.ToDictionary(s => s.SourceId.ToString(CultureInfo.InvariantCulture), s => s.PublishedRevisionId!.Value);
        return new ContextPackInput(intent.Question, intent.Mode, intent.EffectiveInstructions, materialized.History,
            external, [], [], [], folderMap, scope, coverage, model, snapshot?.Generation?.Id, revisions,
            intent.EvidenceBudgetCap, intent.FetchK, intent.TopK, pathInventory && pathMatches.Count > 0 ? true : null);
    }

    /// <summary>
    /// The builder's coverage invariants (searchable + pending + error == filesInScope,
    /// refreshPending + refreshError &lt;= filesInScope, every pinned file counted) hold for ANY
    /// store snapshot (chat-during-scan-v1 §2). Coverage is read before the retrieval pin; a folder
    /// check, extraction or rule change in between can only make it disagree with the pin, never
    /// fail the turn: a shortfall against the pinned files counts as searchable, negative counts
    /// read as zero, and refresh counts are clamped to the files in scope.
    /// </summary>
    internal static PackCorpusCoverage NormalizedCoverage(CoverageSnapshot c, int pinnedFiles)
    {
        int searchable = Math.Max(0, c.Searchable), pending = Math.Max(0, c.Pending), error = Math.Max(0, c.Error);
        int shortfall = Math.Max(0, pinnedFiles - (searchable + pending + error));
        int filesInScope = searchable + pending + error + shortfall;
        int refreshPending = Math.Min(Math.Max(0, c.RefreshPending), filesInScope);
        return new PackCorpusCoverage(filesInScope, searchable + shortfall, pending, error, Math.Max(0, c.Skipped),
            Math.Max(0, c.Missing), Math.Max(0, c.Unavailable), refreshPending,
            Math.Min(Math.Max(0, c.RefreshError), filesInScope - refreshPending), c.IsLowerBound);
    }

    private static string[] Tokens(string question)
    {
        var tokens = new HashSet<string>(StringComparer.Ordinal);
        var current = new StringBuilder();
        void Flush()
        {
            if (current.ToString().EnumerateRunes().Count() >= 3) tokens.Add(current.ToString());
            current.Clear();
        }
        foreach (var rune in question.ToLowerInvariant().EnumerateRunes())
        {
            if (Rune.IsLetterOrDigit(rune)) current.Append(rune.ToString());
            else Flush();
        }
        Flush();
        return tokens.Order(StringComparer.Ordinal).ToArray();
    }
}

/// <summary>Owns the candidate pool (and with it the WP3 query pin) until disposed.</summary>
internal sealed class CompatibilityPackReadSession : IPackReadSession
{
    private readonly NotebookStore _store;
    private readonly PinnedRetrievalCandidates? _pool;
    private readonly IReadOnlyDictionary<long, ContextSourceDetail> _details;
    private readonly IReadOnlyDictionary<long, ScopedSource> _sources;
    private PackPassage[] _stashedNeighbours = [];
    private int _disposed;

    internal CompatibilityPackReadSession(NotebookStore store, PinnedRetrievalCandidates? pool, ContextPackInput input,
        IReadOnlyDictionary<long, ContextSourceDetail> details)
    {
        _store = store;
        _pool = pool;
        Input = input;
        _details = details;
        _sources = (pool?.Snapshot?.Sources ?? []).ToDictionary(s => s.SourceId);
    }

    public ContextPackInput Input { get; }

    /// <summary>The pool was ranked for the intent's question at pin time; this returns its fused order.</summary>
    public Task<PackHit[]> SearchAsync(string question, int fetchK, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (_pool is null) return Task.FromResult(Array.Empty<PackHit>());
        if (question != Input.Question || fetchK != Input.FetchK) throw new ContextPackException("invalidInput");
        return Task.FromResult(_pool.Fused.Select(c => new PackHit(c.Reference.ChunkId, c.Reference.SourceId,
            c.Reference.RevisionId, c.RrfMicro)).ToArray());
    }

    /// <summary>
    /// Hydrates each hit at its own revision; published neighbours (radius 1) are copied in
    /// the same pinned borrow and returned by <see cref="NeighboursAsync"/>.
    /// </summary>
    public Task<PackPassage[]> HydrateAsync(PackHit[] hits, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (_pool?.Snapshot is not { } snapshot || hits.Length == 0) return Task.FromResult(Array.Empty<PackPassage>());
        var references = new Dictionary<long, ChunkReference>();
        foreach (var candidate in _pool.Fused) references.TryAdd(candidate.Reference.ChunkId, candidate.Reference);
        var rrf = new Dictionary<long, long>();
        foreach (var hit in hits) rrf.TryAdd(hit.ChunkId, hit.RrfMicro);
        var requested = hits.Where(h => references.ContainsKey(h.ChunkId)).Select(h => references[h.ChunkId]).ToArray();
        var passages = new EvidenceHydrator(_store.MakeRetrievalReader()).Hydrate(snapshot, requested, RagContractV1.Pack.NeighborRadius);
        var languages = _store.ContextChunkLanguages(passages.Select(p => p.Reference.ChunkId));
        var mapped = passages.Select(p => Pack(p, p.IsNeighbour ? 0 : rrf.GetValueOrDefault(p.Reference.ChunkId), languages)).ToArray();
        _stashedNeighbours = passages.Zip(mapped).Where(pair => pair.First.IsNeighbour).Select(pair => pair.Second).ToArray();
        return Task.FromResult(passages.Zip(mapped).Where(pair => !pair.First.IsNeighbour).Select(pair => pair.Second).ToArray());
    }

    public Task<PackPassage[]> NeighboursAsync(PackPassage[] passages, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var sources = passages.Select(p => p.SourceId).ToHashSet();
        return Task.FromResult(_stashedNeighbours.Where(p => sources.Contains(p.SourceId)).ToArray());
    }

    /// <summary>First chunk of the published revision of every scoped eligible file.</summary>
    public Task<PackPassage[]> OverviewAsync(CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (_pool?.Snapshot is not { } snapshot) return Task.FromResult(Array.Empty<PackPassage>());
        var revisions = snapshot.Sources.Where(s => s.PublishedRevisionId is not null)
            .ToDictionary(s => s.SourceId, s => s.PublishedRevisionId!.Value);
        var references = _store.ContextFirstChunks(revisions);
        var passages = new EvidenceHydrator(_store.MakeRetrievalReader()).Hydrate(snapshot, references, 0);
        var languages = _store.ContextChunkLanguages(passages.Select(p => p.Reference.ChunkId));
        return Task.FromResult(passages.Where(p => p.Reference.Ord == 0).Select(p => Pack(p, 0, languages)).ToArray());
    }

    public ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 0) _pool?.Dispose();
        return ValueTask.CompletedTask;
    }

    private PackPassage Pack(EvidencePassage passage, long rrfMicro, IReadOnlyDictionary<long, string> languages)
    {
        var reference = passage.Reference;
        _details.TryGetValue(reference.SourceId, out var detail);
        (string RelPath, string DisplayName) label = _sources.TryGetValue(reference.SourceId, out var source)
            ? ContextPackLabels.Identity(source, detail)
            : ($"source-{reference.SourceId}", $"source-{reference.SourceId}");
        var span = passage.Spans.Count > 0 ? passage.Spans[0] : null;
        string language = ContextPackLabels.Language(languages.TryGetValue(reference.ChunkId, out var lang) ? lang : detail?.Lang);
        return new PackPassage(reference.ChunkId, reference.SourceId, reference.RevisionId, source?.FolderId,
            label.RelPath, label.DisplayName, language, passage.Text, reference.Ord, span?.Start, span?.End,
            span?.PageFrom, span?.PageTo, rrfMicro, []);
    }
}

/// <summary>
/// Supplies caller-provided web results (the existing typed <c>SendAsync(webResults:)</c>
/// API) instead of the inner source's own search, so they are never fetched twice.
/// </summary>
internal sealed class SuppliedWebPackDataSource(IPackDataSource inner, IReadOnlyList<WebSearchResult> results) : IPackDataSource
{
    public async Task<IPackReadSession> PinAsync(PackIntent intent, PackModel model, CancellationToken ct)
    {
        var read = await inner.PinAsync(intent with { UseWebSearch = false }, model, ct).ConfigureAwait(false);
        return new Session(read, ContextPackLabels.Web(results));
    }

    private sealed class Session(IPackReadSession read, PackExternal[] web) : IPackReadSession
    {
        public ContextPackInput Input => read.Input with { External = [.. read.Input.External, .. web] };
        public Task<PackHit[]> SearchAsync(string question, int fetchK, CancellationToken ct) => read.SearchAsync(question, fetchK, ct);
        public Task<PackPassage[]> HydrateAsync(PackHit[] hits, CancellationToken ct) => read.HydrateAsync(hits, ct);
        public Task<PackPassage[]> OverviewAsync(CancellationToken ct) => read.OverviewAsync(ct);
        public Task<PackPassage[]> NeighboursAsync(PackPassage[] passages, CancellationToken ct) => read.NeighboursAsync(passages, ct);
        public ValueTask DisposeAsync() => read.DisposeAsync();
    }
}

/// <summary>
/// Model-facing labels. Folder identity is <c>(folderId, relPath)</c>; roots and raw
/// paths never enter a request.
/// </summary>
internal static class ContextPackLabels
{
    private static readonly HashSet<string> Languages = ["en", "cs", "sk", "de", "und", "mixed"];

    internal static string Language(string? value) => value is not null && Languages.Contains(value) ? value : "und";

    /// <summary>A display label with no path, drive or control syntax.</summary>
    internal static string Label(string text, string fallback)
    {
        var builder = new StringBuilder();
        foreach (var rune in text.EnumerateRunes())
        {
            bool forbidden = rune.Value is '/' or '\\' or ':' or < 32 or (>= 127 and <= 159);
            builder.Append(forbidden ? "_" : rune.ToString());
        }
        string value = builder.ToString().Trim(' ');
        return value is "" or "." or ".." ? fallback : value;
    }

    internal static bool ValidRelative(string path) =>
        path.Length > 0 && !path.EnumerateRunes().Any(r => r.Value is '\\' or ':' or < 32 or (>= 127 and <= 159))
        && path.Split('/').All(part => part is not ("" or "." or ".."));

    internal static (string RelPath, string DisplayName) Identity(ScopedSource source, ContextSourceDetail? detail)
    {
        string fallback = $"source-{source.SourceId}";
        if (source.FolderId is not null && source.RelPath is { } rel && ValidRelative(rel))
            return (rel, Label(rel.Split('/')[^1], fallback));
        string name = Label(detail?.Title ?? source.DisplayName, fallback);
        return (name, name);
    }

    /// <summary>
    /// Map descriptors use the published descriptor's title, type and size on one line;
    /// sources without one fall back to their type. The renderer escapes the label.
    /// </summary>
    internal static string Descriptor(ContextSourceDetail? detail)
    {
        if (detail is null) return "";
        if (detail.Descriptor is not { } json) return detail.Type.RawValue();
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return detail.Type.RawValue();
            var parts = new List<string>();
            if (root.TryGetProperty("title", out var title) && title.ValueKind == JsonValueKind.String && title.GetString() is { Length: > 0 } t)
                parts.Add(t);
            if (root.TryGetProperty("type", out var type) && type.ValueKind == JsonValueKind.String && type.GetString() is { Length: > 0 } ty)
                parts.Add(ty);
            if (root.TryGetProperty("pageCount", out var pages) && pages.ValueKind == JsonValueKind.Number && pages.TryGetInt32(out int p) && p > 0)
                parts.Add(FormattableString.Invariant($"{p} p."));
            if (root.TryGetProperty("sheetCount", out var sheets) && sheets.ValueKind == JsonValueKind.Number && sheets.TryGetInt32(out int s) && s > 0)
                parts.Add(FormattableString.Invariant($"{s} sheets"));
            return string.Join(" · ", parts);
        }
        catch (JsonException) { return detail.Type.RawValue(); }
    }

    internal static PackExternal[] Web(IReadOnlyList<WebSearchResult> results) => results
        .Select((r, i) => new PackExternal(FormattableString.Invariant($"web:{i + 1}"), "web",
            FormattableString.Invariant($"[W{i + 1}] {r.Title}\n{r.Snippet}\n{r.Url}"), "und"))
        .ToArray();

    internal static PackScopeSnapshot Scope(RetrievalScope scope, string notebookName,
        IReadOnlyDictionary<long, ContextFolderDetail> folders, IReadOnlyList<ScopedSource> sources,
        IReadOnlyDictionary<long, ContextSourceDetail> details)
    {
        var (kind, sourceIds, folderIds) = PackIntentKey.ScopeParts(scope);
        string name = notebookName;
        IEnumerable<ContextFolderDetail> involved;
        if (scope is RetrievalScope.Selection selection)
        {
            if (sourceIds.Length == 0 && folderIds.Length == 1 && folders.TryGetValue(folderIds[0], out var only))
                name = only.DisplayName;
            else name = notebookName + " (selection)";
            var ids = selection.FolderIds.Concat(sources.Where(s => s.FolderId is not null).Select(s => s.FolderId!.Value)).ToHashSet();
            involved = ids.Where(folders.ContainsKey).Select(id => folders[id]);
        }
        else involved = folders.Values;
        var list = involved.ToArray();
        var states = list.Select(f => f.ScanState).ToHashSet(StringComparer.Ordinal);
        string state = new[] { "scanning", "partial", "error", "unavailable" }.FirstOrDefault(states.Contains) ?? "idle";
        string? lastFullScan = null;
        if (list.Length > 0 && list.All(f => f.LastFullScanAt is not null))
            lastFullScan = DateTimeOffset.FromUnixTimeSeconds(list.Min(f => f.LastFullScanAt!.Value)).UtcDateTime
                .ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        var languages = sources.Where(s => s.PublishedRevisionId is not null)
            .Select(s => details.TryGetValue(s.SourceId, out var d) ? d.Lang : null)
            .Where(l => l is not null && Languages.Contains(l)).Select(l => l!)
            .Distinct(StringComparer.Ordinal).Order(Comparer<string>.Create(ContextPackAlgorithms.CompareScalars)).ToArray();
        return new PackScopeSnapshot(kind, name, sourceIds, folderIds, languages, lastFullScan, state);
    }
}

// MARK: - Native original resolver (WP6 containment)

/// <summary>
/// Revalidates the live source, folder root and physical containment on every click, then
/// asks <see cref="CitationOriginalPolicy"/>. Never opens a file and never falls back from
/// a folder citation to a raw path.
/// </summary>
public sealed class NativeCitationOriginalResolver : ICitationOriginalResolver
{
    private readonly NotebookStore _store;
    private readonly IFolderFileSystem _fileSystem;

    public NativeCitationOriginalResolver(NotebookStore store) : this(store, new NativeFolderFileSystem()) { }

    public NativeCitationOriginalResolver(NotebookStore store, IFolderFileSystem fileSystem)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
    }

    public Task<ResolvedCitationOriginal> ResolveAsync(long notebookId, Citation citation, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(citation);
        ct.ThrowIfCancellationRequested();
        var record = _store.ContextOriginal(notebookId, citation.SourceId);
        if (record is null) return Task.FromResult(new ResolvedCitationOriginal(CitationOriginalDecision.Unavailable));
        if (record.Source.Type == SourceType.Note)
            return Task.FromResult(new ResolvedCitationOriginal(
                record.NoteId is null ? CitationOriginalDecision.Unavailable : CitationOriginalDecision.Available,
                noteId: record.NoteId));
        return Task.FromResult(citation.FolderId is not null || record.Source.FolderId is not null
            ? EvaluateFolder(record, citation) : EvaluateLoose(record, citation));
    }

    private ResolvedCitationOriginal EvaluateFolder(ContextOriginalRecord record, Citation citation)
    {
        string relPath = citation.RelPath ?? record.Source.RelPath ?? "";
        var input = new CitationOriginalInput(relPath, [], [], true, false, false, true,
            record.CurrentRevisionId, citation.RevisionId);
        // Syntax first: a traversal path is unsafe even if the source is gone.
        if (CitationOriginalPolicy.Evaluate(input) == CitationOriginalDecision.Unsafe)
            return new(CitationOriginalDecision.Unsafe);
        if (record.Folder is not { } folder || citation.FolderId is long cited && cited != folder.Id
            || record.Source.RelPath is not { } live || !StringComparer.Ordinal.Equals(live, relPath))
            return new(CitationOriginalDecision.Unavailable);
        try
        {
            var opened = _fileSystem.Resolve(folder.Draft.RootPath);
            if (opened.VolumeId != folder.Identity.VolumeId || opened.RootFileId != folder.Identity.RootFileId
                || !opened.Components.SequenceEqual(folder.Identity.Components, StringComparer.Ordinal))
                return new(CitationOriginalDecision.Unavailable);
            // No-follow descriptor walk: interior/leaf links and escapes fail here.
            _fileSystem.Stat(folder, relPath);
        }
        catch (FolderIngestionException error) when (error.Code is "outsideRoot" or "interiorLink")
        {
            return new(CitationOriginalDecision.Unsafe);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or FolderIngestionException
            or System.ComponentModel.Win32Exception)
        {
            return new(CitationOriginalDecision.Unavailable);
        }
        string physical = Path.Combine(folder.Draft.RootPath, relPath.Replace('/', Path.DirectorySeparatorChar));
        bool exists, regular;
        try
        {
            var info = new FileInfo(physical);
            exists = info.Exists || Directory.Exists(physical);
            regular = info.Exists && info.LinkTarget is null && (info.Attributes & FileAttributes.Directory) == 0;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { exists = regular = false; }
        bool caseSensitive;
        try { caseSensitive = _fileSystem.CaseSensitive(folder); }
        catch (Exception) { caseSensitive = true; }
        // The walk above validated every component without following links, so the
        // resolved identity is the root's canonical components plus the relative ones.
        var root = folder.Identity.Components.ToArray();
        input = input with
        {
            RootComponents = root,
            ResolvedComponents = [.. root, .. relPath.Split('/')],
            CaseSensitive = caseSensitive, Exists = exists, IsRegularFile = regular
        };
        return new(CitationOriginalPolicy.Evaluate(input), physical);
    }

    /// <summary>Loose legacy files use the live source's trusted stored location.</summary>
    private static ResolvedCitationOriginal EvaluateLoose(ContextOriginalRecord record, Citation citation)
    {
        if (record.RawPath is not { } raw || raw.Contains('\0') || !Path.IsPathFullyQualified(raw))
            return new(CitationOriginalDecision.Unavailable);
        string? parent = Path.GetDirectoryName(raw);
        if (parent is null) return new(CitationOriginalDecision.Unavailable);
        string physical, physicalParent;
        bool exists, regular;
        try
        {
            physicalParent = Resolve(parent, directory: true);
            physical = Resolve(raw, directory: false);
            var info = new FileInfo(physical);
            exists = info.Exists || Directory.Exists(physical);
            regular = info.Exists && (info.Attributes & FileAttributes.Directory) == 0;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return new(CitationOriginalDecision.Unavailable);
        }
        var input = new CitationOriginalInput(Path.GetFileName(raw), Components(physicalParent), Components(physical),
            true, exists, regular, true, record.CurrentRevisionId, citation.RevisionId);
        return new(CitationOriginalPolicy.Evaluate(input), physical);
    }

    private static string Resolve(string path, bool directory)
    {
        FileSystemInfo info = directory ? new DirectoryInfo(path) : new FileInfo(path);
        return (info.ResolveLinkTarget(returnFinalTarget: true)?.FullName) ?? Path.GetFullPath(path);
    }

    private static string[] Components(string path) =>
        path.Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries);
}

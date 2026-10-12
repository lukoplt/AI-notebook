using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

/// <summary>
/// Chat turns are prepared once into an immutable context pack (WP8) and the exact
/// prepared request is streamed, retries included. Preparation writes nothing; the user
/// row is appended immediately before the first stream attempt and the assistant row
/// (with packed v2 citations) only after a successful stream.
/// </summary>
public sealed class ChatEngine
{
    private readonly NotebookStore _store;
    private readonly IngestionAdmission? _admission;
    private readonly object _sendingGate = new();
    // Per-session send guard: fingerprint reads plus the user insert of one turn never
    // interleave with another send in the same session.
    private readonly HashSet<long> _sending = [];

    public ContextPackCoordinator Coordinator { get; }
    public ContextPreviewSession Previews { get; }
    public string ChatModel { get; }
    /// <summary>Explicit retrieval overrides; null takes the value from the runtime tuning.</summary>
    public int? TopK { get; }
    public int? FetchK { get; }
    // WP7 runtime tuning (the shipped benchmark decision by default), resolved once per captured
    // intent so a preview and its send hash the same fetchK/topK.
    private readonly Func<RagRuntimeTuning> _tuning;
    public int RetryAttempts { get; }
    public int RetryBackoffMillis { get; }

    /// <summary>
    /// Compatibility constructor: adapts the merged WP5 retriever and the WP2 provider
    /// transport through <see cref="CompatibilityPackDataSource"/> and
    /// <see cref="CompatibilityPackTransportFactory"/>.
    /// </summary>
    public ChatEngine(
        NotebookStore store, Retriever retriever, IChatStreaming chat, string chatModel,
        int? topK = null, int retryAttempts = 2, int retryBackoffMillis = 250,
        IngestionAdmission? admission = null, IWebSearch? webSearch = null)
        : this(store, new ContextPackCoordinator(new CompatibilityPackDataSource(store, retriever, webSearch),
                new CompatibilityPackTransportFactory(chat, chatModel, store)),
            new ContextPreviewSession(), chatModel, retryAttempts, retryBackoffMillis, admission, topK)
    {
    }

    public ChatEngine(NotebookStore store, ContextPackCoordinator coordinator, ContextPreviewSession previews,
        string chatModel, int retryAttempts = 2, int retryBackoffMillis = 250, IngestionAdmission? admission = null,
        int? topK = null, int? fetchK = null, Func<RagRuntimeTuning>? tuning = null)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        Coordinator = coordinator ?? throw new ArgumentNullException(nameof(coordinator));
        Previews = previews ?? throw new ArgumentNullException(nameof(previews));
        ChatModel = chatModel;
        TopK = topK;
        FetchK = fetchK;
        _tuning = tuning ?? RagRuntimeTuning.Bundled;
        RetryAttempts = retryAttempts;
        RetryBackoffMillis = retryBackoffMillis;
        _admission = admission;
    }

    // MARK: - Two-phase API (preview UI)

    /// <summary>
    /// Captures everything a turn depends on from the live selection, store and
    /// arguments. The UI derives <see cref="PackIntentKey.Make"/> from a fresh capture to
    /// detect a stale preview.
    /// </summary>
    public async Task<PackIntent> CaptureIntentAsync(
        long sessionId, long notebookId, string question, RetrievalScope scope,
        string mode = "answer", string? currentNoteContent = null, bool useWebSearch = false,
        string? model = null, string? instructionsOverride = null,
        long? regenerateUserId = null, long? replacesAssistantId = null, bool editUserText = false,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(question);
        ArgumentNullException.ThrowIfNull(scope);
        if (mode is not ("answer" or "overview"))
            throw new ArgumentOutOfRangeException(nameof(mode), mode, "Mode must be answer or overview.");
        ct.ThrowIfCancellationRequested();
        var described = await Coordinator.DescribeAsync(model, ct).ConfigureAwait(false);
        var (fetchK, topK) = Retrieval(TopK, FetchK, _tuning());
        string instructions, history, scopeFingerprint;
        int? cap;
        lock (_store.Gate)
        {
            instructions = _store.ContextNotebook(notebookId).Instructions;
            cap = _store.EvidenceBudgetCap(notebookId);
            history = _store.ContextHistoryFingerprint(sessionId);
            scopeFingerprint = _store.ContextScopeFingerprint(notebookId, scope);
        }
        return new PackIntent(notebookId, sessionId, question, mode, scope, described.Model.ProviderId,
            described.Model.Model, described.ConfigurationRevision, described.Model.RuntimeContext,
            described.Model.MaxOutputTokens, cap, fetchK, topK, instructions, instructionsOverride,
            currentNoteContent, useWebSearch, history, scopeFingerprint, regenerateUserId, replacesAssistantId,
            editUserText);
    }

    /// <summary>Explicit values win; omitted ones come from the tuning; fetchK never drops below topK.</summary>
    internal static (int FetchK, int TopK) Retrieval(int? topK, int? fetchK, RagRuntimeTuning tuning)
    {
        int top = topK ?? tuning.TopK;
        return (Math.Max(fetchK ?? tuning.FetchK, top), top);
    }

    /// <summary>Builds the exact request a later <see cref="SendPreparedAsync"/> streams. Writes nothing.</summary>
    public Task<PreparedPackHandle> PrepareAsync(PackIntent intent, CancellationToken ct = default) =>
        AdmittedAsync(() => Coordinator.PrepareAsync(intent, ct));

    /// <summary>
    /// Streams <c>handle.Request</c> unchanged (including on retries), persists the answer
    /// with its packed citations and retains the sent preview by the real assistant ID.
    /// <paramref name="expectedKey"/> is the key of a freshly captured intent; a mismatch or
    /// changed history/scope throws <see cref="StalePreparedRequestException"/> without a row
    /// or network call; a replay throws <see cref="PreparedRequestConsumedException"/>.
    /// </summary>
    public async Task<ChatMessage> SendPreparedAsync(PreparedPackHandle handle, byte[] expectedKey,
        Action<string>? onToken, Action? onRetry, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(handle);
        long sessionId = handle.Intent.SessionId;
        BeginSending(sessionId);
        try
        {
            return await AdmittedAsync(() => StreamPreparedAsync(handle, expectedKey, onToken, onRetry, ct)).ConfigureAwait(false);
        }
        finally { EndSending(sessionId); }
    }

    // MARK: - Convenience (capture → prepare → send)

    /// <summary>
    /// Typed-scope turn. <see cref="RetrievalScope.All"/> searches the whole notebook; an
    /// explicit selection (sources plus live folder membership, evaluated this turn) searches
    /// exactly that set, and an empty selection yields no evidence — it never widens.
    /// <paramref name="mode"/> is <c>answer</c> or <c>overview</c>. Supplied web results are
    /// labelled outside-folder context of this turn.
    /// </summary>
    public async Task<ChatMessage> SendAsync(
        long sessionId, long notebookId, string userText,
        RetrievalScope scope, string mode = "answer", string? currentNoteContent = null,
        IReadOnlyList<WebSearchResult>? webResults = null, string? model = null,
        string? instructionsOverride = null, Action<string>? onToken = null,
        Action? onRetry = null, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(scope);
        if (mode is not ("answer" or "overview"))
            throw new ArgumentOutOfRangeException(nameof(mode), mode, "Mode must be answer or overview.");
        ct.ThrowIfCancellationRequested();
        BeginSending(sessionId);
        try
        {
            return await AdmittedAsync(() => ReprepareOnStaleAsync(async () =>
            {
                var intent = await CaptureIntentAsync(sessionId, notebookId, userText, scope, mode, currentNoteContent,
                    webResults is { Count: > 0 }, model, instructionsOverride, ct: ct).ConfigureAwait(false);
                var handle = await CoordinatorFor(webResults).PrepareAsync(intent, ct).ConfigureAwait(false);
                return await StreamPreparedAsync(handle, handle.Key, onToken, onRetry, ct).ConfigureAwait(false);
            }, ct)).ConfigureAwait(false);
        }
        finally { EndSending(sessionId); }
    }

    /// <summary>
    /// Old-signature compatibility wrapper for note chat and tests: null or empty
    /// <paramref name="sourceIds"/> keeps the historical whole-notebook meaning. New callers
    /// use the typed-scope overload.
    /// </summary>
    public Task<ChatMessage> SendAsync(
        long sessionId, long notebookId, string userText,
        string? currentNoteContent = null, IReadOnlyCollection<long>? sourceIds = null,
        IReadOnlyList<WebSearchResult>? webResults = null,
        string? model = null, string? instructionsOverride = null,
        Action<string>? onToken = null, Action? onRetry = null, CancellationToken ct = default) =>
        SendAsync(sessionId, notebookId, userText, LegacyScope(sourceIds), "answer", currentNoteContent, webResults,
            model, instructionsOverride, onToken, onRetry, ct);

    /// <summary>
    /// Typed-scope regenerate of the last exchange. The existing user row and the previous
    /// answer stay until the replacement commits. A non-null <paramref name="editedQuestion"/>
    /// is an edit-and-resend: the user row is rewritten in the same commit transaction.
    /// </summary>
    public async Task<ChatMessage> RegenerateAsync(
        long sessionId, long notebookId, RetrievalScope scope, string mode = "answer",
        string? currentNoteContent = null, IReadOnlyList<WebSearchResult>? webResults = null,
        string? model = null, string? instructionsOverride = null, string? editedQuestion = null,
        Action<string>? onToken = null, Action? onRetry = null, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(scope);
        BeginSending(sessionId);
        try
        {
            return await AdmittedAsync(() => ReprepareOnStaleAsync(async () =>
            {
                var (user, assistantId) = RegenerateTarget(sessionId);
                var intent = await CaptureIntentAsync(sessionId, notebookId, editedQuestion ?? user.Content, scope, mode,
                    currentNoteContent, webResults is { Count: > 0 }, model, instructionsOverride,
                    user.Id, assistantId, editedQuestion is not null, ct).ConfigureAwait(false);
                var handle = await CoordinatorFor(webResults).PrepareAsync(intent, ct).ConfigureAwait(false);
                return await StreamPreparedAsync(handle, handle.Key, onToken, onRetry, ct).ConfigureAwait(false);
            }, ct)).ConfigureAwait(false);
        }
        finally { EndSending(sessionId); }
    }

    /// <summary>The last user row and, when answered, its trailing assistant row.</summary>
    public (ChatMessage User, long? AssistantId) RegenerateTarget(long sessionId)
    {
        var history = _store.Messages(sessionId).Where(m => m.Id is not null).OrderBy(m => m.Id!.Value).ToArray();
        long? assistantId = history.Length > 0 && history[^1].Role == ChatRole.Assistant ? history[^1].Id : null;
        var candidates = assistantId is null ? history : history[..^1];
        if (candidates.Length == 0 || candidates[^1].Role != ChatRole.User)
            throw new InvalidOperationException("noUserMessageToRegenerate");
        return (candidates[^1], assistantId);
    }

    private static RetrievalScope LegacyScope(IReadOnlyCollection<long>? sourceIds) => sourceIds is not { Count: > 0 }
        ? new RetrievalScope.All()
        : new RetrievalScope.Selection(sourceIds.ToHashSet(), new HashSet<long>());

    private ContextPackCoordinator CoordinatorFor(IReadOnlyList<WebSearchResult>? webResults) =>
        webResults is { Count: > 0 } ? Coordinator.WithData(new SuppliedWebPackDataSource(Coordinator.Data, webResults)) : Coordinator;

    // MARK: - Guards

    /// <summary>
    /// While a chat phase runs, background indexing holds its next provider batch (question
    /// embedding is never gated). The bracket covers retrieval, streaming, retries,
    /// cancellation and callback failures.
    /// </summary>
    private async Task<T> AdmittedAsync<T>(Func<Task<T>> body)
    {
        Guid? token = _admission?.BeginChat();
        try { return await body().ConfigureAwait(false); }
        finally { if (token is Guid value) _admission!.EndChat(value); }
    }

    /// <summary>
    /// A capture → prepare → send cycle whose scope evidence changed underneath it (a running
    /// folder check or extraction; <see cref="StalePreparedRequestException"/> is thrown before
    /// any row or network call) runs again from the new snapshot, at most
    /// <see cref="ChatSessionState.StaleRepreparations"/> more times (chat-during-scan-v1 §3).
    /// </summary>
    private static async Task<T> ReprepareOnStaleAsync<T>(Func<Task<T>> body, CancellationToken ct)
    {
        for (int attempt = 0; ; attempt++)
        {
            try { return await body().ConfigureAwait(false); }
            catch (StalePreparedRequestException) when (ChatSessionState.ReprepareAfterStale(attempt))
            {
                ct.ThrowIfCancellationRequested();
            }
        }
    }

    private void BeginSending(long sessionId)
    {
        lock (_sendingGate)
            if (!_sending.Add(sessionId)) throw new ChatSendInProgressException();
    }

    private void EndSending(long sessionId)
    {
        lock (_sendingGate) _sending.Remove(sessionId);
    }

    // MARK: - Streaming

    private async Task<ChatMessage> StreamPreparedAsync(PreparedPackHandle handle, byte[] expectedKey,
        Action<string>? onToken, Action? onRetry, CancellationToken ct)
    {
        var intent = handle.Intent;
        if (!handle.KeyEquals(expectedKey)) throw new StalePreparedRequestException();
        if (handle.IsConsumed) throw new PreparedRequestConsumedException();
        lock (_store.Gate)
        {
            if (_store.ContextHistoryFingerprint(intent.SessionId) != intent.HistoryFingerprint
                || _store.ContextScopeFingerprint(intent.NotebookId, intent.Scope) != intent.ScopeFingerprint)
                throw new StalePreparedRequestException();
        }
        // One-shot from here on, whatever the outcome.
        if (!handle.TryConsume()) throw new PreparedRequestConsumedException();
        ct.ThrowIfCancellationRequested();
        if (intent.RegenerateUserId is null) _store.AppendContextUser(intent.SessionId, intent.Question);

        string assembled = await StreamWithRetryAsync(handle, onToken, onRetry, ct).ConfigureAwait(false);

        // Resolve markers against the finished pack; unknown markers are dropped.
        var byMarker = new Dictionary<int, Citation>();
        foreach (var citation in handle.Request.CitationMap) byMarker.TryAdd(citation.Marker, citation);
        var seen = new HashSet<int>();
        var citations = CitationParser.Markers(assembled)
            .Where(m => seen.Add(m) && byMarker.ContainsKey(m))
            .Select(m => byMarker[m]).ToArray();

        var stored = _store.CommitContextAssistant(intent.SessionId, assembled, citations, handle.Transport.StorageModel,
            intent.ReplacesAssistantId, intent.RegenerateUserId, intent.EditUserText ? intent.Question : null);
        if (stored.Id is long assistantId)
        {
            // A preview that cannot be retained (e.g. oversize) never undoes a saved answer.
            if (Previews.Draft(handle.Key) is not null) Previews.PromoteDraft(intent.SessionId, assistantId);
            else
            {
                try { Previews.Retain(ContextPreviewSnapshotJson.Encode(handle.Snapshot), intent.SessionId, assistantId); }
                catch (Exception error) when (error is System.Text.Json.JsonException or ContextPackException) { }
            }
        }
        return stored;
    }

    /// <summary>
    /// Retries reuse the same frozen transport and request (total tries = RetryAttempts + 1).
    /// Auth, refusal, consent, configuration and context-length errors are terminal;
    /// caller cancellation is never retried.
    /// </summary>
    private async Task<string> StreamWithRetryAsync(PreparedPackHandle handle, Action<string>? onToken,
        Action? onRetry, CancellationToken ct)
    {
        int attempt = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                var partial = new System.Text.StringBuilder();
                await foreach (var token in handle.Transport.StreamAsync(handle.Request, ct).WithCancellation(ct).ConfigureAwait(false))
                {
                    partial.Append(token);
                    onToken?.Invoke(token);
                }
                ct.ThrowIfCancellationRequested();
                return partial.ToString();
            }
            catch (Exception ex)
            {
                // Terminal provider errors: retrying cannot help — the user must fix the key
                // (auth), rephrase (refusal), grant consent (FR-A8) or shorten the context.
                if (ex is ProviderAuthException or ProviderRefusalException or ProviderConsentException
                    or ProviderConfigurationException or ProviderContextTooLongException
                    or StalePreparedRequestException or ContextPackException)
                    throw;
                // HttpClient timeouts also surface as OperationCanceledException; retry
                // those, but stop immediately when the caller cancels.
                ct.ThrowIfCancellationRequested();
                if (attempt >= RetryAttempts) throw;
                attempt++;
                // Tokens from the failed attempt already reached onToken; tell the caller
                // to discard its partial answer before the retry appends to it.
                onRetry?.Invoke();
                // Honor a 429's Retry-After over the (much shorter) exponential backoff.
                var backoff = TimeSpan.FromMilliseconds(RetryBackoffMillis * Math.Pow(2, attempt - 1));
                var delay = (ex as ProviderRateLimitException)?.RetryAfter ?? backoff;
                await Task.Delay(delay, ct).ConfigureAwait(false);
            }
        }
    }
}

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.App.Services;          // ILocalizedStrings, ChatEngineHolder, coordinators (Plan 1)
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;

namespace AINotebook.App.ViewModels;

public partial class ChatViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly ChatEngineHolder _chatHolder;
    private readonly NoteJumpCoordinator _noteJump;
    private readonly TabSwitchCoordinator _tabSwitch;
    private readonly ILocalizedStrings _t;
    private readonly IChatStreaming _chatStreaming;
    private readonly ISettingsService _settings;
    private readonly ICitationOriginalResolver _originals;
    private readonly DispatcherQueue _dispatcher;

    private long _notebookId;
    // WP8: the pending draft preparation, whether the open preview shows the draft (vs a
    // sent turn), and a guard so resetting per-turn toggles after capture keeps the handle.
    private CancellationTokenSource? _prepareCts;
    /// <summary>The open preview shows the next message's draft (vs a sent turn's retained context).</summary>
    [ObservableProperty] public partial bool ShowingDraftPreview { get; private set; }
    private bool _suppressInvalidation;
    // Stop: the running send/regenerate/edit (late tokens of a stopped turn are dropped).
    private readonly ChatTurnControl _turn = new();
    /// <summary>The answer the user stopped mid-stream (its row shows "Stopped").</summary>
    public long? StoppedMessageId { get; private set; }

    public ObservableCollection<ChatSession> Sessions { get; } = new();
    public ObservableCollection<MessageViewModel> Messages { get; } = new();

    // WP6: explicit chat scope — whole notebook, or selected folders/sets/sources (an empty selection stays empty).
    public FolderScopeModel Scope { get; }
    // Tier 2a: up to 3 suggested follow-up questions shown after an answer streams in.
    public ObservableCollection<string> Followups { get; } = new();

    [ObservableProperty] public partial ChatSession? SelectedSession { get; set; }
    [ObservableProperty] public partial string Input { get; set; } = "";
    [ObservableProperty] public partial string StreamingDraft { get; set; } = "";
    [ObservableProperty] public partial bool Sending { get; set; }
    [ObservableProperty] public partial string? ErrorMessage { get; set; }
    [ObservableProperty] public partial bool ShowEmptyState { get; set; } = true;

    // C3: edit/regenerate last exchange
    [ObservableProperty] public partial bool CanEditLast { get; set; }
    [ObservableProperty] public partial string EditInput { get; set; } = "";
    [ObservableProperty] public partial bool IsEditMode { get; set; }

    // C4: citation panel
    [ObservableProperty] public partial bool IsCitationPanelOpen { get; set; }
    [ObservableProperty] public partial CitationViewModel? SelectedCitation { get; set; }
    public ObservableCollection<CitationViewModel> PanelCitations { get; } = new();

    // C2: source set picker.
    public ObservableCollection<SourceSet> SourceSets { get; } = new();

    // C5: personas — a named preset of instructions + source set + model.
    // macOS parity: ChatView.swift's persona menu (None / list / New…).
    public ObservableCollection<Persona> Personas { get; } = new();
    [ObservableProperty] public partial Persona? ActivePersona { get; set; }
    [ObservableProperty] public partial string NewPersonaName { get; set; } = "";
    [ObservableProperty] public partial string NewPersonaInstructions { get; set; } = "";

    /// Label on the persona button: the active persona's name, or "Persona".
    public string PersonaButtonText => ActivePersona?.Name ?? _t.Get(StringKey.PersonaMenu);

    // C3: enabled providers offered in the "Regenerate with" menu, so the last
    // answer can be re-generated through a specific provider (macOS parity —
    // ChatView.swift's regenerate Menu). Empty means the menu shows only the
    // plain Regenerate entry.
    public ObservableCollection<ProviderConfig> ChatProviders { get; } = new();
    public bool HasChatProviders => ChatProviders.Count > 0;

    // UI redesign §2.2 composer chips.
    /// <summary>Persona chip is hidden while the notebook has no persona.</summary>
    public bool HasPersonas => Personas.Count > 0;
    /// <summary>Persona chip label: the active persona or "No persona".</summary>
    public string PersonaChipText => ActivePersona?.Name ?? _t.Get(StringKey.PersonaChipNone);
    /// <summary>Model chip label: "Provider · model" for the next send (persona model wins).</summary>
    public string ModelChipText => ModelChip.Format(_store, _settings, ActivePersona?.Model);
    /// <summary>"+ › Web search" is offered only when web search is enabled in Settings (macOS parity).</summary>
    public bool ShowWebSearchOption => _settings.WebSearchEnabled;
    /// <summary>The new-chat state: no thread yet (created by the first send).</summary>
    public bool IsNewChat => SelectedSession is null;
    /// <summary>A failed turn can be retried (send, regenerate or edit) with the same question.</summary>
    [ObservableProperty] public partial bool CanRetry { get; set; }
    /// <summary>Raised when an answer's citation or "sent context" should open the right panel.</summary>
    public event Action? CitationsRequested;
    public event Action? ContextRequested;

    // E3: per-message web search toggle (reset after each send; Core searches once while preparing).
    [ObservableProperty] public partial bool UseWebSearch { get; set; }

    // WP8: per-message Overview mode, the context preview panel and click-time citation status.
    [ObservableProperty] public partial bool OverviewForNextMessage { get; set; }
    [ObservableProperty] public partial bool PreparingContext { get; set; }
    [ObservableProperty] public partial bool IsContextPreviewOpen { get; set; }
    [ObservableProperty] public partial ContextPreviewViewModel? ContextPreview { get; set; }
    [ObservableProperty] public partial string? CitationStatus { get; set; }
    /// <summary>The prepared draft handle; Send streams it unchanged when its key still matches.</summary>
    public PreparedPackHandle? Prepared { get; private set; }

    // Bound to the scope flyout button label (whole notebook / no sources selected / selected items (n)).
    public string ScopeButtonText => Scope.ButtonText;

    public bool HasFollowups => Followups.Count > 0;

    public ChatViewModel(
        NotebookStore store, ChatEngineHolder chatHolder,
        NoteJumpCoordinator noteJump, TabSwitchCoordinator tabSwitch,
        ILocalizedStrings t, IChatStreaming chatStreaming, ISettingsService settings,
        ICitationOriginalResolver originals, DispatcherQueue dispatcher)
    {
        _store = store; _chatHolder = chatHolder;
        _noteJump = noteJump; _tabSwitch = tabSwitch;
        _t = t; _chatStreaming = chatStreaming; _settings = settings;
        _originals = originals; _dispatcher = dispatcher;
        Scope = new FolderScopeModel(store, t.Get);
        _settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(ISettingsService.SelectedChatModel) or nameof(ISettingsService.SelectedChatProviderId))
                OnPropertyChanged(nameof(ModelChipText));
            if (e.PropertyName == nameof(ISettingsService.WebSearchEnabled))
            {
                OnPropertyChanged(nameof(ShowWebSearchOption));
                if (!_settings.WebSearchEnabled) UseWebSearch = false;
            }
        };
        Personas.CollectionChanged += (_, _) => OnPropertyChanged(nameof(HasPersonas));
        Scope.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(FolderScopeModel.ButtonText)) OnPropertyChanged(nameof(ScopeButtonText));
            // Any scope selection change makes a prepared preview stale.
            InvalidatePrepared();
        };
    }

    // Bound to title text + send-enabled gating (mirrors `.disabled(sending || input.isEmpty)`).
    public bool CanSend => !Sending && !PreparingContext && !string.IsNullOrWhiteSpace(Input);
    public bool CanPrepareContext => CanSend;
    partial void OnInputChanged(string value)
    {
        InvalidatePrepared();
        SendCommand.NotifyCanExecuteChanged();
        PrepareContextCommand.NotifyCanExecuteChanged();
    }
    partial void OnSendingChanged(bool value)
    {
        RefreshEmptyState();
        SendCommand.NotifyCanExecuteChanged();
        PrepareContextCommand.NotifyCanExecuteChanged();
    }
    partial void OnPreparingContextChanged(bool value)
    {
        SendCommand.NotifyCanExecuteChanged();
        PrepareContextCommand.NotifyCanExecuteChanged();
    }
    partial void OnUseWebSearchChanged(bool value) => InvalidatePrepared();
    partial void OnOverviewForNextMessageChanged(bool value) => InvalidatePrepared();

    // Session switches drop the draft (retained sent previews of other sessions stay).
    partial void OnSelectedSessionChanged(ChatSession? value)
    {
        OnPropertyChanged(nameof(IsNewChat));
        StoppedMessageId = null;
        _lastAttempt = null;
        CanRetry = false;
        InvalidatePrepared();
        if (!ShowingDraftPreview) { ContextPreview = null; IsContextPreviewOpen = false; }
        _ = ReloadMessagesAsync();
    }

    /// <summary>
    /// WP8: any change to question, scope, persona/model, mode, web flag or session makes a
    /// prepared draft stale: cancel a pending preparation, drop the handle and the draft
    /// preview, and advance the Core draft generation so a late completion is ignored.
    /// </summary>
    private void InvalidatePrepared()
    {
        if (_suppressInvalidation) return;
        _prepareCts?.Cancel();
        _prepareCts = null;
        Prepared = null;
        try { _chatHolder.Engine.Previews.InvalidateDraft(); } catch (Exception) { }
        if (ShowingDraftPreview)
        {
            ContextPreview = null;
            ShowingDraftPreview = false;
        }
        PreparingContext = false;
    }
    partial void OnStreamingDraftChanged(string value) => RefreshEmptyState();
    // The new-chat state hides the conversation, so a running or failed first turn must not count as empty.
    private void RefreshEmptyState() =>
        ShowEmptyState = Messages.Count == 0 && string.IsNullOrEmpty(StreamingDraft) && !Sending
            && string.IsNullOrEmpty(ErrorMessage) && string.IsNullOrEmpty(PendingQuestion);
    partial void OnErrorMessageChanged(string? value) => RefreshEmptyState();

    /// <summary>The question being sent, shown as the user's message until the turn commits.</summary>
    [ObservableProperty] public partial string? PendingQuestion { get; set; }
    partial void OnPendingQuestionChanged(string? value) => RefreshEmptyState();

    public long NotebookId => _notebookId;

    /// <summary>The sidebar owns thread creation: raised when the first send of a new chat created its session.</summary>
    public event Action<ChatSession>? SessionCreated;

    public async Task LoadAsync(long notebookId)
    {
        _notebookId = notebookId;
        LoadScopeSources();
        LoadSourceSets();
        LoadPersonas();
        LoadChatProviders();
        await EnsureSessionsAsync();
    }

    /// <summary>
    /// UI redesign: the shell decides which thread is shown. Loads the notebook's pickers when the
    /// notebook changes, then selects <paramref name="sessionId"/>; null shows the new-chat state
    /// (the session is created by the first send or preview).
    /// </summary>
    public async Task ShowAsync(long notebookId, long? sessionId)
    {
        bool notebookChanged = notebookId != _notebookId;
        if (notebookChanged)
        {
            _notebookId = notebookId;
            LoadScopeSources();
            LoadSourceSets();
            LoadPersonas();
        }
        LoadChatProviders();
        // Already showing it (e.g. the first send just created this thread): keep the running turn.
        if (!notebookChanged && sessionId is long shown && SelectedSession?.Id == shown) return;
        Sessions.Clear();
        try { foreach (var s in _store.ChatSessions(_notebookId)) Sessions.Add(s); }
        catch (Exception ex) { ErrorMessage = ChatErrorText(ex); }
        var target = sessionId is long id ? Sessions.FirstOrDefault(s => s.Id == id) : null;
        if (!ReferenceEquals(SelectedSession, target)) SelectedSession = target;
        else await ReloadMessagesAsync();
    }

    /// <summary>A new chat has no session until its first send/preview; create it titled after the question.</summary>
    private long? EnsureSessionForDraft(string question)
    {
        if (SelectedSession?.Id is long existing) return existing;
        if (_notebookId == 0) return null;
        try
        {
            var created = _store.CreateChatSession(_notebookId, ChatTitles.FromQuestion(question, _t.Get("chatNewSessionTitle")));
            Sessions.Insert(0, created);
            _suppressInvalidation = true;
            try { SelectedSession = created; }
            finally { _suppressInvalidation = false; }
            SessionCreated?.Invoke(created);
            return created.Id;
        }
        catch (Exception ex) { ErrorMessage = ChatErrorText(ex); return null; }
    }

    // C3: providers for the "Regenerate with" menu — enabled ones only, same
    // filter macOS applies (ChatView.swift: `store.providers().filter(\.enabled)`).
    private void LoadChatProviders()
    {
        ChatProviders.Clear();
        try
        {
            foreach (var p in _store.Providers().Where(p => p.Enabled)) ChatProviders.Add(p);
        }
        catch { }
        OnPropertyChanged(nameof(HasChatProviders));
    }

    // C2: load saved source sets for the notebook.
    private void LoadSourceSets()
    {
        SourceSets.Clear();
        try { foreach (var ss in _store.SourceSets(_notebookId)) SourceSets.Add(ss); } catch { }
    }

    [RelayCommand]
    private void ApplySourceSet(SourceSet? set)
    {
        if (set?.Id is not { } id) return;
        // The set stays an ID: its current membership is resolved on every turn.
        Scope.SelectSet(id);
    }

    // C2: delete a saved source set.
    [RelayCommand]
    private void DeleteSourceSet(SourceSet? set)
    {
        if (set?.Id is not { } id) return;
        try
        {
            _store.DeleteSourceSet(id);
            var existing = SourceSets.FirstOrDefault(s => s.Id == id);
            if (existing is not null) SourceSets.Remove(existing);
            // A selected set that is deleted keeps the selection explicit (and possibly empty), never widened.
            Scope.Reload(_notebookId);
        }
        catch (Exception ex) { ErrorMessage = ChatErrorText(ex); }
    }

    // C2: save the current explicit selection (sources, folders and resolved sets) as a named source set.
    [RelayCommand]
    private void CreateSourceSet(string? name)
    {
        var trimmed = name?.Trim();
        if (string.IsNullOrEmpty(trimmed)) return;
        try
        {
            var set = Scope.SaveAsSet(trimmed);
            SourceSets.Add(set);
            Scope.Reload(_notebookId);
        }
        catch (Exception ex) { ErrorMessage = ChatErrorText(ex); }
    }

    // C5: load this notebook's saved personas.
    private void LoadPersonas()
    {
        Personas.Clear();
        try { foreach (var p in _store.Personas(_notebookId)) Personas.Add(p); } catch { }
    }

    /// C5: activate a persona. Its source set (when it has one) narrows the
    /// scope selection immediately; its instructions and model are applied on
    /// the next send, in <see cref="SendCoreAsync"/>.
    [RelayCommand]
    private void ApplyPersona(Persona? persona)
    {
        if (persona is null) return;
        ActivePersona = persona;
        if (persona.SourceSetId is not { } setId) return;
        Scope.SelectSet(setId);
    }

    // C5: back to the notebook's own instructions and the Settings model.
    [RelayCommand]
    private void ClearPersona() => ActivePersona = null;

    /// C5: save a new persona from the name and instructions typed into the
    /// flyout, capturing the current provider:model the way macOS does. A
    /// source set can be attached later; there is no picker for it yet on
    /// either platform.
    [RelayCommand]
    private void CreatePersona()
    {
        var name = NewPersonaName.Trim();
        if (name.Length == 0) return;
        try
        {
            var persona = _store.CreatePersona(
                _notebookId, name, NewPersonaInstructions,
                sourceSetId: null,
                model: $"{_settings.SelectedChatProviderId}:{_settings.SelectedChatModel}");
            NewPersonaName = "";
            NewPersonaInstructions = "";
            Personas.Add(persona);
            ApplyPersona(persona);
        }
        catch (Exception ex) { ErrorMessage = ChatErrorText(ex); }
    }

    partial void OnActivePersonaChanged(Persona? value)
    {
        OnPropertyChanged(nameof(PersonaButtonText));
        OnPropertyChanged(nameof(PersonaChipText));
        OnPropertyChanged(nameof(ModelChipText));
        InvalidatePrepared();
    }

    // WP6: (re)load the scope picker rows; the selection survives reloads and resets only on a notebook switch.
    private void LoadScopeSources()
    {
        try { Scope.Reload(_notebookId); }
        catch (Exception ex) { ErrorMessage = ChatErrorText(ex); }
        OnPropertyChanged(nameof(ScopeButtonText));
    }

    // Mirrors ChatView.ensureSessions(): load sessions; if none, create one.
    private async Task EnsureSessionsAsync()
    {
        try
        {
            Sessions.Clear();
            foreach (var s in _store.ChatSessions(_notebookId)) Sessions.Add(s);
            if (Sessions.Count == 0)
            {
                var created = _store.CreateChatSession(_notebookId, _t.Get("chatNewSessionTitle"));
                Sessions.Add(created);
            }
            SelectedSession = Sessions.FirstOrDefault();
            await ReloadMessagesAsync();
        }
        catch (Exception ex) { ErrorMessage = ChatErrorText(ex); }
    }

    [RelayCommand]
    private async Task NewSessionAsync()
    {
        try
        {
            var s = _store.CreateChatSession(_notebookId, _t.Get("chatNewSessionTitle"));
            Sessions.Insert(0, s);
            SelectedSession = s;
            await ReloadMessagesAsync();
        }
        catch (Exception ex) { ErrorMessage = ChatErrorText(ex); }
    }

    [RelayCommand]
    private async Task DeleteSessionAsync(ChatSession? session)
    {
        if (session?.Id is not { } id) return;
        try
        {
            _store.DeleteChatSession(id);
            _chatHolder.Engine.Previews.Clear(id);
            var existing = Sessions.FirstOrDefault(x => x.Id == id);
            if (existing is not null) Sessions.Remove(existing);
            SelectedSession = Sessions.FirstOrDefault();
            await ReloadMessagesAsync();
        }
        catch (Exception ex) { ErrorMessage = ChatErrorText(ex); }
    }

    private Task ReloadMessagesAsync()
    {
        Messages.Clear();
        PanelCitations.Clear();
        if (SelectedSession?.Id is not { } sid) { RefreshEmptyState(); CanEditLast = false; return Task.CompletedTask; }
        try
        {
            var rows = _store.Messages(sid);
            long? latestUser = rows.LastOrDefault(m => m.Role == ChatRole.User)?.Id;
            long? latestAnswer = rows.Count > 0 && rows[^1].Role == ChatRole.Assistant ? rows[^1].Id : null;
            foreach (var m in rows)
                Messages.Add(new MessageViewModel
                {
                    Message = m,
                    IsLatestUser = m.Id is not null && m.Id == latestUser,
                    IsLatestAssistant = m.Id is not null && m.Id == latestAnswer,
                    IsStopped = m.Id is not null && m.Id == StoppedMessageId,
                });
            // C4: collect all citations from last assistant message for the panel
            var lastAssistant = Messages.LastOrDefault(m => m.IsAssistant);
            if (lastAssistant?.Message?.Citations is { Count: > 0 } cits)
                foreach (var c in cits) PanelCitations.Add(BuildCitationViewModel(c));
        }
        catch (Exception ex) { ErrorMessage = ChatErrorText(ex); }
        CanEditLast = Messages.Count >= 2;
        RefreshEmptyState();
        return Task.CompletedTask;
    }

    // C3: start edit mode for the last user message
    [RelayCommand]
    private void EditLast()
    {
        var lastUser = Messages.LastOrDefault(m => m.Message?.Role == ChatRole.User);
        if (lastUser?.Message is null) return;
        EditInput = lastUser.Message.Content;
        IsEditMode = true;
    }

    // C3: regenerate — delete last exchange, re-send same question
    [RelayCommand]
    private Task RegenerateAsync() => RegenerateCoreAsync(null);

    /// <summary>
    /// C3: regenerate the last answer through a specific provider. The engine
    /// gets a provider-qualified `"{providerId}:{model}"` key, which
    /// <see cref="Services.ProviderRouter.StreamAsync"/> validates against the
    /// providers table and routes accordingly — and which the stored message is
    /// then tagged with. Mirrors ChatView.swift's per-provider regenerate menu.
    /// </summary>
    [RelayCommand]
    private Task RegenerateWithAsync(ProviderConfig? provider) =>
        provider is null
            ? Task.CompletedTask
            : RegenerateCoreAsync($"{provider.Id}:{_settings.SelectedChatModel}");

    /// <summary>
    /// WP8: the existing user row and the previous answer stay until the replacement
    /// commits (Core replaces them in one transaction after a successful stream).
    /// </summary>
    private async Task RegenerateCoreAsync(string? modelOverride)
    {
        if (SelectedSession?.Id is not { } sid) return;
        (ChatMessage User, long? AssistantId) target;
        try { target = _chatHolder.Engine.RegenerateTarget(sid); }
        catch (InvalidOperationException) { return; }
        await SendCoreAsync(modelOverride, new Replacement(target.User.Id!.Value, target.AssistantId, target.User.Content, false));
    }

    // C3: commit edit — the edited question replaces the last user row only after success.
    [RelayCommand]
    private async Task CommitEditAsync()
    {
        if (SelectedSession?.Id is not { } sid) return;
        var text = EditInput.Trim();
        if (text.Length == 0) return;
        (ChatMessage User, long? AssistantId) target;
        try { target = _chatHolder.Engine.RegenerateTarget(sid); }
        catch (InvalidOperationException) { return; }
        await SendCoreAsync(null, new Replacement(target.User.Id!.Value, target.AssistantId, text, true));
    }

    private sealed record Replacement(long UserId, long? AssistantId, string Question, bool Edit);

    /// <summary>The last turn that failed: retry repeats it with the same question and target.</summary>
    private sealed record Attempt(string? ModelOverride, Replacement? Replacement, string Question);
    private Attempt? _lastAttempt;

    /// <summary>Error row "Try again" (spec §2.2): repeats the failed send / regenerate / edit.</summary>
    [RelayCommand]
    private async Task RetryAsync()
    {
        if (_lastAttempt is not { } attempt || Sending) return;
        if (attempt.Replacement is null)
        {
            // A question that already reached the history is answered again, never stored twice
            // (Core ChatSessionState.RetryAfterFailedSend, shared rule with macOS).
            var history = Messages.Select(m => m.Message).ToList();
            if (ChatSessionState.RetryAfterFailedSend(attempt.Question, history) is ChatRetry.Regenerate)
            {
                await RegenerateCoreAsync(attempt.ModelOverride);
                return;
            }
            Input = attempt.Question;
        }
        await SendCoreAsync(attempt.ModelOverride, attempt.Replacement);
    }

    [RelayCommand]
    private void CancelEdit() => IsEditMode = false;

    // C4: open citation panel populated from a specific message's citations
    [RelayCommand]
    private void ShowCitations(MessageViewModel? vm) => ShowCitation(vm, null);

    /// <summary>
    /// Inline [N] chip: the Citations panel lists that answer's citations with N focused
    /// (spec §2.2 — the same panel on both platforms, replacing the popover).
    /// </summary>
    public void ShowCitation(MessageViewModel? vm, int? marker)
    {
        if (vm?.Message?.Citations is not { Count: > 0 } cits) return;
        PanelCitations.Clear();
        int? focus = marker ?? cits[0].Marker;
        foreach (var c in cits)
        {
            var cvm = BuildCitationViewModel(c);
            cvm.IsFocused = c.Marker == focus;
            PanelCitations.Add(cvm);
        }
        SelectedCitation = PanelCitations.FirstOrDefault(c => c.IsFocused);
        CitationStatus = null;
        IsCitationPanelOpen = true;
        CitationsRequested?.Invoke();
    }

    [RelayCommand]
    private void CloseCitationPanel() => IsCitationPanelOpen = false;

    [RelayCommand(CanExecute = nameof(CanSend))]
    private Task SendAsync() => SendCoreAsync(null, null);

    /// <summary>
    /// WP8: captures the turn's intent (question, explicit scope, persona/model, Overview
    /// and web flags, history/scope fingerprints) from the live state.
    /// </summary>
    private Task<PackIntent> CaptureIntentAsync(long sid, string question, string? modelOverride,
        Replacement? replacement, CancellationToken ct, bool? overview = null, bool? useWeb = null)
    {
        // C5: an active persona supplies the model and the instructions unless the caller
        // passed an explicit override (regenerate-with). Blank persona instructions fall
        // through to the notebook's own (FR-C1) rather than blanking the instructions.
        var personaInstructions = string.IsNullOrWhiteSpace(ActivePersona?.Instructions)
            ? null : ActivePersona!.Instructions;
        // Fresh membership snapshot for this turn (sets and folders resolved now); a failure is shown, never
        // silently widened to the whole notebook. An empty selection stays empty.
        RetrievalScope scope = Scope.ResolveForTurn();
        string mode = (overview ?? OverviewForNextMessage) ? "overview" : "answer";
        bool web = useWeb ?? UseWebSearch;
        string? model = modelOverride ?? ActivePersona?.Model;
        var engine = _chatHolder.Engine;
        long notebookId = _notebookId;
        // The store reads run on the thread pool: the UI thread never waits for the store gate
        // while a folder check, extraction or embedding batch holds it (chat-during-scan-v1 §2).
        return Task.Run(() => engine.CaptureIntentAsync(sid, notebookId, question, scope,
            mode, currentNoteContent: null,
            useWebSearch: web, model: model,
            instructionsOverride: personaInstructions, regenerateUserId: replacement?.UserId,
            replacesAssistantId: replacement?.AssistantId, editUserText: replacement?.Edit ?? false, ct: ct), ct);
    }

    /// <summary>
    /// WP8 "Show what will be sent": prepares the current draft once and shows exactly that
    /// request. A stale or cancelled completion (draft edited, session switched) has no effect.
    /// </summary>
    [RelayCommand(CanExecute = nameof(CanPrepareContext))]
    private async Task PrepareContextAsync()
    {
        var text = Input.Trim();
        if (text.Length == 0) return;
        if (EnsureSessionForDraft(text) is not { } sid) return;
        InvalidatePrepared();
        var cts = new CancellationTokenSource();
        _prepareCts = cts;
        var engine = _chatHolder.Engine;
        var status = new ContextPreviewViewModel(_t.Get);
        status.LoadStatus(_t.Get(StringKey.ContextPreviewPreparing));
        ShowingDraftPreview = true;
        ContextPreview = status;
        IsContextPreviewOpen = true;
        ContextRequested?.Invoke();
        PreparingContext = true;
        ErrorMessage = null;
        try
        {
            var intent = await CaptureIntentAsync(sid, text, null, null, cts.Token);
            var key = PackIntentKey.Make(intent);
            ulong generation = engine.Previews.BeginDraft(sid, key);
            var handle = await engine.PrepareAsync(intent, cts.Token);
            if (cts.IsCancellationRequested || !ReferenceEquals(_prepareCts, cts) || SelectedSession?.Id != sid) return;
            engine.Previews.CompleteDraft(generation, key, ContextPreviewSnapshotJson.Encode(handle.Snapshot));
            Prepared = handle;
            var preview = new ContextPreviewViewModel(_t.Get);
            preview.Load(handle.Snapshot);
            ContextPreview = preview;
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) when (ReferenceEquals(_prepareCts, cts))
        {
            // The draft stays in the input box; nothing was written.
            status = new ContextPreviewViewModel(_t.Get);
            status.LoadStatus(ChatErrorText(ex));
            ContextPreview = status;
        }
        finally
        {
            if (ReferenceEquals(_prepareCts, cts)) PreparingContext = false;
        }
    }

    // WP8: a sent turn's retained preview by its persisted assistant ID; never rebuilt from current state.
    [RelayCommand]
    private void ShowSentContext(MessageViewModel? vm)
    {
        if (SelectedSession?.Id is not { } sid || vm?.Message?.Id is not { } id || !vm.IsAssistant) return;
        var preview = new ContextPreviewViewModel(_t.Get);
        var bytes = _chatHolder.Engine.Previews.Sent(sid, id);
        if (bytes is null) preview.LoadUnavailable();
        else
        {
            try { preview.Load(ContextPreviewSnapshotJson.Decode(bytes)); }
            catch (Exception) { preview.LoadUnavailable(); }
        }
        ShowingDraftPreview = false;
        ContextPreview = preview;
        IsContextPreviewOpen = true;
        ContextRequested?.Invoke();
    }

    [RelayCommand]
    private void CloseContextPreview() => IsContextPreviewOpen = false;

    /// <summary>
    /// WP8: resolves the original at click time (current folder root, containment, revision)
    /// and launches only a validated path; note citations keep note navigation. Never uses a
    /// path captured earlier.
    /// </summary>
    [RelayCommand]
    private async Task OpenCitationOriginalAsync(CitationViewModel? cvm)
    {
        if (cvm is null) return;
        CitationStatus = null;
        try
        {
            var resolved = await _originals.ResolveAsync(_notebookId, cvm.Citation);
            cvm.OriginalDecision = resolved.Decision;
            cvm.OriginalStatus = OriginalStatusText(resolved.Decision);
            CitationStatus = cvm.OriginalStatus;
            if (resolved.NoteId is long noteId) { RequestOpenNote(noteId); return; }
            if (resolved.Path is { } path) await Windows.System.Launcher.LaunchUriAsync(new Uri(path));
        }
        catch (Exception)
        {
            cvm.OriginalDecision = CitationOriginalDecision.Unavailable;
            cvm.OriginalStatus = CitationStatus = _t.Get(StringKey.CitationOriginalUnavailable);
        }
    }

    public string? OriginalStatusText(CitationOriginalDecision decision) => decision switch
    {
        CitationOriginalDecision.Changed => _t.Get(StringKey.CitationRevisionChanged),
        CitationOriginalDecision.Unavailable => _t.Get(StringKey.CitationOriginalUnavailable),
        CitationOriginalDecision.Unsafe => _t.Get(StringKey.CitationOriginalOutsideFolder),
        _ => null
    };

    /// <param name="modelOverride">
    /// Provider-qualified `"{providerId}:{model}"` key for FR-C3 regenerate-
    /// with-model, or null for the default path (the router then uses the live
    /// Settings selection).
    /// </param>
    /// <param name="replacement">Regenerate/edit target; null for a new turn.</param>
    private async Task SendCoreAsync(string? modelOverride, Replacement? replacement)
    {
        var text = replacement?.Question ?? Input.Trim();
        if (text.Length == 0) return;
        long? ensured = replacement is null ? EnsureSessionForDraft(text) : SelectedSession?.Id;
        if (ensured is not { } sid) return;
        var (ct, generation) = _turn.Begin();
        StoppedMessageId = null;
        Sending = true;
        ErrorMessage = null;
        CanRetry = false;
        _lastAttempt = new Attempt(modelOverride, replacement, text);
        PendingQuestion = replacement is null ? text : null;
        StreamingDraft = "";
        ClearFollowups();
        var engine = _chatHolder.Engine;
        // Rows newer than this belong to this turn (a stopped empty turn removes its question).
        long? newestIdBeforeSend = Messages.Select(m => m.Message.Id).Max();
        PreparedPackHandle? sent = null;
        // Per-turn toggles are captured once: a re-preparation after a background change
        // (below) must describe the same turn.
        bool overview = OverviewForNextMessage, useWeb = UseWebSearch;
        try
        {
            for (int attempt = 0; ; attempt++)
            {
                var intent = await CaptureIntentAsync(sid, text, modelOverride, replacement, ct, overview, useWeb);
                var key = PackIntentKey.Make(intent);
                try
                {
                    // Send the previewed handle when it still matches a fresh capture; else prepare once.
                    var handle = attempt == 0 && Prepared is { IsConsumed: false } ready && ready.Key.AsSpan().SequenceEqual(key)
                        ? ready : await Task.Run(() => engine.PrepareAsync(intent, ct), ct);
                    ct.ThrowIfCancellationRequested();
                    sent = handle;
                    // The intent is captured: clear the draft and reset per-turn toggles without
                    // invalidating the handle. The input is cleared only after preparation succeeded.
                    _suppressInvalidation = true;
                    try
                    {
                        if (replacement is null) Input = "";
                        UseWebSearch = false;
                        OverviewForNextMessage = false;
                        IsEditMode = false;
                    }
                    finally { _suppressInvalidation = false; }
                    Prepared = null;
                    if (ShowingDraftPreview)
                    {
                        ShowingDraftPreview = false;
                        ContextPreview = null;
                        IsContextPreviewOpen = false;
                    }

                    Task<ChatMessage> Stream() => engine.SendPreparedAsync(handle, key,
                        onToken: token => _dispatcher.TryEnqueue(() =>
                        {
                            if (_turn.IsCurrent(generation) && Sending) StreamingDraft += token;
                        }),
                        // A retry restarts the answer from scratch, so drop whatever the
                        // failed attempt already streamed instead of appending to it.
                        onRetry: () => _dispatcher.TryEnqueue(() =>
                        {
                            if (_turn.IsCurrent(generation)) StreamingDraft = "";
                        }),
                        ct: ct);
                    // Off the UI thread: the pre-send check reads the store under its gate.
                    await Task.Run(Stream, ct);
                    break;
                }
                catch (StalePreparedRequestException) when (ChatSessionState.ReprepareAfterStale(attempt))
                {
                    // A running folder check / extraction changed the scope's evidence between capture
                    // and send; nothing was written. Prepare the same turn again from the new snapshot
                    // (chat-during-scan-v1 §3).
                    sent = null;
                }
            }
            _lastAttempt = null;
            PendingQuestion = null;
            await ReloadMessagesAsync();
            await GenerateFollowupsAsync(text);
        }
        catch (Exception) when (_turn.StopRequested && _turn.IsCurrent(generation))
        {
            // Stopped by the user: not an error. Before streaming the question is still in the
            // input; while streaming a new turn keeps its partial answer, a regenerate/edit keeps
            // the previous exchange (Core replaces it only after a complete stream).
            _lastAttempt = null;
            PendingQuestion = null;
            // Stopped before any text arrived: the question returns to the composer.
            bool returnsQuestion = WithdrawStoppedQuestion(sid, sent, replacement is not null, text, newestIdBeforeSend);
            KeepStoppedAnswer(sid, sent, isReplacement: replacement is not null);
            if (replacement is { Edit: true } && sent is not null)
            {
                // The edited question returns to the edit card.
                EditInput = text;
                IsEditMode = true;
            }
            else if (returnsQuestion)
            {
                Input = text;
            }
            await ReloadMessagesAsync();
        }
        catch (Exception ex)
        {
            PendingQuestion = null;
            ErrorMessage = ChatErrorText(ex);
            await ReloadMessagesAsync();
            CanRetry = _lastAttempt is not null;
        }
        finally
        {
            _turn.End(generation);
            Sending = false;
            StreamingDraft = "";
            RefreshEmptyState();
        }
    }

    /// <summary>
    /// Composer Stop (replaces Send while an answer is prepared or streams): cancels the running
    /// turn. Not an error — no error row; a new turn keeps what has streamed so far.
    /// </summary>
    [RelayCommand]
    private void Stop()
    {
        if (Sending) _turn.Stop();
    }

    /// <summary>A stopped new turn keeps its partial answer (see <see cref="StoppedTurn.Persist"/>).</summary>
    private void KeepStoppedAnswer(long sessionId, PreparedPackHandle? handle, bool isReplacement)
    {
        try { StoppedMessageId = StoppedTurn.Persist(_store, sessionId, handle, StreamingDraft, isReplacement)?.Id; }
        catch (Exception ex) { ErrorMessage = ChatErrorText(ex); }
    }

    /// <summary>A stopped empty new turn removes its saved question (see <see cref="StoppedTurn.WithdrawQuestion"/>).</summary>
    private bool WithdrawStoppedQuestion(long sessionId, PreparedPackHandle? handle, bool isReplacement,
        string question, long? newestIdBeforeSend)
    {
        try
        {
            return StoppedTurn.WithdrawQuestion(_store, sessionId, handle, StreamingDraft, isReplacement,
                question, newestIdBeforeSend);
        }
        catch (Exception ex)
        {
            ErrorMessage = ChatErrorText(ex);
            return true; // the question still returns to the composer
        }
    }

    /// <summary>Localized chat failure text; see <see cref="ChatFailureText"/>.</summary>
    public string ChatErrorText(Exception ex) => ChatFailureText.Format(ex, _t.Get);

    // Tier 2a: after the answer lands, ask FollowupSuggester for up to 3 next questions.
    // Best-effort — never surfaces an error (the chat answer already succeeded).
    private async Task GenerateFollowupsAsync(string userText)
    {
        var answer = Messages.LastOrDefault(m => m.IsAssistant)?.Content;
        if (string.IsNullOrWhiteSpace(answer)) return;
        try
        {
            var suggester = new FollowupSuggester(_chatStreaming, _settings.SelectedChatModel);
            var suggestions = await Task.Run(() => suggester.GenerateAsync(userText, answer));
            void Apply()
            {
                Followups.Clear();
                foreach (var q in suggestions.Take(3)) Followups.Add(q);
                OnPropertyChanged(nameof(HasFollowups));
            }
            if (!_dispatcher.HasThreadAccess) _dispatcher.TryEnqueue(Apply); else Apply();
        }
        catch { /* follow-ups are optional; ignore failures */ }
    }

    private void ClearFollowups()
    {
        Followups.Clear();
        OnPropertyChanged(nameof(HasFollowups));
    }

    // Tier 2a: tapping a follow-up chip drops it into the input box ready to send.
    [RelayCommand]
    private void UseFollowup(string? question)
    {
        if (string.IsNullOrWhiteSpace(question)) return;
        Input = question;
        ClearFollowups();
    }

    /// <summary>The note created by the last "Save as note" (the page shows "Saved as a note · Open note").</summary>
    [ObservableProperty] public partial long? SavedNoteId { get; set; }

    // Mirrors MessageBubble "Save as note": title "Chat reply — <date>", origin=Chat, originRef=msg.id.
    [RelayCommand]
    private void SaveAsNote(MessageViewModel? vm)
    {
        if (vm?.Message is not { } msg) return;
        try
        {
            var when = msg.CreatedAt.ToLocalTime().ToString("g", System.Globalization.CultureInfo.CurrentCulture);
            var title = string.Format(System.Globalization.CultureInfo.CurrentCulture, _t.Get(StringKey.ChatReplyNoteTitle), when);
            var note = _store.CreateNote(_notebookId, title, msg.Content, NoteOrigin.Chat, msg.Id);
            SavedNoteId = note.Id;
        }
        catch (Exception ex) { ErrorMessage = ChatErrorText(ex); }
    }

    // Mirrors ChatView.showCitation(): resolve source/page/note metadata for the Flyout.
    public CitationViewModel BuildCitationViewModel(Citation c) => CitationViewModel.Resolve(_store, c);

    /// <summary>Citation "Open note": the shell opens the note as a document (the Citations panel stays put).</summary>
    public void RequestOpenNote(long noteId) => _noteJump.Request(noteId);
}

/// <summary>Sidebar titles for new chats: the first question, on one line, at most 48 characters.</summary>
public static class ChatTitles
{
    public const int MaxLength = 48;

    public static string FromQuestion(string question, string fallback)
    {
        var line = string.Join(' ', (question ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        if (line.Length == 0) return fallback;
        if (line.Length <= MaxLength) return line;
        // Same rule as Swift ShellNavigation.sessionTitle: cut to MaxLength − 1, drop a trailing space, add "…".
        var cut = line[..(MaxLength - 1)];
        if (cut.EndsWith(' ')) cut = cut[..^1];
        return cut + "…";
    }
}

/// <summary>Composer model chip text: "Provider · model" (spec §2.2).</summary>
public static class ModelChip
{
    /// <param name="personaModel">An active persona's provider-qualified "providerId:model", if any.</param>
    public static string Format(NotebookStore store, ISettingsService settings, string? personaModel)
    {
        string providerId = settings.SelectedChatProviderId, model = settings.SelectedChatModel;
        if (!string.IsNullOrWhiteSpace(personaModel) && personaModel.IndexOf(':') is int colon and > 0)
        {
            providerId = personaModel[..colon];
            model = personaModel[(colon + 1)..];
        }
        string name;
        try { name = store.Providers().FirstOrDefault(p => p.Id == providerId)?.Name ?? providerId; }
        catch (Exception) { name = providerId; }
        return string.IsNullOrWhiteSpace(model) ? name : $"{name} · {model}";
    }
}

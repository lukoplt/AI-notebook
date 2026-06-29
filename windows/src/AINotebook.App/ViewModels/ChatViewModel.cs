using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
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
    private readonly IWebSearch _webSearch;
    private readonly DispatcherQueue _dispatcher;

    private long _notebookId;

    public ObservableCollection<ChatSession> Sessions { get; } = new();
    public ObservableCollection<MessageViewModel> Messages { get; } = new();

    // Tier 3: checkable source-scope picker (default = all selected = unscoped).
    public ObservableCollection<ScopeSourceItem> ScopeSources { get; } = new();
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

    // E3: per-message web search toggle.
    [ObservableProperty] public partial bool UseWebSearch { get; set; }

    // Bound to the Sources scope flyout button label ("Sources" / "Sources (2)").
    public string ScopeButtonText
    {
        get
        {
            var selected = ScopeSources.Count(s => s.IsSelected);
            var label = _t.Get(StringKey.ChatScopeButton);
            return (ScopeSources.Count == 0 || selected == ScopeSources.Count)
                ? label : $"{label} ({selected})";
        }
    }

    public bool HasFollowups => Followups.Count > 0;

    public ChatViewModel(
        NotebookStore store, ChatEngineHolder chatHolder,
        NoteJumpCoordinator noteJump, TabSwitchCoordinator tabSwitch,
        ILocalizedStrings t, IChatStreaming chatStreaming, ISettingsService settings,
        IWebSearch webSearch, DispatcherQueue dispatcher)
    {
        _store = store; _chatHolder = chatHolder;
        _noteJump = noteJump; _tabSwitch = tabSwitch;
        _t = t; _chatStreaming = chatStreaming; _settings = settings;
        _webSearch = webSearch; _dispatcher = dispatcher;
    }

    // Bound to title text + send-enabled gating (mirrors `.disabled(sending || input.isEmpty)`).
    public bool CanSend => !Sending && !string.IsNullOrWhiteSpace(Input);
    partial void OnInputChanged(string value) => SendCommand.NotifyCanExecuteChanged();
    partial void OnSendingChanged(bool value) => SendCommand.NotifyCanExecuteChanged();

    partial void OnSelectedSessionChanged(ChatSession? value) => _ = ReloadMessagesAsync();
    partial void OnStreamingDraftChanged(string value) => RefreshEmptyState();
    private void RefreshEmptyState() =>
        ShowEmptyState = Messages.Count == 0 && string.IsNullOrEmpty(StreamingDraft);

    public async Task LoadAsync(long notebookId)
    {
        _notebookId = notebookId;
        LoadScopeSources();
        LoadSourceSets();
        await EnsureSessionsAsync();
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
        try
        {
            var memberIds = _store.SourceSetMembers(id).ToHashSet();
            foreach (var s in ScopeSources) s.IsSelected = memberIds.Contains(s.Id);
            OnPropertyChanged(nameof(ScopeButtonText));
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
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
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    // C2: save the current selection as a named source set.
    [RelayCommand]
    private void CreateSourceSet(string? name)
    {
        var trimmed = name?.Trim();
        if (string.IsNullOrEmpty(trimmed)) return;
        try
        {
            var selectedIds = ScopeSources.Where(s => s.IsSelected).Select(s => s.Id).ToList();
            var set = _store.CreateSourceSet(_notebookId, trimmed);
            _store.SetSourceSetMembers(set.Id, selectedIds);
            SourceSets.Add(set);
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    // Tier 3: populate the scope picker with this notebook's Ready sources (all selected).
    private void LoadScopeSources()
    {
        foreach (var s in ScopeSources) s.PropertyChanged -= OnScopeItemChanged;
        ScopeSources.Clear();
        try
        {
            foreach (var src in _store.Sources(_notebookId))
            {
                if (src.Status != SourceStatus.Ready || src.Id is not { } id) continue;
                var item = new ScopeSourceItem(id, src.Title);
                item.PropertyChanged += OnScopeItemChanged;
                ScopeSources.Add(item);
            }
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
        OnPropertyChanged(nameof(ScopeButtonText));
    }

    private void OnScopeItemChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ScopeSourceItem.IsSelected))
            OnPropertyChanged(nameof(ScopeButtonText));
    }

    // null => unscoped (all or none selected); otherwise the explicit subset of source ids.
    private IReadOnlyCollection<long>? SelectedSourceIds()
    {
        if (ScopeSources.Count == 0) return null;
        var ids = ScopeSources.Where(s => s.IsSelected).Select(s => s.Id).ToList();
        if (ids.Count == 0 || ids.Count == ScopeSources.Count) return null;
        return ids;
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
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
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
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    [RelayCommand]
    private async Task DeleteSessionAsync(ChatSession? session)
    {
        if (session?.Id is not { } id) return;
        try
        {
            _store.DeleteChatSession(id);
            var existing = Sessions.FirstOrDefault(x => x.Id == id);
            if (existing is not null) Sessions.Remove(existing);
            SelectedSession = Sessions.FirstOrDefault();
            await ReloadMessagesAsync();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    private Task ReloadMessagesAsync()
    {
        Messages.Clear();
        PanelCitations.Clear();
        if (SelectedSession?.Id is not { } sid) { RefreshEmptyState(); CanEditLast = false; return Task.CompletedTask; }
        try
        {
            foreach (var m in _store.Messages(sid))
                Messages.Add(new MessageViewModel { Message = m });
            // C4: collect all citations from last assistant message for the panel
            var lastAssistant = Messages.LastOrDefault(m => m.IsAssistant);
            if (lastAssistant?.Message?.Citations is { Count: > 0 } cits)
                foreach (var c in cits) PanelCitations.Add(BuildCitationViewModel(c));
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
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
    private async Task RegenerateAsync()
    {
        if (SelectedSession?.Id is not { } sid) return;
        var lastUser = Messages.LastOrDefault(m => m.Message?.Role == ChatRole.User);
        if (lastUser?.Message is null) return;
        var text = lastUser.Message.Content;
        _store.DeleteLastExchange(sid);
        Input = text;
        IsEditMode = false;
        await SendAsync();
    }

    // C3: commit edit — delete last exchange then send new text
    [RelayCommand]
    private async Task CommitEditAsync()
    {
        if (SelectedSession?.Id is not { } sid) return;
        var text = EditInput.Trim();
        if (text.Length == 0) return;
        _store.DeleteLastExchange(sid);
        Input = text;
        IsEditMode = false;
        await SendAsync();
    }

    [RelayCommand]
    private void CancelEdit() => IsEditMode = false;

    // C4: open citation panel populated from a specific message's citations
    [RelayCommand]
    private void ShowCitations(MessageViewModel? vm)
    {
        if (vm?.Message?.Citations is not { Count: > 0 } cits) return;
        PanelCitations.Clear();
        foreach (var c in cits) PanelCitations.Add(BuildCitationViewModel(c));
        IsCitationPanelOpen = true;
    }

    [RelayCommand]
    private void CloseCitationPanel() => IsCitationPanelOpen = false;

    [RelayCommand(CanExecute = nameof(CanSend))]
    private async Task SendAsync()
    {
        if (SelectedSession?.Id is not { } sid) return;
        var text = Input.Trim();
        if (text.Length == 0) return;
        Input = "";
        Sending = true;
        ErrorMessage = null;
        StreamingDraft = "";
        ClearFollowups();
        try
        {
            IReadOnlyList<WebSearchResult>? webResults = null;
            if (UseWebSearch)
            {
                try { webResults = await _webSearch.SearchAsync(text); } catch { }
            }
            await _chatHolder.Engine.SendAsync(
                sid, _notebookId, text,
                currentNoteContent: null, sourceIds: SelectedSourceIds(),
                webResults: webResults,
                onToken: token => _dispatcher.TryEnqueue(() => StreamingDraft += token));
            await ReloadMessagesAsync();
            await GenerateFollowupsAsync(text);
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToString();
            await ReloadMessagesAsync();
        }
        finally
        {
            Sending = false;
            StreamingDraft = "";
            RefreshEmptyState();
        }
    }

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

    // Mirrors MessageBubble "Save as note": title "Chat reply — <date>", origin=Chat, originRef=msg.id.
    [RelayCommand]
    private void SaveAsNote(MessageViewModel? vm)
    {
        if (vm?.Message is not { } msg) return;
        try
        {
            var when = msg.CreatedAt.ToLocalTime().ToString("d MMM yyyy, h:mm tt");
            _store.CreateNote(_notebookId, $"Chat reply — {when}", msg.Content,
                NoteOrigin.Chat, msg.Id);
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    // Mirrors ChatView.showCitation(): resolve source/page/note metadata for the Flyout.
    public CitationViewModel BuildCitationViewModel(Citation c) => CitationViewModel.Resolve(_store, c);

    public void RequestOpenNote(long noteId)
    {
        _tabSwitch.Request(TabSwitchCoordinator.Tab.Notes);
        _noteJump.Request(noteId);
    }
}

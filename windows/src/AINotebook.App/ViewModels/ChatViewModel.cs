using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;           // OllamaClient, OllamaChatAdapter (Stage C followups)
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
    private readonly OllamaClient _ollama;       // Stage C: build FollowupSuggester on demand
    private readonly ISettingsService _settings; // Stage C: current chat model
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
        ILocalizedStrings t, OllamaClient ollama, ISettingsService settings,
        DispatcherQueue dispatcher)
    {
        _store = store; _chatHolder = chatHolder;
        _noteJump = noteJump; _tabSwitch = tabSwitch;
        _t = t; _ollama = ollama; _settings = settings; _dispatcher = dispatcher;
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
        await EnsureSessionsAsync();
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
        if (SelectedSession?.Id is not { } sid) { RefreshEmptyState(); return Task.CompletedTask; }
        try
        {
            foreach (var m in _store.Messages(sid))
                Messages.Add(new MessageViewModel { Message = m });
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
        RefreshEmptyState();
        return Task.CompletedTask;
    }

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
            await _chatHolder.Engine.SendAsync(
                sid, _notebookId, text,
                currentNoteContent: null, sourceIds: SelectedSourceIds(),
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
            var suggester = new FollowupSuggester(
                new OllamaChatAdapter(_ollama), _settings.SelectedChatModel);
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

    public void RequestOpenNote(long noteId) => _noteJump.Request(noteId);
}

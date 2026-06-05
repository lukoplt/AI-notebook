using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using AINotebook.Core.Models;
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
    private readonly DispatcherQueue _dispatcher;

    private long _notebookId;

    public ObservableCollection<ChatSession> Sessions { get; } = new();
    public ObservableCollection<MessageViewModel> Messages { get; } = new();

    [ObservableProperty] public partial ChatSession? SelectedSession { get; set; }
    [ObservableProperty] public partial string Input { get; set; } = "";
    [ObservableProperty] public partial string StreamingDraft { get; set; } = "";
    [ObservableProperty] public partial bool Sending { get; set; }
    [ObservableProperty] public partial string? ErrorMessage { get; set; }
    [ObservableProperty] public partial bool ShowEmptyState { get; set; } = true;

    public ChatViewModel(
        NotebookStore store, ChatEngineHolder chatHolder,
        NoteJumpCoordinator noteJump, TabSwitchCoordinator tabSwitch,
        ILocalizedStrings t, DispatcherQueue dispatcher)
    {
        _store = store; _chatHolder = chatHolder;
        _noteJump = noteJump; _tabSwitch = tabSwitch;
        _t = t; _dispatcher = dispatcher;
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
        await EnsureSessionsAsync();
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
        try
        {
            await _chatHolder.Engine.SendAsync(
                sid, _notebookId, text,
                currentNoteContent: null,
                onToken: token => _dispatcher.TryEnqueue(() => StreamingDraft += token));
            await ReloadMessagesAsync();
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

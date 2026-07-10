using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;

namespace AINotebook.App.ViewModels;

public partial class NotesChatPanelViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly ChatEngineHolder _chatHolder;
    private readonly ILocalizedStrings _t;
    private readonly DispatcherQueue _dispatcher;
    private long _notebookId;
    private long? _sessionId;

    public ObservableCollection<MessageViewModel> Messages { get; } = new();
    [ObservableProperty] public partial string Input { get; set; } = "";
    [ObservableProperty] public partial string StreamingDraft { get; set; } = "";
    [ObservableProperty] public partial bool Sending { get; set; }
    [ObservableProperty] public partial string? ErrorMessage { get; set; }
    [ObservableProperty] public partial bool ShowEmptyState { get; set; } = true;

    // Pushed live from NotesViewModel.SelectedNote so context tracks the open note.
    public Func<Note?>? CurrentNoteProvider { get; set; }
    public bool HasCurrentNote => CurrentNoteProvider?.Invoke() is not null;

    public NotesChatPanelViewModel(
        NotebookStore store, ChatEngineHolder chatHolder,
        ILocalizedStrings t, DispatcherQueue dispatcher)
    { _store = store; _chatHolder = chatHolder; _t = t; _dispatcher = dispatcher; }

    public bool CanSend => !Sending && !string.IsNullOrWhiteSpace(Input);
    partial void OnInputChanged(string v) => SendCommand.NotifyCanExecuteChanged();
    partial void OnSendingChanged(bool v) => SendCommand.NotifyCanExecuteChanged();

    public async Task LoadAsync(long notebookId)
    {
        _notebookId = notebookId;
        try
        {
            var existing = _store.ChatSessions(notebookId);
            _sessionId = existing.FirstOrDefault()?.Id
                ?? _store.CreateChatSession(notebookId, _t.Get("chatNewSessionTitle")).Id;
            ReloadMessages();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
        await Task.CompletedTask;
    }

    private void ReloadMessages()
    {
        Messages.Clear();
        if (_sessionId is not { } sid) { ShowEmptyState = true; return; }
        foreach (var m in _store.Messages(sid)) Messages.Add(new MessageViewModel { Message = m });
        ShowEmptyState = Messages.Count == 0 && string.IsNullOrEmpty(StreamingDraft);
    }

    [RelayCommand(CanExecute = nameof(CanSend))]
    private async Task SendAsync()
    {
        if (_sessionId is not { } sid) return;
        var text = Input.Trim();
        if (text.Length == 0) return;
        Input = ""; Sending = true; ErrorMessage = null; StreamingDraft = "";
        var noteCtx = CurrentNoteProvider?.Invoke()?.BodyMd;
        try
        {
            await _chatHolder.Engine.SendAsync(sid, _notebookId, text,
                currentNoteContent: noteCtx,
                onToken: tok => _dispatcher.TryEnqueue(() => StreamingDraft += tok));
            ReloadMessages();
        }
        catch (Exception ex)
        {
            // FR-A8: mirrors ChatViewModel.SendAsync's catch — see the
            // comment there for why ProviderConsentException specifically
            // gets a localized message while everything else keeps the
            // existing raw ex.ToString() behavior.
            ErrorMessage = ex is ProviderConsentException
                ? _t.Get(StringKey.ErrorConsentRequired)
                : ex.ToString();
            ReloadMessages();
        }
        finally { Sending = false; StreamingDraft = ""; }
    }

    // Save-as-note + citation resolution identical to ChatViewModel (reuse CitationViewModel.Resolve).
    public CitationViewModel BuildCitationViewModel(Citation c) => CitationViewModel.Resolve(_store, c);

    [RelayCommand]
    private void SaveAsNote(MessageViewModel? vm)
    {
        if (vm?.Message is not { } msg) return;
        try
        {
            var when = msg.CreatedAt.ToLocalTime().ToString("d MMM yyyy, h:mm tt");
            _store.CreateNote(_notebookId, $"Chat reply — {when}", msg.Content, NoteOrigin.Chat, msg.Id);
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }
}

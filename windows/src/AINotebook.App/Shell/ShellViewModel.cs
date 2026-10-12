using AINotebook.App.Services;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.Shell;

/// <summary>
/// Owns the shell state: sidebar, navigation and the bridges from the Core-era coordinators
/// (TabSwitchCoordinator, NoteJumpCoordinator) to the new targets (spec §2.7). No WinUI types.
/// </summary>
public sealed partial class ShellViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly TabSwitchCoordinator _tabSwitch;
    private readonly NoteJumpCoordinator _noteJump;
    private readonly ISettingsService _settings;

    public SidebarViewModel Sidebar { get; }
    public NavigationState Navigation { get; }

    public ShellViewModel(SidebarViewModel sidebar, NotebookStore store, TabSwitchCoordinator tabSwitch,
        NoteJumpCoordinator noteJump, ISettingsService settings)
    {
        Sidebar = sidebar;
        _store = store;
        _tabSwitch = tabSwitch;
        _noteJump = noteJump;
        _settings = settings;
        Navigation = new NavigationState(ParsePanel(settings.RightPanel));
        Navigation.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NavigationState.Selection)) Sidebar.SetActive(Navigation.Selection);
            // Remembered across launches; a remembered note chat reopens as Context outside a note.
            if (e.PropertyName == nameof(NavigationState.Panel))
                _settings.RightPanel = Navigation.Panel?.ToString() ?? "";
        };
        _tabSwitch.PropertyChanged += async (_, e) =>
        {
            if (e.PropertyName != nameof(TabSwitchCoordinator.Target) || _tabSwitch.Target is not { } tab) return;
            _tabSwitch.Clear();
            await Navigation.ApplyAsync(tab);
        };
        _noteJump.TargetChanged += async target =>
        {
            if (target is not long noteId) return;
            _noteJump.Clear();
            await OpenNoteAsync(noteId);
        };
        Navigation.Replace(Sidebar.FirstSelection());
        Sidebar.SetActive(Navigation.Selection);
    }

    /// <summary>Opens a note (citation "Open note", tool result, global search) as a document.</summary>
    public async Task<bool> OpenNoteAsync(long noteId)
    {
        var note = _store.Note(noteId);
        if (note?.Id is not long id) return false;
        return await Navigation.NavigateAsync(new ShellSelection.Note(note.NotebookId, id));
    }

    /// <summary>Ctrl+N / "New chat": the new-chat state of the notebook in context (or the first one).</summary>
    public Task<bool> NewChatAsync(long? notebookId = null)
    {
        long? nb = notebookId ?? Navigation.NotebookId ?? Sidebar.Notebooks.FirstOrDefault()?.Id;
        return nb is null
            ? Navigation.NavigateAsync(new ShellSelection.Empty())
            : Navigation.NavigateAsync(new ShellSelection.NewChat(nb));
    }

    /// <summary>A notebook was created (dialog or "Open folder as notebook"): show its new chat.</summary>
    public Task<bool> OnNotebookCreatedAsync(long notebookId)
    {
        Sidebar.Reload();
        return Navigation.NavigateAsync(new ShellSelection.NewChat(notebookId));
    }

    /// <summary>The first send of a new chat created this session: the thread becomes real.</summary>
    public void OnSessionCreated(long notebookId, long sessionId)
    {
        Sidebar.Reload();
        Navigation.Replace(new ShellSelection.Chat(notebookId, sessionId));
    }

    public async Task DeleteChatAsync(long notebookId, long sessionId, AINotebook.Core.Rag.ContextPreviewSession? previews)
    {
        var next = Sidebar.DeleteChat(notebookId, sessionId, previews);
        if (Navigation.Selection is ShellSelection.Chat open && open.SessionId == sessionId)
            await Navigation.NavigateAsync(next);
    }

    public async Task DeleteNotebookAsync(long notebookId)
    {
        var next = Sidebar.DeleteNotebook(notebookId);
        if (Navigation.NotebookId == notebookId || Navigation.Selection is ShellSelection.Empty)
            Navigation.Replace(next); // the open note/thread no longer exists: no unsaved-changes prompt
        else if (!Sidebar.HasNotebooks)
            Navigation.Replace(new ShellSelection.Empty());
        await Task.CompletedTask;
    }

    internal static PanelSegment? ParsePanel(string? value) =>
        Enum.TryParse<PanelSegment>(value, out var segment) ? segment : null;
}

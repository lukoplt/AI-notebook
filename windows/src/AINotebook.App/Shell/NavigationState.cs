using AINotebook.App.Services;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.Shell;

/// <summary>What the main area shows (spec §2: chat thread, note document, new chat, settings).</summary>
public abstract record ShellSelection
{
    private ShellSelection() { }

    /// <summary>An existing chat thread of a notebook.</summary>
    public sealed record Chat(long NotebookId, long SessionId) : ShellSelection;

    /// <summary>A note opened as a document in the main area (§2.4).</summary>
    public sealed record Note(long NotebookId, long NoteId) : ShellSelection;

    /// <summary>The new-chat empty state; the thread is created on the first send (§2.2).</summary>
    public sealed record NewChat(long? NotebookId) : ShellSelection;

    /// <summary>The full-area settings page (§2.5).</summary>
    public sealed record Settings(SettingsSection Section) : ShellSelection;

    /// <summary>No notebook exists yet: the app empty state (§2.2).</summary>
    public sealed record Empty : ShellSelection;

    /// <summary>The notebook this selection belongs to, when it has one.</summary>
    public long? ContextNotebookId => this switch
    {
        Chat c => c.NotebookId,
        Note n => n.NotebookId,
        NewChat n => n.NotebookId,
        _ => null,
    };
}

/// <summary>Right panel segments (§2.3). <see cref="NoteChat"/> replaces <see cref="Context"/> in document mode.</summary>
public enum PanelSegment { Sources, Notes, Context, Citations, NoteChat }

/// <summary>Settings sections (§2.5), in navigation order.</summary>
public enum SettingsSection { General, Providers, ModelsLimits, Indexing, Tools, About }

/// <summary>
/// Shell navigation state shared by the sidebar, the main area and the right panel. Pure: no
/// WinUI types, so App.Tests cover it. Mirrors the macOS <c>NavigationState</c> (B3).
/// </summary>
public sealed partial class NavigationState : ObservableObject
{
    private PanelSegment _lastSegment = PanelSegment.Sources;
    private ShellSelection? _lastThread;
    private ShellSelection? _beforeSettings;

    public NavigationState(PanelSegment? initialPanel = null)
    {
        if (initialPanel is { } segment)
        {
            Panel = Resolve(segment, document: false);
            _lastSegment = Panel.Value;
        }
    }

    [ObservableProperty]
    public partial ShellSelection Selection { get; private set; } = new ShellSelection.NewChat(null);

    /// <summary>The open right-panel segment; null while the panel is collapsed.</summary>
    [ObservableProperty]
    public partial PanelSegment? Panel { get; private set; }

    public bool IsPanelOpen => Panel is not null;
    public bool IsDocument => Selection is ShellSelection.Note;
    public bool IsSettings => Selection is ShellSelection.Settings;
    public bool IsThread => Selection is ShellSelection.Chat or ShellSelection.NewChat;

    /// <summary>The notebook in context: the selection's own, or (in settings) the one left behind.</summary>
    public long? NotebookId => Selection.ContextNotebookId ?? _beforeSettings?.ContextNotebookId ?? _lastThread?.ContextNotebookId;

    /// <summary>
    /// Asked before leaving the current selection (the open note may have unsaved changes);
    /// returning false keeps the user where they are.
    /// </summary>
    public Func<Task<bool>>? LeaveGuard { get; set; }

    /// <summary>"+ › Run tool" / TabSwitchCoordinator.Tab.Transformations: the shell opens the run-tool dialog.</summary>
    public event Action? RunToolRequested;

    partial void OnSelectionChanged(ShellSelection value)
    {
        OnPropertyChanged(nameof(IsDocument));
        OnPropertyChanged(nameof(IsSettings));
        OnPropertyChanged(nameof(IsThread));
        OnPropertyChanged(nameof(NotebookId));
    }

    partial void OnPanelChanged(PanelSegment? value) => OnPropertyChanged(nameof(IsPanelOpen));

    /// <summary>Moves the main area; false when the leave guard cancelled.</summary>
    public async Task<bool> NavigateAsync(ShellSelection target)
    {
        ArgumentNullException.ThrowIfNull(target);
        if (Equals(target, Selection)) return true;
        if (LeaveGuard is { } guard && Selection is ShellSelection.Note && !await guard()) return false;
        Commit(target);
        return true;
    }

    /// <summary>Replaces the selection without the leave guard (e.g. a new chat became a real thread).</summary>
    public void Replace(ShellSelection target)
    {
        ArgumentNullException.ThrowIfNull(target);
        if (!Equals(target, Selection)) Commit(target);
    }

    private void Commit(ShellSelection target)
    {
        if (Selection is ShellSelection.Chat or ShellSelection.NewChat) _lastThread = Selection;
        if (target is ShellSelection.Settings && Selection is not ShellSelection.Settings) _beforeSettings = Selection;
        Selection = target;
        if (Panel is { } open) Panel = Resolve(open, target is ShellSelection.Note);
    }

    /// <summary>
    /// The note chat takes the Context slot while a note is open and gives it back afterwards
    /// (Swift ShellNavigation.resolvedSegment).
    /// </summary>
    public static PanelSegment Resolve(PanelSegment wanted, bool document) => (wanted, document) switch
    {
        (PanelSegment.Context, true) => PanelSegment.NoteChat,
        (PanelSegment.NoteChat, false) => PanelSegment.Context,
        _ => wanted,
    };

    /// <summary>Alt+← / back arrow: settings return where they were opened from, a document returns to its thread.</summary>
    public Task<bool> GoBackAsync()
    {
        ShellSelection? target = Selection switch
        {
            ShellSelection.Settings => _beforeSettings ?? _lastThread ?? new ShellSelection.NewChat(NotebookId),
            ShellSelection.Note n => ThreadFor(n.NotebookId),
            _ => null,
        };
        return target is null ? Task.FromResult(false) : NavigateAsync(target);
    }

    /// <summary>The last thread of a notebook, or its new-chat state.</summary>
    public ShellSelection ThreadFor(long notebookId) =>
        _lastThread is { } last && last.ContextNotebookId == notebookId ? last : new ShellSelection.NewChat(notebookId);

    /// <summary>Ctrl+0 / top-bar toggle: reopens the last segment.</summary>
    public void TogglePanel()
    {
        if (Panel is not null) { Panel = null; return; }
        Panel = Resolve(_lastSegment, IsDocument);
    }

    public void ShowPanel(PanelSegment segment)
    {
        Panel = Resolve(segment, IsDocument);
        _lastSegment = Panel.Value;
    }

    public void ClosePanel() => Panel = null;

    /// <summary>
    /// Maps the Core-era tab requests onto the new shell (spec §2.7): Sources and Notes open
    /// their panel segment, Chat returns to the thread, Transformations opens "Run tool".
    /// </summary>
    public async Task ApplyAsync(TabSwitchCoordinator.Tab tab)
    {
        switch (tab)
        {
            case TabSwitchCoordinator.Tab.Sources: ShowPanel(PanelSegment.Sources); break;
            case TabSwitchCoordinator.Tab.Notes: ShowPanel(PanelSegment.Notes); break;
            case TabSwitchCoordinator.Tab.Chat:
                if (!IsThread && NotebookId is long nb) await NavigateAsync(ThreadFor(nb));
                break;
            case TabSwitchCoordinator.Tab.Transformations: RunToolRequested?.Invoke(); break;
        }
    }
}

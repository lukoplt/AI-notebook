using System.Collections.ObjectModel;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using AINotebook.Core.Rag;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.Shell;

/// <summary>Collapsible notebook group header (spec §2.1).</summary>
public sealed partial class SidebarNotebookRow : ObservableObject
{
    public SidebarNotebookRow() : this(new Notebook(null, "", "", default, default), false, "") { }

    public SidebarNotebookRow(Notebook notebook, bool expanded, string actionsLabel)
    {
        Notebook = notebook;
        IsExpanded = expanded;
        ActionsLabel = actionsLabel;
    }

    /// <summary>Accessible name of the row's "…" button.</summary>
    public string ActionsLabel { get; }

    public Notebook Notebook { get; }
    public long NotebookId => Notebook.Id ?? 0;
    public string Title => Notebook.Name;

    [ObservableProperty] public partial bool IsExpanded { get; set; }
    /// <summary>Highlighted while this notebook's new-chat state is shown.</summary>
    [ObservableProperty] public partial bool IsActive { get; set; }

    /// <summary>Segoe Fluent chevron (tokens-v1 chevronDown / chevronRight).</summary>
    public string ExpandGlyph => IsExpanded ? "" : "";
    partial void OnIsExpandedChanged(bool value) => OnPropertyChanged(nameof(ExpandGlyph));
}

/// <summary>One chat thread under its notebook.</summary>
public sealed partial class SidebarChatRow : ObservableObject
{
    public SidebarChatRow() : this(new ChatSession(null, 0, "", default)) { }
    public SidebarChatRow(ChatSession session) => Session = session;

    public ChatSession Session { get; }
    public long NotebookId => Session.NotebookId;
    public long SessionId => Session.Id ?? 0;
    public string Title => Session.Title;

    [ObservableProperty] public partial bool IsActive { get; set; }
}

/// <summary>"Show more" / "Show less" under a notebook with more than eight chats.</summary>
public sealed class SidebarMoreRow
{
    public SidebarMoreRow() : this(0, false, "") { }
    public SidebarMoreRow(long notebookId, bool showingAll, string label)
    {
        NotebookId = notebookId;
        IsShowingAll = showingAll;
        Label = label;
    }

    public long NotebookId { get; }
    public bool IsShowingAll { get; }
    public string Label { get; }
}

/// <summary>
/// Sidebar: notebooks as collapsible groups with their chats newest first, at most
/// <see cref="VisibleChats"/> each until "Show more" (spec §2.1). No WinUI types.
/// </summary>
public sealed partial class SidebarViewModel : ObservableObject
{
    /// <summary>tokens-v1 <c>sidebarChatsVisible</c>.</summary>
    public const int VisibleChats = 8;

    private readonly NotebookStore _store;
    private readonly ILocalizedStrings _l;
    private readonly HashSet<long> _expanded = new();
    private readonly HashSet<long> _showAll = new();
    private readonly Dictionary<long, IReadOnlyList<ChatSession>> _sessions = new();
    private ShellSelection _active = new ShellSelection.NewChat(null);

    public ObservableCollection<Notebook> Notebooks { get; } = new();
    public ObservableCollection<object> Rows { get; } = new();

    public bool HasNotebooks => Notebooks.Count > 0;

    public SidebarViewModel(NotebookStore store, ILocalizedStrings l)
    {
        _store = store;
        _l = l;
        Reload();
    }

    /// <summary>Re-reads notebooks and chats; keeps expansion and the active row.</summary>
    public void Reload()
    {
        Notebooks.Clear();
        _sessions.Clear();
        foreach (var nb in _store.Notebooks())
        {
            Notebooks.Add(nb);
            if (nb.Id is long id) _sessions[id] = _store.ChatSessions(id);
        }
        _expanded.IntersectWith(_sessions.Keys);
        _showAll.IntersectWith(_sessions.Keys);
        OnPropertyChanged(nameof(HasNotebooks));
        Rebuild();
    }

    public IReadOnlyList<ChatSession> Sessions(long notebookId) =>
        _sessions.TryGetValue(notebookId, out var list) ? list : Array.Empty<ChatSession>();

    public bool IsExpanded(long notebookId) => _expanded.Contains(notebookId);

    public void Toggle(long notebookId)
    {
        if (!_expanded.Remove(notebookId)) _expanded.Add(notebookId);
        Rebuild();
    }

    public void ToggleShowAll(long notebookId)
    {
        if (!_showAll.Remove(notebookId)) _showAll.Add(notebookId);
        Rebuild();
    }

    /// <summary>Highlights the row for the current selection and expands its notebook.</summary>
    public void SetActive(ShellSelection selection)
    {
        _active = selection;
        bool structural = false;
        if (selection.ContextNotebookId is long nb && _expanded.Add(nb)) structural = true;
        if (selection is ShellSelection.Chat chat && !_showAll.Contains(chat.NotebookId)
            && Sessions(chat.NotebookId).Select(s => s.Id).ToList().IndexOf(chat.SessionId) >= VisibleChats)
        {
            _showAll.Add(chat.NotebookId);
            structural = true;
        }
        if (structural) { Rebuild(); return; }
        ApplyActive();
    }

    private void Rebuild()
    {
        Rows.Clear();
        foreach (var row in Flatten(Notebooks, _sessions, _expanded, _showAll, _l.Get))
            Rows.Add(row);
        ApplyActive();
    }

    private void ApplyActive()
    {
        foreach (var row in Rows)
        {
            switch (row)
            {
                case SidebarChatRow c:
                    c.IsActive = _active is ShellSelection.Chat a && a.SessionId == c.SessionId;
                    break;
                case SidebarNotebookRow n:
                    n.IsActive = _active is ShellSelection.NewChat { NotebookId: long id } && id == n.NotebookId;
                    break;
            }
        }
    }

    /// <summary>
    /// Pure projection: each notebook header, then (when expanded) its newest chats, capped at
    /// <see cref="VisibleChats"/> unless "show all" is on, then a more/less row when capped.
    /// </summary>
    public static IReadOnlyList<object> Flatten(IEnumerable<Notebook> notebooks,
        IReadOnlyDictionary<long, IReadOnlyList<ChatSession>> sessions, ISet<long> expanded, ISet<long> showAll,
        Func<StringKey, string> text)
    {
        var rows = new List<object>();
        foreach (var nb in notebooks)
        {
            if (nb.Id is not long id) continue;
            bool open = expanded.Contains(id);
            rows.Add(new SidebarNotebookRow(nb, open, text(StringKey.ShellMore)));
            if (!open) continue;
            var chats = sessions.TryGetValue(id, out var list) ? list : Array.Empty<ChatSession>();
            bool all = showAll.Contains(id);
            foreach (var session in all ? chats : chats.Take(VisibleChats)) rows.Add(new SidebarChatRow(session));
            if (chats.Count > VisibleChats)
                rows.Add(new SidebarMoreRow(id, all, all
                    ? text(StringKey.ShellShowLess)
                    : string.Format(System.Globalization.CultureInfo.CurrentCulture, text(StringKey.ShellShowMore), chats.Count - VisibleChats)));
        }
        return rows;
    }

    /// <summary>
    /// Deletes a chat and its retained context previews; returns where to go next when that chat
    /// was open (Swift ShellNavigation.selectionAfterDeleting rule).
    /// </summary>
    public ShellSelection DeleteChat(long notebookId, long sessionId, ContextPreviewSession? previews)
    {
        var before = Sessions(notebookId).Select(s => s.Id ?? 0).ToList();
        _store.DeleteChatSession(sessionId);
        try { previews?.Clear(sessionId); } catch (Exception) { }
        Reload();
        return SelectionAfterDeleting(sessionId, before) is long next
            ? new ShellSelection.Chat(notebookId, next)
            : new ShellSelection.NewChat(notebookId);
    }

    /// <summary>
    /// Renames a chat (sidebar flyout, top bar title or "…"); blank or unchanged titles keep the stored
    /// one (Core <see cref="ChatSessionState.RenamedTitle"/>). Returns whether a new title was saved.
    /// </summary>
    public bool RenameChat(long notebookId, long sessionId, string? title)
    {
        var current = Sessions(notebookId).FirstOrDefault(s => s.Id == sessionId)?.Title ?? "";
        if (ChatSessionState.RenamedTitle(title, current) is not { } newTitle) return false;
        _store.RenameChatSession(sessionId, newTitle);
        Reload();
        return true;
    }

    /// <summary>The next chat in the list (older), else the previous one, else none (new chat).</summary>
    public static long? SelectionAfterDeleting(long id, IReadOnlyList<long> sessionIds)
    {
        int index = sessionIds.ToList().IndexOf(id);
        if (index < 0) return null;
        if (index + 1 < sessionIds.Count) return sessionIds[index + 1];
        return index > 0 ? sessionIds[index - 1] : null;
    }

    /// <summary>Deletes a notebook; returns the selection to show afterwards.</summary>
    public ShellSelection DeleteNotebook(long notebookId)
    {
        _store.DeleteNotebook(notebookId);
        Reload();
        return FirstSelection();
    }

    /// <summary>Start-up / fallback selection: the first notebook's new chat, or the app empty state.</summary>
    public ShellSelection FirstSelection() =>
        Notebooks.FirstOrDefault()?.Id is long first
            ? new ShellSelection.NewChat(first)
            : new ShellSelection.Empty();
}

using System.Collections.ObjectModel;
using System.ComponentModel;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.ViewModels;

/// <summary>
/// Chat scope picker state: an explicit whole-notebook mode or a selection of folders, saved sets and individual
/// sources. Checking any item switches to selected mode; checking every visible item does not switch back. Selected
/// IDs survive reloads even when the folder/set/source disappears, so a removed selection stays empty and never widens.
/// Sets stay IDs and contribute their current members each turn via <see cref="ResolveForTurn"/>.
/// No dispatcher is required; callers mutate it on the UI thread.
/// </summary>
public sealed partial class FolderScopeModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly Func<StringKey, string> _text;
    private readonly HashSet<long> _sources = [];
    private readonly HashSet<long> _folders = [];
    private readonly HashSet<long> _sets = [];
    private long? _notebookId;
    private bool _syncing;

    public FolderScopeModel(NotebookStore store, Func<StringKey, string> text)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _text = text ?? throw new ArgumentNullException(nameof(text));
    }

    public ObservableCollection<ScopeSourceItem> Folders { get; } = new();
    public ObservableCollection<ScopeSourceItem> Sets { get; } = new();
    public ObservableCollection<ScopeSourceItem> Sources { get; } = new();

    [ObservableProperty]
    public partial bool WholeNotebook { get; set; } = true;

    public bool SelectedItems
    {
        get => !WholeNotebook;
        set => WholeNotebook = !value;
    }

    public FolderScopeSelection Selection => new(WholeNotebook, _sources, _folders, _sets);

    public bool IsEmptySelection => !WholeNotebook && _sources.Count == 0 && _folders.Count == 0 && _sets.Count == 0;

    public string ButtonText => WholeNotebook ? _text(StringKey.ScopeWholeNotebook)
        : IsEmptySelection ? _text(StringKey.ScopeEmpty)
        : $"{_text(StringKey.ScopeSelection)} ({_sources.Count + _folders.Count + _sets.Count})";

    partial void OnWholeNotebookChanged(bool value) => Changed();

    /// <summary>Loads the pickable rows. Switching notebook deliberately resets to whole notebook; a reload never does.</summary>
    public void Reload(long notebookId)
    {
        if (_notebookId != notebookId)
        {
            _notebookId = notebookId;
            _sources.Clear(); _folders.Clear(); _sets.Clear();
            WholeNotebook = true;
        }
        Fill(Folders, _store.Folders(notebookId).Select(f => (f.Id, f.Draft.DisplayName)), _folders);
        Fill(Sets, _store.SourceSets(notebookId).Select(s => (s.Id, s.Name)), _sets);
        // Published sources stay pickable even when their latest refresh failed.
        Fill(Sources, _store.Sources(notebookId)
            .Where(s => s.Id is not null && (s.PublishedRevisionId is not null || s.Status == SourceStatus.Ready))
            .Select(s => (s.Id!.Value, s.Title)), _sources);
        Changed();
    }

    /// <summary>Selects exactly one saved set (persona or "apply set").</summary>
    public void SelectSet(long setId)
    {
        _sources.Clear(); _folders.Clear(); _sets.Clear();
        _sets.Add(setId);
        Sync(Folders, _folders); Sync(Sets, _sets); Sync(Sources, _sources);
        WholeNotebook = false;
        Changed();
    }

    /// <summary>Fresh SQL snapshot for this turn; errors propagate (never silently the whole notebook).</summary>
    public RetrievalScope ResolveForTurn() =>
        _store.ResolveFolderScope(_notebookId ?? throw new InvalidOperationException("No notebook loaded."), Selection);

    public SourceSet SaveAsSet(string name) =>
        _store.SaveFolderScopeSet(_notebookId ?? throw new InvalidOperationException("No notebook loaded."), name, Selection);

    private void Fill(ObservableCollection<ScopeSourceItem> items, IEnumerable<(long Id, string Title)> rows, HashSet<long> selected)
    {
        foreach (var item in items) item.PropertyChanged -= OnItemChanged;
        items.Clear();
        foreach (var (id, title) in rows)
        {
            var item = new ScopeSourceItem(id, title, isSelected: selected.Contains(id));
            item.PropertyChanged += OnItemChanged;
            items.Add(item);
        }
    }

    private void Sync(ObservableCollection<ScopeSourceItem> items, HashSet<long> selected)
    {
        _syncing = true;
        try { foreach (var item in items) item.IsSelected = selected.Contains(item.Id); }
        finally { _syncing = false; }
    }

    private void OnItemChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (_syncing || e.PropertyName != nameof(ScopeSourceItem.IsSelected) || sender is not ScopeSourceItem item) return;
        var target = Folders.Contains(item) ? _folders : Sets.Contains(item) ? _sets : _sources;
        if (item.IsSelected) target.Add(item.Id); else target.Remove(item.Id);
        // Any checkbox interaction is an explicit selection, even if every visible row ends up checked.
        WholeNotebook = false;
        Changed();
    }

    private void Changed()
    {
        OnPropertyChanged(nameof(SelectedItems));
        OnPropertyChanged(nameof(Selection));
        OnPropertyChanged(nameof(IsEmptySelection));
        OnPropertyChanged(nameof(ButtonText));
    }
}

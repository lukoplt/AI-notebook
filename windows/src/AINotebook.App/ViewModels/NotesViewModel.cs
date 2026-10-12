using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;

namespace AINotebook.App.ViewModels;

public partial class NotesViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly NoteJumpCoordinator _noteJump;
    private readonly NoteEditorCoordinator _editorCoord;
    private readonly ILocalizedStrings _t;
    private readonly DispatcherQueue _dispatcher;
    private long _notebookId;

    public ObservableCollection<Note> Notes { get; } = new();
    public ObservableCollection<Note> FilteredNotes { get; } = new();

    // B8: tags for the currently selected note + all notebook tags.
    public ObservableCollection<Tag> CurrentNoteTags { get; } = new();
    public ObservableCollection<Tag> AllNotebookTags { get; } = new();

    [ObservableProperty] public partial Note? SelectedNote { get; set; }
    public bool HasSelectedNote => SelectedNote is not null;
    [ObservableProperty] public partial string DraftTitle { get; set; } = "";
    [ObservableProperty] public partial string DraftBody { get; set; } = "";
    [ObservableProperty] public partial string? ErrorMessage { get; set; }
    [ObservableProperty] public partial string SearchQuery { get; set; } = "";
    /// <summary>UI redesign: Notes panel tag filter (parity with Sources); null = all notes.</summary>
    [ObservableProperty] public partial long? TagFilterId { get; set; }
    partial void OnTagFilterIdChanged(long? value) => ApplySearchFilter();

    // W-6 (FR-B6): multi-select + bulk delete for notes — parity with
    // SourcesViewModel's bulk mode and with macOS NotesView.bulkMode.
    [ObservableProperty] public partial bool IsBulkMode { get; set; }
    private readonly HashSet<long> _bulkSelection = new();
    public int BulkSelectionCount => _bulkSelection.Count;
    public bool HasBulkSelection => _bulkSelection.Count > 0;

    // Unsaved-changes gate.
    private long? _pendingSelectionId;
    public event Action? UnsavedDialogRequested;      // page shows ContentDialog
    public event Action<long>? HistoryRequested;      // page shows history dialog
    public event Action<long>? JumpHandled;           // page re-selects the note

    public NoteEditorCoordinator EditorCoordinator => _editorCoord;

    public NotesViewModel(
        NotebookStore store, NoteJumpCoordinator noteJump,
        NoteEditorCoordinator editorCoord, ILocalizedStrings t, DispatcherQueue dispatcher)
    {
        _store = store; _noteJump = noteJump; _editorCoord = editorCoord;
        _t = t; _dispatcher = dispatcher;
        _noteJump.TargetChanged += OnJumpTarget;     // Plan-1 coordinator exposes an event/INPC
    }

    public string CurrentNoteBody => SelectedNote?.BodyMd ?? "";
    public Note? CurrentNote => SelectedNote;

    public async Task LoadAsync(long notebookId)
    {
        _notebookId = notebookId;
        LoadAllTags();
        await ReloadAsync();
    }

    public async Task ReloadAsync()
    {
        try
        {
            var current = SelectedNote?.Id;
            Notes.Clear();
            foreach (var n in _store.Notes(_notebookId)) Notes.Add(n);
            ApplySearchFilter();
            // keep selection by id; else pick first.
            SelectedNote = Notes.FirstOrDefault(n => n.Id == current) ?? Notes.FirstOrDefault();
            SyncDraftFromSelection();
        }
        catch (Exception ex) { ErrorMessage = ex.Message; }
        await Task.CompletedTask;
    }

    partial void OnSelectedNoteChanged(Note? value)
    {
        OnPropertyChanged(nameof(HasSelectedNote));
        LoadCurrentNoteTags();
    }

    private void LoadAllTags()
    {
        AllNotebookTags.Clear();
        try { foreach (var t in _store.Tags()) AllNotebookTags.Add(t); } catch { }
    }

    private void LoadCurrentNoteTags()
    {
        CurrentNoteTags.Clear();
        if (SelectedNote?.Id is not { } id) return;
        try { foreach (var t in _store.TagsForNote(id)) CurrentNoteTags.Add(t); } catch { }
    }

    [RelayCommand]
    private void ToggleNoteTag(Tag? tag)
    {
        if (tag is null || SelectedNote?.Id is not { } noteId) return;
        var current = _store.NoteTagIds(noteId).ToHashSet();
        if (current.Contains(tag.Id)) current.Remove(tag.Id); else current.Add(tag.Id);
        _store.SetNoteTags(noteId, [.. current]);
        LoadCurrentNoteTags();
    }

    [RelayCommand]
    private void CreateNoteTag(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return;
        var existing = AllNotebookTags.FirstOrDefault(t =>
            t.Name.Equals(name.Trim(), StringComparison.OrdinalIgnoreCase));
        var tag = existing ?? _store.CreateTag(name.Trim());
        if (existing is null) LoadAllTags();
        ToggleNoteTag(tag);
    }

    partial void OnSearchQueryChanged(string value) => ApplySearchFilter();

    /// <summary>Notes carrying <paramref name="tagId"/> (all when null).</summary>
    public static IEnumerable<Note> FilterByTag(IEnumerable<Note> notes, Func<long, IReadOnlyCollection<long>> tagIdsOf, long? tagId) =>
        tagId is long id ? notes.Where(n => n.Id is long noteId && tagIdsOf(noteId).Contains(id)) : notes;

    private void ApplySearchFilter()
    {
        FilteredNotes.Clear();
        var q = SearchQuery?.Trim() ?? "";
        IEnumerable<Note> tagged;
        try { tagged = FilterByTag(Notes, id => _store.NoteTagIds(id), TagFilterId).ToList(); }
        catch (Exception) { tagged = Notes.ToList(); }
        if (string.IsNullOrEmpty(q))
        {
            foreach (var n in tagged) FilteredNotes.Add(n);
        }
        else
        {
            try
            {
                var hits = _store.SearchNotes(_notebookId, q);
                var hitIds = hits.Select(h => h.NoteId).ToHashSet();
                foreach (var n in tagged.Where(n => hitIds.Contains(n.Id!.Value))) FilteredNotes.Add(n);
            }
            catch
            {
                // FTS not available — fall back to in-memory LIKE
                foreach (var n in tagged.Where(n =>
                    n.Title.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                    n.BodyMd.Contains(q, StringComparison.OrdinalIgnoreCase)))
                    FilteredNotes.Add(n);
            }
        }
    }

    [RelayCommand]
    private void ClearSearch() => SearchQuery = "";

    private void SyncDraftFromSelection()
    {
        DraftTitle = SelectedNote?.Title ?? "";
        DraftBody = SelectedNote?.BodyMd ?? "";
    }

    [RelayCommand]
    private async Task CreateBlankAsync()
    {
        try
        {
            var n = _store.CreateNote(_notebookId, _t.Get("noteUntitled"), "");
            await ReloadAsync();
            AttemptSelect(n.Id);
        }
        catch (Exception ex) { ErrorMessage = ex.Message; }
    }

    // Called by the editor host's autosave sink (OnSaveRequested) AND manual save.
    public void Save(long id, string body)
    {
        try
        {
            _store.UpdateNote(id, DraftTitle, body);  // OnNoteSaved fires indexing in Core/DI
            _dispatcher.TryEnqueue(async () => await ReloadAsync());
        }
        catch (Exception ex) { ErrorMessage = ex.Message; }
    }

    // Selection interception mirrors NotesView.attemptSelect.
    public void AttemptSelect(long? newId)
    {
        if (_editorCoord.HasUnsavedChanges && newId != SelectedNote?.Id)
        {
            _pendingSelectionId = newId;
            UnsavedDialogRequested?.Invoke();
            return;
        }
        ApplySelection(newId);
    }

    public void OnUnsavedSave()       // dialog "Save"
    {
        _editorCoord.FlushPendingSave?.Invoke();
        CommitPendingSelection();
    }
    public void OnUnsavedDiscard()    // dialog "Discard"
    {
        _editorCoord.HasUnsavedChanges = false;
        CommitPendingSelection();
    }
    public void OnUnsavedCancel() => _pendingSelectionId = null;   // dialog "Cancel"

    private void CommitPendingSelection()
    {
        var target = _pendingSelectionId;
        _pendingSelectionId = null;
        ApplySelection(target);
    }

    /// <summary>Document mode: open a note directly (the shell already ran the unsaved-changes guard).</summary>
    public void Open(long noteId) => ApplySelection(noteId);

    private void ApplySelection(long? id)
    {
        SelectedNote = Notes.FirstOrDefault(n => n.Id == id);
        SyncDraftFromSelection();
    }

    [RelayCommand]
    private void ShowHistory()
    {
        if (SelectedNote?.Id is { } id) HistoryRequested?.Invoke(id);
    }

    private void OnJumpTarget(long? target)
    {
        if (target is { } id && Notes.Any(n => n.Id == id))
        {
            AttemptSelect(id);
            _noteJump.Clear();
        }
    }

    public string OriginLabel(NoteOrigin o) => o switch
    {
        NoteOrigin.Manual => _t.Get("noteOriginManual"),
        NoteOrigin.Chat => _t.Get("noteOriginChat"),
        NoteOrigin.Transformation => _t.Get("noteOriginTransformation"),
        _ => ""
    };

    /// W-6: the page owns the ListView, so it reports which notes are ticked
    /// and the view model holds the set the bulk delete acts on.
    public void SetBulkSelection(IEnumerable<long> ids)
    {
        _bulkSelection.Clear();
        foreach (var id in ids) _bulkSelection.Add(id);
        OnPropertyChanged(nameof(BulkSelectionCount));
        OnPropertyChanged(nameof(HasBulkSelection));
    }

    [RelayCommand]
    private void ToggleBulkMode()
    {
        IsBulkMode = !IsBulkMode;
        if (!IsBulkMode) SetBulkSelection(Array.Empty<long>());
    }

    /// W-6: delete every ticked note. The page confirms first — this runs after
    /// the user has already said yes. Deleting the open note also clears the
    /// editor, otherwise it would keep showing a row that no longer exists.
    [RelayCommand]
    private async Task BulkDeleteAsync()
    {
        var ids = _bulkSelection.ToList();
        if (ids.Count == 0) return;
        try
        {
            var openNoteDeleted = SelectedNote?.Id is { } openId && ids.Contains(openId);
            await Task.Run(() => { foreach (var id in ids) _store.DeleteNote(id); });
            if (openNoteDeleted) SelectedNote = null;
            IsBulkMode = false;
            SetBulkSelection(Array.Empty<long>());
            await ReloadAsync();
        }
        catch (Exception ex) { ErrorMessage = ex.Message; }
    }
}

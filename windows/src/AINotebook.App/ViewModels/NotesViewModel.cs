using System;
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

    [ObservableProperty] public partial Note? SelectedNote { get; set; }
    [ObservableProperty] public partial string DraftTitle { get; set; } = "";
    [ObservableProperty] public partial string DraftBody { get; set; } = "";
    [ObservableProperty] public partial string? ErrorMessage { get; set; }
    [ObservableProperty] public partial string SearchQuery { get; set; } = "";

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
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
        await Task.CompletedTask;
    }

    partial void OnSearchQueryChanged(string value) => ApplySearchFilter();

    private void ApplySearchFilter()
    {
        FilteredNotes.Clear();
        var q = SearchQuery?.Trim() ?? "";
        if (string.IsNullOrEmpty(q))
        {
            foreach (var n in Notes) FilteredNotes.Add(n);
        }
        else
        {
            try
            {
                var hits = _store.SearchNotes(_notebookId, q);
                var hitIds = hits.Select(h => h.NoteId).ToHashSet();
                foreach (var n in Notes.Where(n => hitIds.Contains(n.Id!.Value))) FilteredNotes.Add(n);
            }
            catch
            {
                // FTS not available — fall back to in-memory LIKE
                foreach (var n in Notes.Where(n =>
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
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    // Called by the editor host's autosave sink (OnSaveRequested) AND manual save.
    public void Save(long id, string body)
    {
        try
        {
            _store.UpdateNote(id, DraftTitle, body);  // OnNoteSaved fires indexing in Core/DI
            _dispatcher.TryEnqueue(async () => await ReloadAsync());
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
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
}

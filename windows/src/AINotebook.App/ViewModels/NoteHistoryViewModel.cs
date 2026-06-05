using System;
using System.Collections.ObjectModel;
using System.Linq;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AINotebook.App.ViewModels;

public partial class NoteHistoryViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly ILocalizedStrings _t;
    private long _noteId;

    public ObservableCollection<NoteVersion> Versions { get; } = new();  // newest-first
    [ObservableProperty] public partial NoteVersion? Selected { get; set; }
    [ObservableProperty] public partial string? ErrorMessage { get; set; }
    public event Action? RequestClose;

    public NoteHistoryViewModel(NotebookStore store, ILocalizedStrings t) { _store = store; _t = t; }

    public void Load(long noteId)
    {
        _noteId = noteId;
        try
        {
            Versions.Clear();
            foreach (var v in _store.NoteVersions(noteId).Reverse()) Versions.Add(v);  // mac shows reversed
            Selected = Versions.FirstOrDefault();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    public string ReasonLabel(NoteVersionReason r) => r switch
    {
        NoteVersionReason.Autosave => _t.Get("historyReasonAutosave"),
        NoteVersionReason.Manual => _t.Get("editorStatusSaved"),
        NoteVersionReason.Restore => _t.Get("historyReasonRestore"),
        _ => ""
    };

    [RelayCommand]
    private void Restore()
    {
        if (Selected?.Id is not { } id) return;
        try { _store.RestoreNoteVersion(id); RequestClose?.Invoke(); }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }
}

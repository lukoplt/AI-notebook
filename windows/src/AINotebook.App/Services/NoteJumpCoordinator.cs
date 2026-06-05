using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.Services;

/// <summary>
/// Port of the mac NoteJumpCoordinator. CitationPopover "Open note" calls
/// Request(noteId); NotesView reacts (selects/scrolls to the note) then Clear().
/// </summary>
public sealed partial class NoteJumpCoordinator : ObservableObject
{
    [ObservableProperty]
    public partial long? Target { get; set; }

    public void Request(long noteId) => Target = noteId;
    public void Clear() => Target = null;
}

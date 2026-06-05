using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.Services;

/// <summary>
/// Port of the mac NoteEditorCoordinator. The active note editor registers a
/// FlushPendingSave delegate on appear and clears it on disappear; the notes
/// list checks HasUnsavedChanges before switching notes and may call
/// FlushPendingSave to force a synchronous manual save.
/// </summary>
public sealed partial class NoteEditorCoordinator : ObservableObject
{
    [ObservableProperty]
    public partial bool HasUnsavedChanges { get; set; }

    /// <summary>Set by the active editor; invoking it triggers a manual save.</summary>
    public Action? FlushPendingSave { get; set; }

    public void Reset()
    {
        HasUnsavedChanges = false;
        FlushPendingSave = null;
    }
}

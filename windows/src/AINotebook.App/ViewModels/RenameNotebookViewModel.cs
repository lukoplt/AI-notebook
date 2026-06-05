using AINotebook.Core;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.ViewModels;

public partial class RenameNotebookViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly long _id;
    private readonly string _original;

    [ObservableProperty] public partial string Name { get; set; }
    [ObservableProperty] public partial string? ErrorMessage { get; set; }

    public bool CanSave => !string.IsNullOrWhiteSpace(Name) && Name.Trim() != _original;

    public RenameNotebookViewModel(NotebookStore store, Notebook nb)
    {
        _store = store;
        _id = nb.Id!.Value;
        _original = nb.Name;
        _name = nb.Name;
    }

    partial void OnNameChanged(string value) => OnPropertyChanged(nameof(CanSave));

    public bool TrySubmit(string emptyNameMessage)
    {
        try { _store.RenameNotebook(_id, Name.Trim()); return true; }
        catch (StoreException.InvalidNotebookName) { ErrorMessage = emptyNameMessage; return false; }
        catch (StoreException ex) { ErrorMessage = ex.Message; return false; }
    }
}

using AINotebook.Core;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.ViewModels;

public partial class NewNotebookViewModel : ObservableObject
{
    private readonly NotebookStore _store;

    [ObservableProperty] public partial string Name { get; set; } = "";
    [ObservableProperty] public partial string Description { get; set; } = "";
    [ObservableProperty] public partial string? ErrorMessage { get; set; }

    public bool CanCreate => !string.IsNullOrWhiteSpace(Name);
    public Notebook? Created { get; private set; }

    public NewNotebookViewModel(NotebookStore store) => _store = store;

    partial void OnNameChanged(string value) => OnPropertyChanged(nameof(CanCreate));

    /// Returns true on success (dialog should close). Sets ErrorMessage otherwise.
    public bool TrySubmit(string emptyNameMessage)
    {
        try
        {
            Created = _store.CreateNotebook(Name.Trim(), Description.Trim());
            return true;
        }
        catch (StoreException.InvalidNotebookName) { ErrorMessage = emptyNameMessage; return false; }
        catch (StoreException ex) { ErrorMessage = ex.Message; return false; }
    }
}

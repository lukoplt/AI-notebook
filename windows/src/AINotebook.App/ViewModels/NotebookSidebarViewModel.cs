using System.Collections.ObjectModel;
using AINotebook.App.Services;
using AINotebook.Core;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AINotebook.App.ViewModels;

public partial class NotebookSidebarViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly ILocalizedStrings _l;

    public ObservableCollection<Notebook> Notebooks { get; } = new();

    [ObservableProperty]
    public partial long? SelectedNotebookId { get; set; }

    public NotebookSidebarViewModel(NotebookStore store, ILocalizedStrings l)
    {
        _store = store;
        _l = l;
        Reload();
    }

    public void Reload()
    {
        var current = SelectedNotebookId;
        Notebooks.Clear();
        foreach (var nb in _store.Notebooks()) Notebooks.Add(nb);
        // Keep selection if it still exists, else clear.
        if (current is long id && Notebooks.All(n => n.Id != id))
            SelectedNotebookId = null;
    }

    /// Called by the New dialog on success: insert + select.
    public void OnCreated(Notebook created)
    {
        Reload();
        SelectedNotebookId = created.Id;
    }

    public void OnRenamed() => Reload();

    [RelayCommand]
    private void Delete(long id)
    {
        try
        {
            _store.DeleteNotebook(id);
            if (SelectedNotebookId == id) SelectedNotebookId = null;
            Reload();
        }
        catch (StoreException)
        {
            // mac sets deleteError but does not render it (non-blocking); mirror: ignore.
        }
    }
}

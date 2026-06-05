using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core;
using AINotebook.Core.Models;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.ViewModels;

public partial class ShellViewModel : ObservableObject
{
    public NotebookSidebarViewModel Sidebar { get; }
    private readonly ILocalizedStrings _l;

    [ObservableProperty]
    public partial Notebook? SelectedNotebook { get; private set; }

    public string NoNotebookSelectedText => _l["noNotebookSelected"];

    public ShellViewModel(NotebookSidebarViewModel sidebar, ILocalizedStrings l)
    {
        Sidebar = sidebar;
        _l = l;
        Sidebar.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NotebookSidebarViewModel.SelectedNotebookId))
                ResolveSelected();
        };
        _l.PropertyChanged += (_, _) => OnPropertyChanged(nameof(NoNotebookSelectedText));
        ResolveSelected();
    }

    private void ResolveSelected()
    {
        var id = Sidebar.SelectedNotebookId;
        SelectedNotebook = id is null ? null : Sidebar.Notebooks.FirstOrDefault(n => n.Id == id);
    }
}

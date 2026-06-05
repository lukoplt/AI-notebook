using AINotebook.App.Services;
using AINotebook.Core;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.ViewModels;

public partial class NotebookDetailViewModel : ObservableObject
{
    private readonly TabSwitchCoordinator _tabSwitch;
    private readonly ILocalizedStrings _l;

    [ObservableProperty] public partial Notebook Notebook { get; set; }
    [ObservableProperty] public partial TabSwitchCoordinator.Tab SelectedTab { get; set; } = TabSwitchCoordinator.Tab.Sources;

    public string SourcesText => _l["sources"];
    public string ChatText => _l["chat"];
    public string NotesText => _l["notes"];
    public string TransformationsText => _l["transformations"];

    public NotebookDetailViewModel(Notebook notebook, TabSwitchCoordinator tabSwitch, ILocalizedStrings l)
    {
        Notebook = notebook;
        _tabSwitch = tabSwitch;
        _l = l;

        _tabSwitch.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(TabSwitchCoordinator.Target) && _tabSwitch.Target is { } target)
            {
                SelectedTab = target;       // jump
                _tabSwitch.Clear();         // reset, like the mac clear()
            }
        };
        _l.PropertyChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(SourcesText)); OnPropertyChanged(nameof(ChatText));
            OnPropertyChanged(nameof(NotesText)); OnPropertyChanged(nameof(TransformationsText));
        };
    }
}

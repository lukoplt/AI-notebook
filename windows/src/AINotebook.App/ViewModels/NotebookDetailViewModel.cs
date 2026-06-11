using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AINotebook.App.ViewModels;

public partial class NotebookDetailViewModel : ObservableObject
{
    private readonly TabSwitchCoordinator _tabSwitch;
    private readonly ILocalizedStrings _l;
    private readonly NotebookStore _store;

    [ObservableProperty] public partial Notebook Notebook { get; set; }
    [ObservableProperty] public partial TabSwitchCoordinator.Tab SelectedTab { get; set; } = TabSwitchCoordinator.Tab.Sources;
    [ObservableProperty] public partial string Instructions { get; set; } = "";
    [ObservableProperty] public partial string? InstructionsSavedMessage { get; set; }

    public string SourcesText => _l["sources"];
    public string ChatText => _l["chat"];
    public string NotesText => _l["notes"];
    public string TransformationsText => _l["transformations"];
    public string SettingsText => _l.Get(StringKey.NotebookInstructionsLabel);

    public NotebookDetailViewModel(Notebook notebook, TabSwitchCoordinator tabSwitch, ILocalizedStrings l, NotebookStore store)
    {
        Notebook = notebook;
        _tabSwitch = tabSwitch;
        _l = l;
        _store = store;
        Instructions = notebook.Instructions;

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
            OnPropertyChanged(nameof(SettingsText));
        };
    }

    [RelayCommand]
    private async Task SaveInstructionsAsync()
    {
        try
        {
            await Task.Run(() => _store.UpdateNotebookInstructions(Notebook.Id!.Value, Instructions));
            Notebook = Notebook with { Instructions = Instructions };
            InstructionsSavedMessage = _l.Get(StringKey.NotebookInstructionsSaved);
            await Task.Delay(2000);
            InstructionsSavedMessage = null;
        }
        catch (Exception ex) { InstructionsSavedMessage = ex.Message; }
    }
}

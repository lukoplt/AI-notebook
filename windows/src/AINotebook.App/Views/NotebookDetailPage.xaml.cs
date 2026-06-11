using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core;
using AINotebook.Core.Models;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

public sealed partial class NotebookDetailPage : Page
{
    public NotebookDetailViewModel ViewModel { get; }

    /// Bridge TabSwitchCoordinator.Tab <-> Pivot SelectedIndex (Sources=0..Transformations=3).
    public int TabIndex
    {
        get => (int)ViewModel.SelectedTab;
        set => ViewModel.SelectedTab = (TabSwitchCoordinator.Tab)value;
    }

    public NotebookDetailPage(Notebook notebook)
    {
        var tabSwitch = App.Current.Services.GetRequiredService<TabSwitchCoordinator>();
        var l = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        ViewModel = new NotebookDetailViewModel(notebook, tabSwitch, l);
        InitializeComponent();

        var id = notebook.Id!.Value;

        var sources = new SourceListPage(notebook);
        SourcesHost.Children.Add(sources);

        var chat = new ChatPage();
        ChatHost.Children.Add(chat);
        chat.Load(id);

        var notes = new NotesPage();
        NotesHost.Children.Add(notes);
        notes.Load(id);

        var transformations = new TransformationsPage();
        TransformationsHost.Children.Add(transformations);
        transformations.Load(id);

        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NotebookDetailViewModel.SelectedTab))
                Bindings.Update(); // refresh TabIndex two-way target after a coordinator jump
        };
    }
}

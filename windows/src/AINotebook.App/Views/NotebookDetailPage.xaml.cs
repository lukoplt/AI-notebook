using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

public sealed partial class NotebookDetailPage : Page
{
    public NotebookDetailViewModel ViewModel { get; }

    /// Bridge TabSwitchCoordinator.Tab <-> Pivot SelectedIndex (Sources=0..Settings=4).
    public int TabIndex
    {
        get => (int)ViewModel.SelectedTab;
        set => ViewModel.SelectedTab = (TabSwitchCoordinator.Tab)value;
    }

    public NotebookDetailPage(Notebook notebook)
    {
        var sp = App.Current.Services;
        var tabSwitch = sp.GetRequiredService<TabSwitchCoordinator>();
        var l = sp.GetRequiredService<ILocalizedStrings>();
        var store = sp.GetRequiredService<NotebookStore>();
        ViewModel = new NotebookDetailViewModel(notebook, tabSwitch, l, store);
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

        // C1: localize instructions tab
        InstructionsLabel.Text = l.Get(StringKey.NotebookInstructionsLabel);
        InstructionsHint.Text = l.Get(StringKey.NotebookInstructionsPlaceholder);
        SaveInstructionsButton.Content = l.Get(StringKey.UnsavedSaveButton);

        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NotebookDetailViewModel.SelectedTab))
                Bindings.Update(); // refresh TabIndex two-way target after a coordinator jump
        };
    }
}

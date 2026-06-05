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

        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NotebookDetailViewModel.SelectedTab))
                Bindings.Update(); // refresh TabIndex two-way target after a coordinator jump
        };
    }
}

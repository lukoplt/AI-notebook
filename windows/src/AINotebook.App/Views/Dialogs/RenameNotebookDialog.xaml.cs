using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views.Dialogs;

public sealed partial class RenameNotebookDialog : ContentDialog
{
    public RenameNotebookViewModel ViewModel { get; }
    public ILocalizedStrings L { get; }

    public RenameNotebookDialog(Notebook nb)
    {
        var store = App.Current.Services.GetRequiredService<NotebookStore>();
        ViewModel = new RenameNotebookViewModel(store, nb);
        L = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();
        DataContext = this;
    }

    private void OnPrimary(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        if (!ViewModel.TrySubmit(L["cannotBeEmpty"])) args.Cancel = true;
    }
}

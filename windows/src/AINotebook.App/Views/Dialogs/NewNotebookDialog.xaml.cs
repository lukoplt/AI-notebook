using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core;
using AINotebook.Core.Models;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views.Dialogs;

public sealed partial class NewNotebookDialog : ContentDialog
{
    public NewNotebookViewModel ViewModel { get; }
    public ILocalizedStrings L { get; }
    public Notebook? Created => ViewModel.Created;

    public NewNotebookDialog()
    {
        ViewModel = ActivatorUtilities.CreateInstance<NewNotebookViewModel>(App.Current.Services);
        L = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();
        DataContext = this; // exposes L for {Binding L[..]}
    }

    private void OnPrimary(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        // Keep the dialog open if validation fails (mac shows inline error).
        if (!ViewModel.TrySubmit(L["cannotBeEmpty"])) args.Cancel = true;
    }
}

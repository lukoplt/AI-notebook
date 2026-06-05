using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Dialogs;

public sealed partial class TransformationHistoryDialog : ContentDialog
{
    public TransformationHistoryViewModel ViewModel { get; }
    private readonly ILocalizedStrings _t;

    public TransformationHistoryDialog(long notebookId)
    {
        ViewModel = App.Current.Services.GetRequiredService<TransformationHistoryViewModel>();
        _t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();

        Title = _t.Get("aiToolsHistoryTitle");
        CloseButtonText = _t.Get("cancelButton");
        EmptyText.Text = _t.Get("aiToolsHistoryEmpty");

        ViewModel.RequestClose += Hide;
        ViewModel.Load(notebookId);
        UpdateEmptyState();
        ViewModel.Rows.CollectionChanged += (_, _) => UpdateEmptyState();
    }

    private void UpdateEmptyState()
    {
        var empty = ViewModel.Rows.Count == 0;
        EmptyText.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        RunsList.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
    }

    private async void OnRowClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is TransformationRunRow row)
            await ViewModel.JumpAsync(row);
    }
}

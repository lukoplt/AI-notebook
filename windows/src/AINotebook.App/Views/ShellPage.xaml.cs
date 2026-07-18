using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.App.Views.Dialogs;
using AINotebook.Core;
using AINotebook.Core.Models;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;

namespace AINotebook.App.Views;

public sealed partial class ShellPage : Page
{
    public ShellViewModel ViewModel { get; }
    private readonly ILocalizedStrings _l;
    private readonly UpdateState _updateState;

    public string RenameText => _l["renameNotebook"];
    public string DeleteText => _l["deleteNotebook"];

    public ShellPage()
    {
        ViewModel = App.Current.Services.GetRequiredService<ShellViewModel>();
        _l = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();
        DataContext = _l; // enables {Binding [key]} localized lookups
        Nav.DataContext = this; // RenameText/DeleteText for the MenuFlyout

        // Everything inside Nav inherits Nav.DataContext (this page), which has
        // no localized-string indexer — assign the texts directly instead.
        PaneHeaderText.Text = _l["notebooks"];
        NewButtonText.Text = _l["createNotebook"];
        ToolTipService.SetToolTip(NewButton, _l["createNotebook"]);
        EmptyStateText.Text = _l["noNotebookSelected"];

        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ShellViewModel.SelectedNotebook))
                ShowDetail(ViewModel.SelectedNotebook);
        };
        ShowDetail(ViewModel.SelectedNotebook);

        _updateState = App.Current.Services.GetRequiredService<UpdateState>();
        _updateState.PropertyChanged += (_, __) => SyncUpdateBar();
        UpdateBar.CloseButtonClick += (_, __) => _updateState.BannerDismissed = true;
        SyncUpdateBar();
    }

    private void SyncUpdateBar()
    {
        var info = _updateState.Available;
        if (info is null || _updateState.BannerDismissed) { UpdateBar.IsOpen = false; return; }
        UpdateBar.Message = string.Format(_l.Get(StringKey.UpdateBannerTitle), info.LatestVersion);
        UpdateDownloadButton.Content = _l.Get(StringKey.UpdateDownloadButton);
        UpdateBar.IsOpen = true;
    }

    private async void OnUpdateDownload(object sender, RoutedEventArgs e)
    {
        var info = _updateState.Available;
        if (info is null) return;
        _ = await Windows.System.Launcher.LaunchUriAsync(new Uri(info.DownloadUrl));
    }

    private void ShowDetail(Notebook? nb)
    {
        EmptyState.Visibility = nb is null ? Visibility.Visible : Visibility.Collapsed;
        // Remove a previous detail page if present.
        for (int i = DetailHost.Children.Count - 1; i >= 0; i--)
            if (DetailHost.Children[i] is NotebookDetailPage) DetailHost.Children.RemoveAt(i);
        if (nb is not null)
            DetailHost.Children.Add(new NotebookDetailPage(nb));
    }

    // Gear item in the nav pane — the only entry point to app settings.
    private bool _settingsOpen;
    private async void Nav_ItemInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (!args.IsSettingsInvoked || _settingsOpen) return;
        _settingsOpen = true; // ShowAsync throws if a second dialog opens meanwhile
        try
        {
            var dialog = new SettingsDialog(App.Current.Services.GetRequiredService<LocalizedStrings>())
            {
                XamlRoot = this.XamlRoot
            };
            await dialog.ShowAsync();
        }
        finally
        {
            _settingsOpen = false;
            Nav.SelectedItem = null; // the notebook list is the only selection surface
        }
    }

    private void NotebookList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        ViewModel.Sidebar.SelectedNotebookId = (NotebookList.SelectedItem as Notebook)?.Id;
    }

    private void NotebookItem_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if (sender is FrameworkElement fe) FlyoutBase.ShowAttachedFlyout(fe);
    }

    private Notebook? ContextNotebook(object sender) =>
        (sender as FrameworkElement)?.DataContext as Notebook
        ?? ((sender as FrameworkElement)?.Parent as FrameworkElement)?.DataContext as Notebook
        ?? NotebookList.SelectedItem as Notebook;

    private async void New_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new NewNotebookDialog { XamlRoot = this.XamlRoot };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && dialog.Created is { } created)
            ViewModel.Sidebar.OnCreated(created);
    }

    private async void Rename_Click(object sender, RoutedEventArgs e)
    {
        if (ContextNotebook(sender) is not { Id: long } nb) return;
        var dialog = new RenameNotebookDialog(nb) { XamlRoot = this.XamlRoot };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            ViewModel.Sidebar.OnRenamed();
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (ContextNotebook(sender) is not { Id: long id }) return;
        var ok = await new ContentDialog
        {
            XamlRoot = this.XamlRoot,
            Title = _l["deleteNotebook"],
            Content = _l["confirmDeleteNotebook"],
            PrimaryButtonText = _l["delete"],
            CloseButtonText = _l["cancel"],
            DefaultButton = ContentDialogButton.Close
        }.ShowAsync() == ContentDialogResult.Primary;
        if (ok) ViewModel.Sidebar.DeleteCommand.Execute(id);
    }
}

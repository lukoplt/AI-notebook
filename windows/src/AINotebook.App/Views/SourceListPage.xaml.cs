using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace AINotebook.App.Views;

public sealed partial class SourceListPage : UserControl
{
    public SourcesViewModel ViewModel { get; }

    private readonly IngestionService _ingestion;
    private readonly LocalizedStrings _strings;

    public SourceListPage(Notebook notebook)
    {
        this.InitializeComponent();
        var sp = App.Current.Services;
        _ingestion = sp.GetRequiredService<IngestionService>();
        _strings = sp.GetRequiredService<LocalizedStrings>();
        var store = sp.GetRequiredService<NotebookStore>();
        ViewModel = new SourcesViewModel(
            store, _strings,
            sp.GetRequiredService<ProviderRouter>(),
            sp.GetRequiredService<ISettingsService>(),
            _ingestion,
            sp.GetRequiredService<FolderWatchService>())
        { NotebookId = notebook.Id!.Value };

        HeaderTitle.Text = _strings.Get(StringKey.SourcesSectionTitle);
        AddButton.Content = _strings.Get(StringKey.AddSourceButton);
        EmptyText.Text = _strings.Get(StringKey.NoSourcesEmptyState);
        EmptyAddButton.Content = _strings.Get(StringKey.AddSourceButton);
        FolderWatchButton.Content = _strings.Get(StringKey.FolderWatchButton);
        FolderWatchActiveButton.Content = _strings.Get(StringKey.FolderWatchActiveLabel);
        BulkButton.Content = _strings.Get(StringKey.BulkSelectButton);
        BulkDeleteButton.Content = _strings.Get(StringKey.BulkDeleteSelectedButton);

        ViewModel.FolderWatchRequested += async () => await PickAndEnableFolderWatchAsync();
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(SourcesViewModel.IsEmpty)) ApplyEmptyState();
            if (e.PropertyName == nameof(SourcesViewModel.IsBulkMode)) BulkSelectedLabel.Text =
                $"{ViewModel.SelectedSourceIds.Count} {_strings.Get(StringKey.BulkSelectButton)}";
        };
        Loaded += async (_, _) => { await ViewModel.LoadAsync(); ApplyEmptyState(); };
    }

    private void ApplyEmptyState()
        => SourceList.Visibility = ViewModel.IsEmpty ? Visibility.Collapsed : Visibility.Visible;

    private async void OnAdd(object sender, RoutedEventArgs e)
    {
        var dialog = new AddSourceDialog(_ingestion, ViewModel.NotebookId, _strings)
        {
            XamlRoot = this.XamlRoot
        };
        await dialog.ShowAsync();
        await ViewModel.LoadAsync();
        ApplyEmptyState();
    }

    private async void OnDeleteRow(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: long id })
            await ViewModel.DeleteAsync(id);
    }

    private async void OnSummarizeRow(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: SourceItem item })
            await ViewModel.SummarizeAsync(item);
    }

    // E2: re-crawl URL source
    private async void OnRefreshUrl(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: SourceItem item })
            await ViewModel.RefreshUrlAsync(item);
    }

    // B7: preview source chunks
    private async void OnPreviewRow(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: SourceItem item }) return;
        var sp = App.Current.Services;
        var source = sp.GetRequiredService<NotebookStore>().Source(item.Id);
        if (source is null) return;
        var dialog = new SourcePreviewDialog(source) { XamlRoot = this.XamlRoot };
        await dialog.ShowAsync();
    }

    // B5: drag-over files
    private void OnDragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems))
        {
            e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy;
            e.DragUIOverride.Caption = _strings.Get(StringKey.AddSourceButton);
        }
    }

    // B5: drop files
    private async void OnDrop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        foreach (var item in items.OfType<Windows.Storage.StorageFile>())
        {
            try
            {
                await _ingestion.IngestFileAsync(new Uri(item.Path), ViewModel.NotebookId);
            }
            catch { /* unsupported file type — skip */ }
        }
        await ViewModel.LoadAsync();
        ApplyEmptyState();
    }

    // E1: pick a folder and start watching
    private void OnFolderWatch(object sender, RoutedEventArgs e) =>
        ViewModel.ToggleFolderWatchCommand.Execute(null);

    private void OnFolderWatchDisable(object sender, RoutedEventArgs e) =>
        ViewModel.ToggleFolderWatchCommand.Execute(null);

    private async Task PickAndEnableFolderWatchAsync()
    {
        var picker = new FolderPicker();
        picker.FileTypeFilter.Add("*");
        var hwnd = WindowNative.GetWindowHandle(App.MainWindow);
        InitializeWithWindow.Initialize(picker, hwnd);
        var folder = await picker.PickSingleFolderAsync();
        if (folder is not null)
            ViewModel.EnableFolderWatch(folder.Path);
    }
}

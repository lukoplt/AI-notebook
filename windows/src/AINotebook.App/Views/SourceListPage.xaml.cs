using System.Linq;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace AINotebook.App.Views;

public sealed partial class SourceListPage : UserControl
{
    public SourcesViewModel ViewModel { get; }

    private readonly IngestionService _ingestion;
    private readonly LocalizedStrings _strings;
    private readonly NotebookStore _store;

    public SourceListPage(Notebook notebook)
    {
        this.InitializeComponent();
        var sp = App.Current.Services;
        _ingestion = sp.GetRequiredService<IngestionService>();
        _strings = sp.GetRequiredService<LocalizedStrings>();
        _store = sp.GetRequiredService<NotebookStore>();
        ViewModel = new SourcesViewModel(
            _store, _strings,
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
        BulkSummarizeButton.Content = _strings.Get(StringKey.BulkSummarizeSelectedButton);
        ToolTipService.SetToolTip(ExportNotebookButton, _strings.Get(StringKey.ExportNotebookZip));
        ExportNotebookButton.Content = new FontIcon { Glyph = "", FontSize = 14 };

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

    // B2: export entire notebook as ZIP.
    private async void OnExportNotebook(object sender, RoutedEventArgs e)
    {
        var picker = new FileSavePicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(App.MainWindow));
        picker.SuggestedFileName = "notebook";
        picker.DefaultFileExtension = ".zip";
        picker.FileTypeChoices.Add("ZIP", [".zip"]);
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        try
        {
            var stream = ExportService.ExportNotebookZip(ViewModel.NotebookId, _store);
            using var outStream = await file.OpenStreamForWriteAsync();
            await stream.CopyToAsync(outStream);
        }
        catch (Exception ex) { ViewModel.ErrorMessage = ex.ToString(); }
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

    // B8: manage tags for a source via ContentDialog.
    private async void OnManageSourceTags(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: SourceItem item }) return;

        // Build dialog body: existing tag chips + text input for new tag.
        var panel = new StackPanel { Spacing = 8 };

        var tagPanel = new ItemsControl();
        tagPanel.ItemsPanel = new ItemsPanelTemplate();
        var tagRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };

        void RebuildChips()
        {
            tagRow.Children.Clear();
            foreach (var tag in item.Tags)
            {
                var chip = new Button
                {
                    Content = $"{tag.Name} ×",
                    Padding = new Microsoft.UI.Xaml.Thickness(8, 2, 8, 2),
                    Tag = tag
                };
                chip.Click += (_, _) =>
                {
                    ViewModel.ToggleSourceTag(item, tag);
                    RebuildChips();
                };
                tagRow.Children.Add(chip);
            }
        }
        RebuildChips();
        panel.Children.Add(tagRow);

        // Quick-pick existing tags not yet applied.
        var quickRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        foreach (var t in ViewModel.AllTags.Where(t => !item.Tags.Any(it => it.Id == t.Id)))
        {
            var btn = new Button { Content = $"+ {t.Name}", Padding = new Microsoft.UI.Xaml.Thickness(6, 2, 6, 2), Tag = t };
            btn.Click += (_, _) =>
            {
                ViewModel.ToggleSourceTag(item, (Tag)btn.Tag);
                RebuildChips();
            };
            quickRow.Children.Add(btn);
        }
        if (quickRow.Children.Count > 0) panel.Children.Add(quickRow);

        var input = new TextBox { PlaceholderText = _strings.Get(StringKey.TagNamePlaceholder) };
        panel.Children.Add(input);

        var dialog = new ContentDialog
        {
            XamlRoot = this.XamlRoot,
            Title = _strings.Get(StringKey.TagsSectionTitle),
            Content = panel,
            PrimaryButtonText = _strings.Get(StringKey.AddTagButton),
            CloseButtonText = _strings.Get(StringKey.CancelButton),
            DefaultButton = ContentDialogButton.Close
        };
        dialog.PrimaryButtonClick += (_, _) =>
        {
            var name = input.Text?.Trim();
            if (string.IsNullOrEmpty(name)) return;
            var tag = ViewModel.GetOrCreateTag(name);
            if (!item.Tags.Any(t => t.Id == tag.Id))
                ViewModel.ToggleSourceTag(item, tag);
        };
        await dialog.ShowAsync();
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

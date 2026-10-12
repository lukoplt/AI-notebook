using AINotebook.App.Services;
using AINotebook.App.Shell;
using AINotebook.App.ViewModels;
using AINotebook.App.Views;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace AINotebook.App.Panels;

/// <summary>
/// Right panel › Sources (spec §2.3): every former Sources feature in a compact panel — add
/// file / folder / URL / text, scan, verify, rules, watch, remove, bulk, tags, preview, re-crawl,
/// summary, grouping and paging. Presentation only; ingestion and watches belong to the runtime.
/// </summary>
public sealed partial class SourcesPanel : UserControl
{
    public SourcesViewModel ViewModel { get; }

    /// <summary>The status strip's "Open settings": the shell opens Settings at this section.</summary>
    public event Action<SettingsSection>? SettingsRequested;

    private readonly IngestionService _ingestion;
    private readonly LocalizedStrings _strings;
    private readonly NotebookStore _store;

    public SourcesPanel(Notebook notebook)
    {
        InitializeComponent();
        var sp = App.Current.Services;
        _ingestion = sp.GetRequiredService<IngestionService>();
        _strings = sp.GetRequiredService<LocalizedStrings>();
        _store = sp.GetRequiredService<NotebookStore>();
        ViewModel = new SourcesViewModel(
            _store, _strings,
            sp.GetRequiredService<ProviderRouter>(),
            sp.GetRequiredService<ISettingsService>(),
            _ingestion,
            sp.GetRequiredService<FolderIngestionRuntime>())
        { NotebookId = notebook.Id!.Value };

        ApplyStrings();
        ViewModel.SettingsRequested += section => SettingsRequested?.Invoke(section);
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(SourcesViewModel.IsEmpty)) ApplyEmptyState();
            if (e.PropertyName == nameof(SourcesViewModel.TagFilterId)) ApplyTagFilter();
            if (e.PropertyName == nameof(SourcesViewModel.IndexingDisplay)) ApplyIndexing();
        };
        // Presentation subscriptions follow the panel; ingestion and watches belong to the app-wide runtime.
        Loaded += async (_, _) =>
        {
            ViewModel.Attach();
            await ViewModel.LoadAsync();
            ApplyEmptyState();
        };
        Unloaded += (_, _) => ViewModel.Detach();
    }

    private void ApplyStrings()
    {
        AddFileItem.Text = _strings.Get(StringKey.ComposerAddFile);
        AddFolderItem.Text = _strings.Get(StringKey.AddFolderButton);
        AddUrlItem.Text = _strings.Get(StringKey.ComposerAddUrl);
        AddTextItem.Text = _strings.Get(StringKey.SourcesAddText);
        EmptyText.Text = _strings.Get(StringKey.NoSourcesEmptyState);
        EmptyAddFolderButton.Content = _strings.Get(StringKey.AddFolderButton);
        BulkDeleteButton.Content = _strings.Get(StringKey.BulkDeleteSelectedButton);
        BulkSummarizeButton.Content = _strings.Get(StringKey.BulkSummarizeSelectedButton);
        BulkDoneButton.Content = _strings.Get(StringKey.Close);
        Label(AddButton, _strings.Get(StringKey.AddSourceButton));
        Label(PanelMoreButton, _strings.Get(StringKey.ShellMore));
        Label(DismissErrorButton, _strings.Get(StringKey.Close));
    }

    private static void Label(FrameworkElement element, string text)
    {
        AutomationProperties.SetName(element, text);
        ToolTipService.SetToolTip(element, text);
    }

    // ---------------------------------------------------------------- indexing status strip

    private static Brush ThemeBrush(string key) => (Brush)Application.Current.Resources[key];

    /// <summary>Renders <see cref="SourcesViewModel.IndexingDisplay"/> (pure mapping in IndexingStatusPresenter).</summary>
    private void ApplyIndexing()
    {
        var d = ViewModel.IndexingDisplay;
        IndexingStrip.Visibility = d.IsVisible ? Visibility.Visible : Visibility.Collapsed;
        if (!d.IsVisible) return;
        IndexingIcon.Glyph = (string)Application.Current.Resources[d.IconKey];
        IndexingIcon.Foreground = ThemeBrush(d.Tone switch
        {
            IndexingStripTone.Warning => "WarningBrush",
            IndexingStripTone.Danger => "DangerBrush",
            IndexingStripTone.Quiet => "Text3Brush",
            _ => "Text2Brush",
        });
        IndexingText.Foreground = ThemeBrush(d.Tone == IndexingStripTone.Quiet ? "Text3Brush" : "Text2Brush");
        IndexingText.Text = d.Text;
        ToolTipService.SetToolTip(IndexingText, d.Text);
        IndexingProgress.Visibility = d.ShowProgress ? Visibility.Visible : Visibility.Collapsed;
        IndexingProgress.IsIndeterminate = d.IsIndeterminate;
        IndexingProgress.Value = d.ProgressFraction ?? 0;
        IndexingSecondaryText.Text = d.SecondaryText ?? "";
        IndexingSecondaryText.Visibility = d.SecondaryText is null ? Visibility.Collapsed : Visibility.Visible;
        ToolTipService.SetToolTip(IndexingSecondaryText, d.SecondaryHelp ?? d.SecondaryText);
        IndexingRetryAllButton.Content = d.RetryAllLabel ?? "";
        IndexingRetryAllButton.Visibility = d.RetryAllLabel is null ? Visibility.Collapsed : Visibility.Visible;
        IndexingActionButton.Content = d.ActionLabel ?? "";
        IndexingActionButton.Visibility = d.Action == IndexingStripAction.None ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetName(IndexingStrip, d.SecondaryText is null ? d.Text : d.Text + ". " + d.SecondaryText);
    }

    private async void OnRetryAllFailed(object sender, RoutedEventArgs e)
    {
        IndexingRetryAllButton.IsEnabled = false;
        try { await ViewModel.RetryAllFailedAsync(); }
        finally { IndexingRetryAllButton.IsEnabled = true; }
    }

    private async void OnRetrySourceRow(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SourceItem item }) await ViewModel.RetrySourceAsync(item);
    }

    private async void OnIndexingAction(object sender, RoutedEventArgs e)
    {
        IndexingActionButton.IsEnabled = false;
        try { await ViewModel.RunIndexingActionAsync(); }
        finally { IndexingActionButton.IsEnabled = true; }
    }

    private void ApplyEmptyState()
    {
        SourceList.Visibility = ViewModel.IsEmpty ? Visibility.Collapsed : Visibility.Visible;
        EmptyPanel.Visibility = ViewModel.IsEmpty ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ApplyTagFilter()
    {
        var tag = ViewModel.AllTags.FirstOrDefault(t => t.Id == ViewModel.TagFilterId);
        TagFilterChip.Visibility = tag is null ? Visibility.Collapsed : Visibility.Visible;
        TagFilterText.Text = tag?.Name ?? "";
    }

    private MenuFlyoutItem Item(string text, string icon, RoutedEventHandler click, object? tag = null)
    {
        var item = new MenuFlyoutItem { Text = text, Tag = tag, Icon = new FontIcon { Glyph = (string)Application.Current.Resources[icon] } };
        item.Click += click;
        return item;
    }

    // ---------------------------------------------------------------- panel menus

    /// <summary>Panel "…": bulk mode and the tag filter (spec §2.3).</summary>
    private void OnPanelMore(object sender, RoutedEventArgs e)
    {
        var menu = new MenuFlyout();
        var bulk = new ToggleMenuFlyoutItem
        {
            Text = _strings.Get(StringKey.BulkSelectButton),
            IsChecked = ViewModel.IsBulkMode,
            Icon = new FontIcon { Glyph = (string)Application.Current.Resources["IconBulkSelect"] },
        };
        bulk.Click += (_, _) => { ViewModel.ToggleBulkModeCommand.Execute(null); UpdateBulkLabel(); };
        menu.Items.Add(bulk);
        if (ViewModel.AllTags.Count > 0)
        {
            var filter = new MenuFlyoutSubItem
            {
                Text = _strings.Get(StringKey.FilterByTagLabel),
                Icon = new FontIcon { Glyph = (string)Application.Current.Resources["IconTag"] },
            };
            var all = new ToggleMenuFlyoutItem { Text = _strings.Get(StringKey.AllTagsOption), IsChecked = ViewModel.TagFilterId is null };
            all.Click += (_, _) => ViewModel.TagFilterId = null;
            filter.Items.Add(all);
            foreach (var tag in ViewModel.AllTags)
            {
                var item = new ToggleMenuFlyoutItem { Text = tag.Name, IsChecked = ViewModel.TagFilterId == tag.Id };
                long id = tag.Id;
                item.Click += (_, _) => ViewModel.TagFilterId = id;
                filter.Items.Add(item);
            }
            menu.Items.Add(filter);
        }
        menu.ShowAt((FrameworkElement)sender);
    }

    private void OnClearTagFilter(object sender, RoutedEventArgs e) => ViewModel.TagFilterId = null;

    private void UpdateBulkLabel() =>
        BulkSelectedLabel.Text = $"{ViewModel.SelectedSourceIds.Count} · {_strings.Get(StringKey.BulkSelectButton)}";

    private async void OnBulkDelete(object sender, RoutedEventArgs e)
    {
        int count = ViewModel.SelectedSourceIds.Count;
        if (count == 0) return;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = _strings.Get(StringKey.BulkDeleteSelectedButton),
            Content = string.Format(_strings.Get(StringKey.BulkDeleteConfirmFormat), count),
            PrimaryButtonText = _strings.Get(StringKey.Delete),
            CloseButtonText = _strings.Get(StringKey.Cancel),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            await ViewModel.BulkDeleteCommand.ExecuteAsync(null);
    }

    private void OnDismissError(object sender, RoutedEventArgs e) => ViewModel.ErrorMessage = null;

    // ---------------------------------------------------------------- add

    private async void OnAddFile(object sender, RoutedEventArgs e) => await AddAsync(AddSourceKind.File);
    private async void OnAddUrl(object sender, RoutedEventArgs e) => await AddAsync(AddSourceKind.Url);
    private async void OnAddText(object sender, RoutedEventArgs e) => await AddAsync(AddSourceKind.Text);

    private async Task AddAsync(AddSourceKind kind)
    {
        var dialog = new AddSourceDialog(_ingestion, ViewModel.NotebookId, _strings, kind) { XamlRoot = XamlRoot };
        await dialog.ShowAsync();
        await ViewModel.LoadAsync();
        ApplyEmptyState();
    }

    // WP6: pick a folder, persist it and start watching.
    private async void OnAddFolder(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(App.MainWindow));
        picker.FileTypeFilter.Add("*");
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;
        await ViewModel.AddFolderAsync(folder.Path);
        ApplyEmptyState();
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

    // B5 + WP6: drop files and folders. Folders become persisted watched folders; a failed item never discards
    // its successful siblings, and every failure is shown.
    private async void OnDrop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        foreach (var item in items)
        {
            try
            {
                if (item is StorageFolder folder) await ViewModel.AddFolderAsync(folder.Path);
                else if (item is StorageFile file) await _ingestion.IngestFileAsync(new Uri(file.Path), ViewModel.NotebookId);
            }
            catch (Exception ex) { ViewModel.ErrorMessage = ex.Message; }
        }
        await ViewModel.LoadAsync();
        ApplyEmptyState();
    }

    // ---------------------------------------------------------------- folders

    /// <summary>Folder "…" (spec §2.3): Scan, Verify all, Rules…, Watch ✓, Remove.</summary>
    private MenuFlyout FolderMenu(FolderRowViewModel row)
    {
        var menu = new MenuFlyout();
        long id = row.Folder.Id;
        menu.Items.Add(Item(row.ScanNowLabel, "IconScan", OnScanFolder, id));
        menu.Items.Add(Item(row.VerifyAllLabel, "IconVerify", OnVerifyFolder, id));
        menu.Items.Add(Item(row.RulesLabel, "IconRules", OnFolderRules, id));
        var watch = new ToggleMenuFlyoutItem
        {
            Text = row.WatchLabel,
            IsChecked = row.WatchEnabled,
            Icon = new FontIcon { Glyph = (string)Application.Current.Resources["IconWatch"] },
        };
        // WatchEnabled persists through FolderRowViewModel.WatchChanged (rolled back on failure).
        watch.Click += (_, _) => row.WatchEnabled = watch.IsChecked;
        menu.Items.Add(watch);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(row.RemoveLabel, "IconDelete", OnRemoveFolder, id));
        return menu;
    }

    private void OnFolderMore(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: FolderRowViewModel row } anchor) FolderMenu(row).ShowAt(anchor);
    }

    private void OnFolderRowRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: FolderRowViewModel row } anchor)
        {
            FolderMenu(row).ShowAt(anchor, e.GetPosition(anchor));
            e.Handled = true;
        }
    }

    // Grouped Sources: expand / collapse a folder; members load lazily, one page at a time.
    private async void OnToggleFolder(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: FolderRowViewModel row }) await ViewModel.ToggleFolderAsync(row);
    }

    private async void OnLoadMoreMembers(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: FolderFooterRow footer }) await ViewModel.LoadMoreMembersAsync(footer);
    }

    private async void OnScanFolder(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: long id }) await ViewModel.ScanFolderAsync(id, verifyAll: false);
    }

    private async void OnVerifyFolder(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: long id }) await ViewModel.ScanFolderAsync(id, verifyAll: true);
    }

    private async void OnFolderRules(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: long id }) return;
        var row = ViewModel.FolderRows.FirstOrDefault(r => r.Folder.Id == id);
        if (row is null) return;
        var dialog = new FolderRulesDialog(row.Folder, rules => ViewModel.SaveFolderRulesAsync(id, rules), _strings)
        {
            XamlRoot = XamlRoot
        };
        await dialog.ShowAsync();
    }

    // Removal deletes the folder's rows from the notebook only; files on disk are kept.
    private async void OnRemoveFolder(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: long id }) return;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = _strings.Get(StringKey.FolderRemoveConfirm),
            Content = new TextBlock { Text = _strings.Get(StringKey.FolderRemoveKeepsFiles), TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = _strings.Get(StringKey.FolderRemoveButton),
            CloseButtonText = _strings.Get(StringKey.CancelButton),
            DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        await ViewModel.RemoveFolderAsync(id);
        ApplyEmptyState();
    }

    // ---------------------------------------------------------------- sources

    /// <summary>Source "…": Preview, Tags…, Summarize, Re-crawl (URL), Delete.</summary>
    private MenuFlyout SourceMenu(SourceItem item)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(Item(_strings.Get(StringKey.SourcePreviewButton), "IconFile", OnPreviewRow, item));
        menu.Items.Add(Item(_strings.Get(StringKey.TagsSectionTitle), "IconTag", OnManageSourceTags, item));
        if (item.CanSummarize) menu.Items.Add(Item(item.SummarizeButtonText, "IconOverview", OnSummarizeRow, item));
        if (item.IsUrl) menu.Items.Add(Item(_strings.Get(StringKey.UrlRefreshButton), "IconRegenerate", OnRefreshUrl, item));
        if (item.CanRetry) menu.Items.Add(Item(item.RetryText, "IconRegenerate", OnRetrySourceRow, item));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(_strings.Get(StringKey.DeleteButton), "IconDelete", OnDeleteRow, item.Id));
        return menu;
    }

    private void OnSourceMore(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SourceItem item } anchor) SourceMenu(item).ShowAt(anchor);
    }

    private void OnSourceRowRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SourceItem item } anchor)
        {
            SourceMenu(item).ShowAt(anchor, e.GetPosition(anchor));
            e.Handled = true;
        }
    }

    private async void OnDeleteRow(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: long id }) await ViewModel.DeleteAsync(id);
    }

    private async void OnSummarizeRow(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SourceItem item }) await ViewModel.SummarizeAsync(item);
    }

    // E2: re-crawl URL source
    private async void OnRefreshUrl(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: SourceItem item }) await ViewModel.RefreshUrlAsync(item);
    }

    // B7: preview source chunks
    private async void OnPreviewRow(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: SourceItem item }) return;
        var source = _store.Source(item.Id);
        if (source is null) return;
        var dialog = new SourcePreviewDialog(source) { XamlRoot = XamlRoot };
        await dialog.ShowAsync();
    }

    // B8: manage tags for a source via ContentDialog.
    private async void OnManageSourceTags(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: SourceItem item }) return;

        var panel = new StackPanel { Spacing = 8 };
        var tagRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var chipStyle = (Style)Application.Current.Resources["ChipButtonStyle"];

        void RebuildChips()
        {
            tagRow.Children.Clear();
            foreach (var tag in item.Tags)
            {
                var chip = new Button { Content = $"{tag.Name} ×", Style = chipStyle, Tag = tag };
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
            var btn = new Button { Content = $"+ {t.Name}", Style = chipStyle, Tag = t };
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
            XamlRoot = XamlRoot,
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
}

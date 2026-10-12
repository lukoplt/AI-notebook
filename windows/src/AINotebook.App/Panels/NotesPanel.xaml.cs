using AINotebook.App.Dialogs;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Panels;

/// <summary>Right panel › Notes (spec §2.3). A click opens the note as a document via NoteJumpCoordinator.</summary>
public sealed partial class NotesPanel : UserControl
{
    public NotesViewModel ViewModel { get; }

    private static ILocalizedStrings Strings => App.Current.Services.GetRequiredService<ILocalizedStrings>();
    private readonly ILocalizedStrings _t;
    private readonly NotebookStore _store;
    private readonly NoteJumpCoordinator _jump;
    private readonly long _notebookId;
    private readonly AINotebook.App.Shell.NavigationState _nav;
    private bool _suppressSelection;

    public NotesPanel(long notebookId, AINotebook.App.Shell.NavigationState nav)
    {
        _nav = nav;
        var sp = App.Current.Services;
        // Own instance: the panel's selection never drives the document editor.
        ViewModel = sp.GetRequiredService<NotesViewModel>();
        _t = sp.GetRequiredService<ILocalizedStrings>();
        _store = sp.GetRequiredService<NotebookStore>();
        _jump = sp.GetRequiredService<NoteJumpCoordinator>();
        _notebookId = notebookId;
        InitializeComponent();

        SearchBox.PlaceholderText = _t.Get(StringKey.NotesSearchPlaceholder);
        EmptyNotesText.Text = _t.Get(StringKey.NotesEmptyState);
        EmptyNewButton.Content = _t.Get(StringKey.NotesNewButton);
        BulkDeleteButton.Content = _t.Get(StringKey.BulkDeleteSelectedButton);
        BulkDoneButton.Content = _t.Get(StringKey.Close);
        Label(NewNoteButton, _t.Get(StringKey.NotesNewButton));
        Label(PanelMoreButton, _t.Get(StringKey.ShellMore));

        ViewModel.FilteredNotes.CollectionChanged += (_, _) => RefreshEmptyState();
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NotesViewModel.IsBulkMode)) ApplyBulkMode();
            if (e.PropertyName == nameof(NotesViewModel.TagFilterId)) ApplyTagFilter();
        };
        Loaded += async (_, _) =>
        {
            await ViewModel.LoadAsync(_notebookId);
            RefreshEmptyState();
        };
    }

    private static void Label(FrameworkElement element, string text)
    {
        AutomationProperties.SetName(element, text);
        ToolTipService.SetToolTip(element, text);
    }

    /// <summary>Row caption: origin · last edit (x:Bind function).</summary>
    public static string Caption(NoteOrigin origin, DateTime updatedAt)
    {
        var t = Strings;
        string label = origin switch
        {
            NoteOrigin.Chat => t.Get(StringKey.NoteOriginChat),
            NoteOrigin.Transformation => t.Get(StringKey.NoteOriginTransformation),
            _ => t.Get(StringKey.NoteOriginManual),
        };
        return label + " · " + updatedAt.ToLocalTime().ToString("g", System.Globalization.CultureInfo.CurrentCulture);
    }

    private void RefreshEmptyState()
    {
        bool empty = ViewModel.FilteredNotes.Count == 0;
        EmptyNotes.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        NotesList.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ApplyTagFilter()
    {
        var tag = ViewModel.AllNotebookTags.FirstOrDefault(t => t.Id == ViewModel.TagFilterId);
        TagFilterChip.Visibility = tag is null ? Visibility.Collapsed : Visibility.Visible;
        TagFilterText.Text = tag?.Name ?? "";
    }

    private void OnClearTagFilter(object sender, RoutedEventArgs e) => ViewModel.TagFilterId = null;

    private void OnNoteClick(object sender, ItemClickEventArgs e)
    {
        if (ViewModel.IsBulkMode) return;
        if (e.ClickedItem is Note { Id: long id }) _jump.Request(id);
    }

    /// <summary>Row context menu (macOS parity): Export Markdown, Delete.</summary>
    private void OnNoteRightTapped(object sender, Microsoft.UI.Xaml.Input.RightTappedRoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: Note note } anchor) return;
        var menu = new MenuFlyout();
        var export = new MenuFlyoutItem { Text = _t.Get(StringKey.ExportNoteMarkdown), Icon = new FontIcon { Glyph = (string)Application.Current.Resources["IconExport"] } };
        export.Click += async (_, _) => await ExportMarkdownAsync(note);
        menu.Items.Add(export);
        menu.Items.Add(new MenuFlyoutSeparator());
        var delete = new MenuFlyoutItem { Text = _t.Get(StringKey.DeleteButton), Icon = new FontIcon { Glyph = (string)Application.Current.Resources["IconDelete"] } };
        delete.Click += async (_, _) => await DeleteAsync(note);
        menu.Items.Add(delete);
        menu.ShowAt(anchor, e.GetPosition(anchor));
        e.Handled = true;
    }

    private async Task ExportMarkdownAsync(Note note)
    {
        var picker = new Windows.Storage.Pickers.FileSavePicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow));
        picker.SuggestedFileName = string.IsNullOrWhiteSpace(note.Title) ? "note" : note.Title;
        picker.DefaultFileExtension = ".md";
        picker.FileTypeChoices.Add("Markdown", [".md"]);
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        try { await Windows.Storage.FileIO.WriteTextAsync(file, AINotebook.Core.Rag.ExportService.ExportNoteMarkdown(note)); }
        catch (Exception ex) { ViewModel.ErrorMessage = ex.Message; }
    }

    /// <summary>Deletes one note; an open document of it closes first (back to the thread).</summary>
    private async Task DeleteAsync(Note note)
    {
        if (note.Id is not long id) return;
        try
        {
            if (_nav.Selection is AINotebook.App.Shell.ShellSelection.Note open && open.NoteId == id)
            {
                App.Current.Services.GetRequiredService<NoteEditorCoordinator>().Reset(); // nothing to save
                await _nav.GoBackAsync();
            }
            _store.DeleteNote(id);
            await ViewModel.ReloadAsync();
        }
        catch (Exception ex) { ViewModel.ErrorMessage = ex.Message; }
    }

    /// <summary>+ New: an untitled note opens as a document.</summary>
    private async void OnNewNote(object sender, RoutedEventArgs e)
    {
        try
        {
            var note = _store.CreateNote(_notebookId, _t.Get(StringKey.NoteUntitled), "");
            await ViewModel.ReloadAsync();
            if (note.Id is long id) _jump.Request(id);
        }
        catch (Exception ex) { ViewModel.ErrorMessage = ex.Message; }
    }

    /// <summary>Panel "…": multi-select, tag filter, tool history (spec §2.3 / §2.7).</summary>
    private void OnPanelMore(object sender, RoutedEventArgs e)
    {
        var menu = new MenuFlyout();
        var bulk = new ToggleMenuFlyoutItem
        {
            Text = _t.Get(StringKey.BulkSelectButton),
            IsChecked = ViewModel.IsBulkMode,
            Icon = new FontIcon { Glyph = (string)Application.Current.Resources["IconBulkSelect"] },
        };
        bulk.Click += (_, _) => ViewModel.ToggleBulkModeCommand.Execute(null);
        menu.Items.Add(bulk);
        if (ViewModel.AllNotebookTags.Count > 0)
        {
            var filter = new MenuFlyoutSubItem
            {
                Text = _t.Get(StringKey.FilterByTagLabel),
                Icon = new FontIcon { Glyph = (string)Application.Current.Resources["IconTag"] },
            };
            var all = new ToggleMenuFlyoutItem { Text = _t.Get(StringKey.AllTagsOption), IsChecked = ViewModel.TagFilterId is null };
            all.Click += (_, _) => ViewModel.TagFilterId = null;
            filter.Items.Add(all);
            foreach (var tag in ViewModel.AllNotebookTags)
            {
                long id = tag.Id;
                var item = new ToggleMenuFlyoutItem { Text = tag.Name, IsChecked = ViewModel.TagFilterId == id };
                item.Click += (_, _) => ViewModel.TagFilterId = id;
                filter.Items.Add(item);
            }
            menu.Items.Add(filter);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        var history = new MenuFlyoutItem
        {
            Text = _t.Get(StringKey.ToolHistory),
            Icon = new FontIcon { Glyph = (string)Application.Current.Resources["IconHistory"] },
        };
        history.Click += async (_, _) =>
        {
            var dialog = new TransformationHistoryDialog(_notebookId) { XamlRoot = XamlRoot };
            await dialog.ShowAsync();
        };
        menu.Items.Add(history);
        menu.ShowAt((FrameworkElement)sender);
    }

    /// <summary>W-6: switch the list between opening notes and ticking them.</summary>
    private void ApplyBulkMode()
    {
        _suppressSelection = true;
        if (NotesList.SelectionMode == ListViewSelectionMode.Multiple) NotesList.SelectedItems.Clear();
        NotesList.SelectionMode = ViewModel.IsBulkMode ? ListViewSelectionMode.Multiple : ListViewSelectionMode.None;
        NotesList.IsItemClickEnabled = !ViewModel.IsBulkMode;
        _suppressSelection = false;
        ViewModel.SetBulkSelection(Array.Empty<long>());
    }

    private void OnNotesSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelection || !ViewModel.IsBulkMode) return;
        ViewModel.SetBulkSelection(NotesList.SelectedItems.OfType<Note>().Where(n => n.Id is not null).Select(n => n.Id!.Value));
    }

    private async void OnBulkDeleteNotes(object sender, RoutedEventArgs e)
    {
        var count = ViewModel.BulkSelectionCount;
        if (count == 0) return;
        var dialog = new ContentDialog
        {
            Title = _t.Get(StringKey.BulkDeleteSelectedButton),
            Content = string.Format(_t.Get(StringKey.BulkDeleteConfirmFormat), count),
            PrimaryButtonText = _t.Get(StringKey.Delete),
            CloseButtonText = _t.Get(StringKey.Cancel),
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = XamlRoot
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            await ViewModel.BulkDeleteCommand.ExecuteAsync(null);
    }
}

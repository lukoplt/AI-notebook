using System;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.App.Dialogs;
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

public sealed partial class NotesPage : Page
{
    public NotesViewModel ViewModel { get; }
    private readonly AttachmentStore _attachments;
    private readonly ILocalizedStrings _t;
    private bool _suppressSelection;

    public string SearchPlaceholder => _t.Get(StringKey.NoteSearchPlaceholder);

    public NotesPage()
    {
        ViewModel = App.Current.Services.GetRequiredService<NotesViewModel>();
        _attachments = App.Current.Services.GetRequiredService<AttachmentStore>();
        _t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();

        NotesTitle.Text = _t.Get("notesSectionTitle");
        NewButtonTop.Content = _t.Get("notesNewButton");
        NewButtonEmpty.Content = _t.Get("notesNewButton");
        EmptyNotesText.Text = _t.Get("notesEmptyState");
        NoSelectionText.Text = _t.Get("notesEmptyState");
        AddTagText.Text = _t.Get(StringKey.AddTagButton);
        ToolTipService.SetToolTip(ExportNoteButton, _t.Get(StringKey.ExportNoteButton));
        ExportMarkdownItem.Text = _t.Get(StringKey.ExportNoteMarkdown);
        ExportPdfItem.Text = _t.Get(StringKey.ExportNotePdf);

        ViewModel.PropertyChanged += OnVmPropertyChanged;
        ViewModel.UnsavedDialogRequested += async () => await ShowUnsavedDialog();
        ViewModel.HistoryRequested += async id => await ShowHistoryDialog(id);
        ViewModel.Notes.CollectionChanged += (_, _) => RefreshEmptyState();
        ViewModel.FilteredNotes.CollectionChanged += (_, _) => RefreshEmptyState();

        ChatPanel.SetCurrentNoteProvider(() => ViewModel.CurrentNote);
    }

    /// Window-level Ctrl+S forwarding (M10.1): force a synchronous manual save of the open note.
    public void TriggerManualSave() => Editor.FlushPendingSave();

    /// Window-level Ctrl+Shift+H forwarding (M10.1): open the note history.
    public void TriggerHistory() => ViewModel.ShowHistoryCommand.Execute(null);

    public async void Load(long notebookId)
    {
        await ViewModel.LoadAsync(notebookId);
        await ChatPanel.LoadAsync(notebookId);
        SyncSelectionToList();
        RefreshEmptyState();
        ReconfigureEditor();
    }

    private void OnVmPropertyChanged(object? s, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(NotesViewModel.SelectedNote))
        {
            SyncSelectionToList();
            ReconfigureEditor();
        }
    }

    private void OnNotesSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelection) return;
        var id = (NotesList.SelectedItem as Note)?.Id;
        // Route through the gate; if the gate cancels, snap back happens via ApplySelection.
        ViewModel.AttemptSelect(id);
        SyncSelectionToList();   // re-sync if the gate kept the old selection
    }

    private void SyncSelectionToList()
    {
        _suppressSelection = true;
        NotesList.SelectedItem = ViewModel.SelectedNote;
        _suppressSelection = false;
    }

    private void ReconfigureEditor()
    {
        if (ViewModel.SelectedNote is { } n && n.Id is { } id)
        {
            NoSelection.Visibility = Visibility.Collapsed;
            Editor.Visibility = Visibility.Visible;
            Editor.OnChange = md => ViewModel.DraftBody = md;
            Editor.OnSaveRequested = body => ViewModel.Save(id, body);
            Editor.OnShowHistory = () => ViewModel.ShowHistoryCommand.Execute(null);
            Editor.Configure(id, n.NoteUuid, n.BodyMd, _attachments, ViewModel.EditorCoordinator, _t);
        }
        else
        {
            Editor.Visibility = Visibility.Collapsed;
            NoSelection.Visibility = Visibility.Visible;
        }
    }

    private void RefreshEmptyState()
    {
        var empty = ViewModel.FilteredNotes.Count == 0;
        EmptyNotes.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        NotesList.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
    }

    private async System.Threading.Tasks.Task ShowUnsavedDialog()
    {
        var dialog = new ContentDialog
        {
            XamlRoot = this.XamlRoot,
            Title = _t.Get("unsavedChangesTitle"),
            Content = _t.Get("unsavedChangesMessage"),
            PrimaryButtonText = _t.Get("unsavedSaveButton"),
            SecondaryButtonText = _t.Get("unsavedDiscardButton"),
            CloseButtonText = _t.Get("cancelButton"),
            DefaultButton = ContentDialogButton.Primary
        };
        var result = await dialog.ShowAsync();
        switch (result)
        {
            case ContentDialogResult.Primary: ViewModel.OnUnsavedSave(); break;
            case ContentDialogResult.Secondary: ViewModel.OnUnsavedDiscard(); break;
            default: ViewModel.OnUnsavedCancel(); break;
        }
        SyncSelectionToList();
    }

    // B1: export selected note as Markdown.
    private async void OnExportNote(object sender, RoutedEventArgs e)
    {
        if (ViewModel.SelectedNote is not { } note) return;
        var picker = new FileSavePicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(App.MainWindow));
        picker.SuggestedFileName = string.IsNullOrWhiteSpace(note.Title) ? "note" : note.Title;
        picker.DefaultFileExtension = ".md";
        picker.FileTypeChoices.Add("Markdown", [".md"]);
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        try { await FileIO.WriteTextAsync(file, ExportService.ExportNoteMarkdown(note)); }
        catch (Exception ex) { ViewModel.ErrorMessage = ex.ToString(); }
    }

    // W-1 (B1 PDF): export the selected note as a PDF via WebView2 print.
    private async void OnExportNotePdf(object sender, RoutedEventArgs e)
    {
        if (ViewModel.SelectedNote is not { } note) return;
        var picker = new FileSavePicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(App.MainWindow));
        picker.SuggestedFileName = string.IsNullOrWhiteSpace(note.Title) ? "note" : note.Title;
        picker.DefaultFileExtension = ".pdf";
        picker.FileTypeChoices.Add("PDF", [".pdf"]);
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        try { await Editor.ExportPdfAsync(file.Path); }
        catch (Exception ex) { ViewModel.ErrorMessage = ex.ToString(); }
    }

    // B8: remove a tag chip from the current note.
    private void OnRemoveNoteTag(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: Tag tag })
            ViewModel.ToggleNoteTagCommand.Execute(tag);
    }

    // B8: add a tag to the current note via ContentDialog.
    private async void OnAddNoteTag(object sender, RoutedEventArgs e)
    {
        var box = new TextBox
        {
            PlaceholderText = _t.Get(StringKey.TagNamePlaceholder),
            MinWidth = 200
        };
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(box);
        if (ViewModel.AllNotebookTags.Count > 0)
        {
            var wrap = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            foreach (var t in ViewModel.AllNotebookTags)
            {
                var btn = new Button { Content = t.Name, Tag = t, Padding = new Thickness(6, 2, 6, 2), FontSize = 11 };
                btn.Click += (_, _) => ViewModel.ToggleNoteTagCommand.Execute(btn.Tag as Tag);
                wrap.Children.Add(btn);
            }
            panel.Children.Add(wrap);
        }
        var dialog = new ContentDialog
        {
            XamlRoot = this.XamlRoot,
            Title = _t.Get(StringKey.AddTagButton),
            Content = panel,
            PrimaryButtonText = _t.Get(StringKey.Create),
            CloseButtonText = _t.Get(StringKey.Cancel)
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && !string.IsNullOrWhiteSpace(box.Text))
            ViewModel.CreateNoteTagCommand.Execute(box.Text.Trim());
    }

    private async System.Threading.Tasks.Task ShowHistoryDialog(long noteId)
    {
        var dialog = new NoteHistoryDialog(noteId) { XamlRoot = this.XamlRoot };
        await dialog.ShowAsync();
        await ViewModel.ReloadAsync();   // mirrors .sheet onDismiss reload (restore may have changed body)
        ReconfigureEditor();
    }
}

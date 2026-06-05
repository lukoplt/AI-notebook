using System;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.App.Dialogs;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

public sealed partial class NotesPage : Page
{
    public NotesViewModel ViewModel { get; }
    private readonly AttachmentStore _attachments;
    private readonly ILocalizedStrings _t;
    private bool _suppressSelection;

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

        ViewModel.PropertyChanged += OnVmPropertyChanged;
        ViewModel.UnsavedDialogRequested += async () => await ShowUnsavedDialog();
        ViewModel.HistoryRequested += async id => await ShowHistoryDialog(id);
        ViewModel.Notes.VectorChanged += (_, _) => RefreshEmptyState();

        ChatPanel.SetCurrentNoteProvider(() => ViewModel.CurrentNote);
    }

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
        var empty = ViewModel.Notes.Count == 0;
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

    private async System.Threading.Tasks.Task ShowHistoryDialog(long noteId)
    {
        var dialog = new NoteHistoryDialog(noteId) { XamlRoot = this.XamlRoot };
        await dialog.ShowAsync();
        await ViewModel.ReloadAsync();   // mirrors .sheet onDismiss reload (restore may have changed body)
        ReconfigureEditor();
    }
}

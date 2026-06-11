using System;
using System.IO;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace AINotebook.App.Views;

public sealed partial class NotebookDetailPage : Page
{
    public NotebookDetailViewModel ViewModel { get; }
    private readonly NotebookStore _store;
    private readonly ILocalizedStrings _l;

    /// Bridge TabSwitchCoordinator.Tab <-> Pivot SelectedIndex (Sources=0..Settings=4).
    public int TabIndex
    {
        get => (int)ViewModel.SelectedTab;
        set => ViewModel.SelectedTab = (TabSwitchCoordinator.Tab)value;
    }

    public NotebookDetailPage(Notebook notebook)
    {
        var sp = App.Current.Services;
        var tabSwitch = sp.GetRequiredService<TabSwitchCoordinator>();
        _l = sp.GetRequiredService<ILocalizedStrings>();
        _store = sp.GetRequiredService<NotebookStore>();
        ViewModel = new NotebookDetailViewModel(notebook, tabSwitch, _l, _store);
        InitializeComponent();

        var id = notebook.Id!.Value;

        var sources = new SourceListPage(notebook);
        SourcesHost.Children.Add(sources);

        var chat = new ChatPage();
        ChatHost.Children.Add(chat);
        chat.Load(id);

        var notes = new NotesPage();
        NotesHost.Children.Add(notes);
        notes.Load(id);

        var transformations = new TransformationsPage();
        TransformationsHost.Children.Add(transformations);
        transformations.Load(id);

        // C1: localize instructions tab
        InstructionsLabel.Text = _l.Get(StringKey.NotebookInstructionsLabel);
        InstructionsHint.Text = _l.Get(StringKey.NotebookInstructionsPlaceholder);
        SaveInstructionsButton.Content = _l.Get(StringKey.UnsavedSaveButton);
        // B3: localize backup section
        BackupSectionLabel.Text = _l.Get(StringKey.BackupButton);
        BackupButton.Content = _l.Get(StringKey.BackupButton);
        RestoreButton.Content = _l.Get(StringKey.BackupRestoreButton);

        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NotebookDetailViewModel.SelectedTab))
                Bindings.Update(); // refresh TabIndex two-way target after a coordinator jump
        };
    }

    // B3: backup the SQLite database to a user-chosen file.
    private async void OnBackup(object sender, RoutedEventArgs e)
    {
        var picker = new FileSavePicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(App.MainWindow));
        picker.SuggestedFileName = "ainotebook-backup";
        picker.DefaultFileExtension = ".db";
        picker.FileTypeChoices.Add("SQLite database", [".db"]);
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        try
        {
            _store.BackupTo(file.Path);
            ViewModel.BackupStatus = _l.Get(StringKey.ExportSuccess);
        }
        catch (Exception ex) { ViewModel.BackupStatus = ex.Message; }
    }

    // B3: restore the database from a backup file (destructive — confirms first).
    private async void OnRestore(object sender, RoutedEventArgs e)
    {
        var confirmDialog = new ContentDialog
        {
            XamlRoot = this.XamlRoot,
            Title = _l.Get(StringKey.BackupRestoreButton),
            Content = _l.Get(StringKey.BackupRestoreConfirm),
            PrimaryButtonText = _l.Get(StringKey.Delete),
            CloseButtonText = _l.Get(StringKey.Cancel),
            DefaultButton = ContentDialogButton.Close
        };
        if (await confirmDialog.ShowAsync() != ContentDialogResult.Primary) return;

        var picker = new FileOpenPicker();
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(App.MainWindow));
        picker.FileTypeFilter.Add(".db");
        var file = await picker.PickSingleFileAsync();
        if (file is null) return;
        try
        {
            var dest = StorePath.Production().FilePath!;
            File.Copy(file.Path, dest, overwrite: true);
            App.MainWindow.Close(); // restart required to reload from restored DB
        }
        catch (Exception ex) { ViewModel.BackupStatus = ex.Message; }
    }
}

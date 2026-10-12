using AINotebook.App.Dialogs;
using AINotebook.App.Services;
using AINotebook.App.Shell;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace AINotebook.App.Document;

/// <summary>
/// Note document in the main area (spec §2.4): replaces the three-column NotesPage. Unsaved
/// changes are guarded by the shell (NavigationState.LeaveGuard over NoteEditorCoordinator).
/// </summary>
public sealed partial class NoteDocumentPage : Page
{
    public NotesViewModel ViewModel { get; }
    private readonly NavigationState _nav;
    private readonly AttachmentStore _attachments;
    private readonly ILocalizedStrings _t;
    private long? _configuredNoteId;

    public NoteDocumentPage(NavigationState nav)
    {
        _nav = nav;
        var sp = App.Current.Services;
        ViewModel = sp.GetRequiredService<NotesViewModel>();
        _attachments = sp.GetRequiredService<AttachmentStore>();
        _t = sp.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();
        ApplyStrings();
        _t.PropertyChanged += (_, _) => ApplyStrings();

        Editor.StatusChanged += (glyph, text) => { StatusIcon.Glyph = glyph; StatusText.Text = text; };
        ViewModel.HistoryRequested += async id => await ShowHistoryAsync(id);
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NotesViewModel.SelectedNote)) ConfigureEditor();
        };
    }

    private void ApplyStrings()
    {
        Label(BackButton, _t.Get(StringKey.ShellBack) + " (Alt+←)");
        Label(HistoryButton, _t.Get(StringKey.HistoryButton) + " (Ctrl+Shift+H)");
        Label(ExportButton, _t.Get(StringKey.DocumentExport));
        Label(SaveButton, _t.Get(StringKey.Save) + " (Ctrl+S)");
        Label(TogglePanelButton, _t.Get(StringKey.ShellTogglePanel));
        TitleBox.PlaceholderText = _t.Get(StringKey.NoteTitlePlaceholder);
        ExportMarkdownItem.Text = _t.Get(StringKey.ExportNoteMarkdown);
        ExportPdfItem.Text = _t.Get(StringKey.ExportNotePdf);
        AddTagText.Text = _t.Get(StringKey.AddTagButton);
    }

    private static void Label(FrameworkElement element, string text)
    {
        AutomationProperties.SetName(element, text);
        ToolTipService.SetToolTip(element, text);
    }

    /// <summary>The note in the editor (the note chat uses it as context).</summary>
    public Note? CurrentNote => ViewModel.CurrentNote;

    public async Task OpenAsync(long notebookId, long noteId)
    {
        await ViewModel.LoadAsync(notebookId);
        ViewModel.Open(noteId);
        ConfigureEditor();
    }

    /// <summary>Reconfigures the editor only when another note opens (saves refresh SelectedNote too).</summary>
    private void ConfigureEditor()
    {
        if (ViewModel.SelectedNote is not { Id: long id } note || id == _configuredNoteId) return;
        _configuredNoteId = id;
        Editor.OnChange = md => ViewModel.DraftBody = md;
        Editor.OnSaveRequested = body => ViewModel.Save(id, body);
        Editor.Configure(id, note.NoteUuid, note.BodyMd, _attachments, ViewModel.EditorCoordinator, _t);
        ViewModel.EditorCoordinator.FlushPendingSave = Editor.FlushPendingSave;
    }

    private void OnTitleChanged(object sender, TextChangedEventArgs e)
    {
        // Only user edits: the loaded title equals the saved one.
        if (ViewModel.SelectedNote is { } note && TitleBox.Text != note.Title) Editor.MarkTitleChanged();
    }

    private async void OnBack(object sender, RoutedEventArgs e) => await _nav.GoBackAsync();
    private void OnTogglePanel(object sender, RoutedEventArgs e) => _nav.TogglePanel();
    private void OnSave(object sender, RoutedEventArgs e) => Editor.FlushPendingSave();
    private void OnHistory(object sender, RoutedEventArgs e) => ViewModel.ShowHistoryCommand.Execute(null);

    private void OnSaveAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        Editor.FlushPendingSave();
    }

    private void OnHistoryAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        ViewModel.ShowHistoryCommand.Execute(null);
    }

    private async Task ShowHistoryAsync(long noteId)
    {
        var dialog = new NoteHistoryDialog(noteId) { XamlRoot = XamlRoot };
        await dialog.ShowAsync();
        await ViewModel.ReloadAsync(); // a restore may have changed the body
        _configuredNoteId = null;
        ConfigureEditor();
    }

    // B1: export as Markdown.
    private async void OnExportMarkdown(object sender, RoutedEventArgs e)
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
        catch (Exception ex) { ViewModel.ErrorMessage = ex.Message; }
    }

    // W-1 (B1 PDF): export via WebView2 print-to-PDF.
    private async void OnExportPdf(object sender, RoutedEventArgs e)
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
        catch (Exception ex) { ViewModel.ErrorMessage = ex.Message; }
    }

    // B8: tags.
    private void OnRemoveTag(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: Tag tag }) ViewModel.ToggleNoteTagCommand.Execute(tag);
    }

    private async void OnAddTag(object sender, RoutedEventArgs e)
    {
        var box = new TextBox { PlaceholderText = _t.Get(StringKey.TagNamePlaceholder), MinWidth = (double)Application.Current.Resources["SizeSidebarMin"] };
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(box);
        if (ViewModel.AllNotebookTags.Count > 0)
        {
            var wrap = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            var chip = (Style)Application.Current.Resources["ChipButtonStyle"];
            foreach (var t in ViewModel.AllNotebookTags)
            {
                var btn = new Button { Content = t.Name, Tag = t, Style = chip };
                btn.Click += (_, _) => ViewModel.ToggleNoteTagCommand.Execute(btn.Tag as Tag);
                wrap.Children.Add(btn);
            }
            panel.Children.Add(wrap);
        }
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = _t.Get(StringKey.AddTagButton),
            Content = panel,
            PrimaryButtonText = _t.Get(StringKey.Create),
            CloseButtonText = _t.Get(StringKey.Cancel)
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && !string.IsNullOrWhiteSpace(box.Text))
            ViewModel.CreateNoteTagCommand.Execute(box.Text.Trim());
    }
}

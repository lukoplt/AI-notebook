using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Ingestion;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace AINotebook.App.Views;

/// <summary>Which tab the add-source dialog opens on ("+ › Add file / Add URL / Add text").</summary>
public enum AddSourceKind { File, Url, Text }

public sealed partial class AddSourceDialog : ContentDialog
{
    private enum Mode { File, Url, Text }

    private readonly IngestionService _ingestion;
    private readonly long _notebookId;
    private readonly LocalizedStrings _strings;
    private Mode _mode = Mode.File;
    private StorageFile? _file;
    private bool _working;

    public bool DidIngest { get; private set; }

    public AddSourceDialog(IngestionService ingestion, long notebookId, LocalizedStrings strings,
        AddSourceKind initial = AddSourceKind.File)
    {
        this.InitializeComponent();
        _ingestion = ingestion;
        _notebookId = notebookId;
        _strings = strings;

        Title = strings.Get(StringKey.AddSourceSheetTitle);
        PrimaryButtonText = strings.Get(StringKey.AddSourceConfirm);
        CloseButtonText = strings.Get(StringKey.CancelButton);

        FileTab.Text = strings.Get(StringKey.AddSourceFromFile);
        UrlTab.Text = strings.Get(StringKey.AddSourceFromURL);
        TextTab.Text = strings.Get(StringKey.AddSourceFromText);
        ChooseFileButton.Content = strings.Get(StringKey.AddSourceFromFile);
        UrlBox.PlaceholderText = strings.Get(StringKey.AddSourceURLPlaceholder);
        RawTitleBox.PlaceholderText = strings.Get(StringKey.AddSourceTitlePlaceholder);
        RawTextBox.PlaceholderText = strings.Get(StringKey.AddSourceTextPlaceholder);

        ModeBar.SelectedItem = initial switch
        {
            AddSourceKind.Url => UrlTab,
            AddSourceKind.Text => TextTab,
            _ => FileTab,
        };
        UpdateCanSubmit();
    }

    private void OnModeChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        _mode = ModeBar.SelectedItem == UrlTab ? Mode.Url
              : ModeBar.SelectedItem == TextTab ? Mode.Text
              : Mode.File;
        FilePanel.Visibility = _mode == Mode.File ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        UrlPanel.Visibility = _mode == Mode.Url ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        TextPanel.Visibility = _mode == Mode.Text ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        UpdateCanSubmit();
    }

    private void OnInputChanged(object sender, TextChangedEventArgs e) => UpdateCanSubmit();

    private bool CanSubmit() => _mode switch
    {
        Mode.File => _file is not null,
        Mode.Url => Uri.TryCreate(UrlBox.Text, UriKind.Absolute, out var u)
                    && (u.Scheme.StartsWith("http", StringComparison.OrdinalIgnoreCase)),
        Mode.Text => !string.IsNullOrWhiteSpace(RawTitleBox.Text)
                     && !string.IsNullOrWhiteSpace(RawTextBox.Text),
        _ => false
    };

    private void UpdateCanSubmit() => IsPrimaryButtonEnabled = !_working && CanSubmit();

    private async void OnChooseFile(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        var picker = new FileOpenPicker
        {
            ViewMode = PickerViewMode.List,
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary
        };
        foreach (var ext in new[] { ".pdf", ".txt", ".md", ".docx", ".pptx", ".xlsx", ".docm", ".pptm", ".xlsm", ".eml", ".msg" })
            picker.FileTypeFilter.Add(ext);

        var hwnd = WindowNative.GetWindowHandle(App.MainWindow);
        InitializeWithWindow.Initialize(picker, hwnd);

        var picked = await picker.PickSingleFileAsync();
        if (picked is not null)
        {
            _file = picked;
            ChosenFileText.Text = picked.Name;
            UpdateCanSubmit();
        }
    }

    private async void OnPrimaryClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var deferral = args.GetDeferral();
        args.Cancel = true; // keep open unless ingestion succeeds

        if (!CanSubmit() || _working) { deferral.Complete(); return; }

        _working = true;
        ErrorBar.IsOpen = false;
        Busy.IsActive = true;
        IsPrimaryButtonEnabled = false;
        IsSecondaryButtonEnabled = false;

        try
        {
            switch (_mode)
            {
                case Mode.File:
                    await _ingestion.IngestFileAsync(new Uri(_file!.Path), _notebookId);
                    break;
                case Mode.Url:
                    await _ingestion.IngestUrlAsync(new Uri(UrlBox.Text), _notebookId);
                    break;
                case Mode.Text:
                    await _ingestion.IngestRawTextAsync(RawTitleBox.Text, RawTextBox.Text, _notebookId);
                    break;
            }
            DidIngest = true;
            args.Cancel = false; // allow close
        }
        catch (Exception ex)
        {
            // Localized category only; raw exception text can carry paths or response bodies.
            ErrorBar.Message = ChatFailureText.Format(ex, key => _strings.Get(key));
            ErrorBar.IsOpen = true;
        }
        finally
        {
            _working = false;
            Busy.IsActive = false;
            IsSecondaryButtonEnabled = true;
            UpdateCanSubmit();
            deferral.Complete();
        }
    }

    private void OnCloseClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        // Cancel button: just dismiss (mirrors the mac Cancel).
    }
}

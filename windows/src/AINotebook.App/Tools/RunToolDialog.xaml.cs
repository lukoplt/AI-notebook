using AINotebook.App.Dialogs;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace AINotebook.App.Tools;

/// <summary>"+ › Run tool": TransformationsViewModel unchanged; the result note opens as a document.</summary>
public sealed partial class RunToolDialog : ContentDialog
{
    public TransformationsViewModel ViewModel { get; }
    private readonly ILocalizedStrings _t;
    private readonly long? _templateId;
    private bool _loaded;

    public RunToolDialog(long notebookId, long? templateId)
    {
        ViewModel = App.Current.Services.GetRequiredService<TransformationsViewModel>();
        _t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        _templateId = templateId;
        InitializeComponent();

        Title = _t.Get(StringKey.ComposerRunTool);
        CloseButtonText = _t.Get(StringKey.Close);
        PickerLabel.Text = _t.Get("transformationPickerLabel");
        PreviewBtn.Content = _t.Get("aiToolsPreviewButton");
        ScopeSource.Content = _t.Get(StringKey.ToolScopeSource);
        ScopeNotebook.Content = _t.Get(StringKey.ScopeWholeNotebook);
        ScopeSeg.Header = _t.Get(StringKey.ToolScope);
        ScopeAll.Content = _t.Get("aiToolsScopeAllSources");
        ScopeHint.Text = _t.Get("aiToolsScopeHint");
        SourceCombo.Header = _t.Get("transformationSourcePickerLabel");
        RunBtn.Content = _t.Get("transformationRunButton");

        ViewModel.PropertyChanged += OnVmChanged;
        Opened += async (_, _) =>
        {
            if (_loaded) return; // re-shown after the prompt preview: keep the user's choices
            _loaded = true;
            await ViewModel.LoadAsync(notebookId);
            if (_templateId is long id && ViewModel.Transformations.FirstOrDefault(t => t.Id == id) is { } preset)
                ViewModel.SelectedTransformation = preset;
            SyncScopeSegment();
            RenderContent();
        };
    }

    private void OnVmChanged(object? s, System.ComponentModel.PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(TransformationsViewModel.Scope): SyncScopeSegment(); break;
            case nameof(TransformationsViewModel.Running):
            case nameof(TransformationsViewModel.ResultNoteId):
            case nameof(TransformationsViewModel.BatchSavedCount):
            case nameof(TransformationsViewModel.ResultBody):
            case nameof(TransformationsViewModel.BatchCompleted):
                RenderContent(); break;
        }
    }

    private void SyncScopeSegment()
    {
        ScopeSeg.SelectedIndex = ViewModel.Scope switch
        {
            BatchScope.Source => 0, BatchScope.Notebook => 1, BatchScope.AllSources => 2, _ => 0
        };
        SourceCombo.Visibility = ViewModel.Scope == BatchScope.Source ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnScopeChanged(object sender, SelectionChangedEventArgs e)
    {
        ViewModel.Scope = ScopeSeg.SelectedIndex switch
        {
            1 => BatchScope.Notebook, 2 => BatchScope.AllSources, _ => BatchScope.Source
        };
        SourceCombo.Visibility = ViewModel.Scope == BatchScope.Source ? Visibility.Visible : Visibility.Collapsed;
    }

    private static object Res(string key) => Application.Current.Resources[key];

    /// <summary>Running / single result / batch toast / nothing yet.</summary>
    private void RenderContent()
    {
        ContentHost.Children.Clear();
        if (ViewModel.Running) ContentHost.Children.Add(BuildRunning());
        else if (ViewModel.BatchSavedCount is > 1) ContentHost.Children.Add(BuildSaved(ViewModel.BatchSavedFormat(), body: null));
        else if (ViewModel.ResultNoteId is not null) ContentHost.Children.Add(BuildSaved(ViewModel.ResultSavedTitle(), ViewModel.ResultBody));
    }

    private UIElement BuildRunning()
    {
        var panel = new StackPanel { Spacing = (double)Res("Space8") };
        if (ViewModel.BatchTotal > 0)
            panel.Children.Add(new ProgressBar { Minimum = 0, Maximum = ViewModel.BatchTotal, Value = ViewModel.BatchCompleted });
        else
            panel.Children.Add(new ProgressRing { IsActive = true, HorizontalAlignment = HorizontalAlignment.Left });
        panel.Children.Add(new TextBlock
        {
            Text = ViewModel.BatchTotal > 0 ? ViewModel.RunningFormat() : _t.Get("transformationRunningStatus"),
            Style = (Style)Res("SecondaryCaption"),
        });
        if (!string.IsNullOrEmpty(ViewModel.ResultBody)) panel.Children.Add(ResultText(ViewModel.ResultBody));
        return panel;
    }

    private UIElement BuildSaved(string title, string? body)
    {
        var panel = new StackPanel { Spacing = (double)Res("Space8") };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = (double)Res("Space8") };
        row.Children.Add(new FontIcon { Glyph = (string)Res("IconSuccess"), Foreground = (Brush)Res("SuccessBrush") });
        row.Children.Add(new TextBlock { Text = title, Style = (Style)Res("TextBody"), VerticalAlignment = VerticalAlignment.Center });
        var open = new Button { Content = _t.Get("aiToolsOpenNoteButton"), Style = (Style)Res("PrimaryButtonStyle") };
        open.Click += async (_, _) =>
        {
            Hide(); // the note opens as a document behind the dialog
            await ViewModel.OpenResultNoteCommand.ExecuteAsync(null);
        };
        row.Children.Add(open);
        panel.Children.Add(row);
        if (!string.IsNullOrEmpty(body)) panel.Children.Add(ResultText(body));
        return panel;
    }

    private static UIElement ResultText(string text) => new ScrollViewer
    {
        MaxHeight = (double)Res("SizePanelMin"),
        Content = new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            Style = (Style)Res("TextBody"),
            Foreground = (Brush)Res("Text1Brush"),
        },
    };

    // Opening the prompt preview closes this dialog first (WinUI shows one ContentDialog at a time).
    private async void OnPreview(object s, RoutedEventArgs e)
    {
        if (ViewModel.SelectedTransformation is not { } tx) return;
        var src = ViewModel.Scope == BatchScope.Source ? ViewModel.SelectedSource : null;
        Hide();
        var dlg = new TransformationPromptPreviewDialog(tx, src) { XamlRoot = XamlRoot };
        await dlg.ShowAsync();
        await ShowAsync();
    }
}

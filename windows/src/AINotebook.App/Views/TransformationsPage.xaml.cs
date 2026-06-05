using System;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.App.Dialogs;
using AINotebook.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

public sealed partial class TransformationsPage : Page
{
    public TransformationsViewModel ViewModel { get; }
    private readonly ILocalizedStrings _t;

    public TransformationsPage()
    {
        ViewModel = App.Current.Services.GetRequiredService<TransformationsViewModel>();
        _t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();
        HeaderTitle.Text = _t.Get("aiToolsSectionTitle");
        HistoryBtn.Content = _t.Get("aiToolsHistoryButton");
        EditBtn.Content = _t.Get("transformationEditButton");
        PickerLabel.Text = _t.Get("transformationPickerLabel");
        PreviewBtn.Content = _t.Get("aiToolsPreviewButton");
        ScopeAll.Content = _t.Get("aiToolsScopeAllSources");
        ScopeHint.Text = _t.Get("aiToolsScopeHint");
        SourceCombo.Header = _t.Get("transformationSourcePickerLabel");
        RunBtn.Content = _t.Get("transformationRunButton");
        ViewModel.PropertyChanged += OnVmChanged;
        SyncScopeSegment();
        RenderContent();
    }

    public async void Load(long notebookId)
    {
        await ViewModel.LoadAsync(notebookId);
        SyncScopeSegment();
        RenderContent();
    }

    private void OnVmChanged(object? s, System.ComponentModel.PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(TransformationsViewModel.Scope): SyncScopeSegment(); break;
            case nameof(TransformationsViewModel.ErrorMessage):
                ErrorText.Text = ViewModel.ErrorMessage ?? ""; break;
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

    // Build the four content states (running / single-saved / batch-toast / empty explainer).
    private void RenderContent()
    {
        ContentHost.Children.Clear();
        if (ViewModel.Running) ContentHost.Children.Add(BuildRunning());
        else if (ViewModel.BatchSavedCount is > 1) ContentHost.Children.Add(BuildBatchToast());
        else if (ViewModel.ResultNoteId is not null) ContentHost.Children.Add(BuildSingleSaved());
        else ContentHost.Children.Add(BuildEmpty());
    }

    private UIElement BuildRunning()
    {
        var panel = new StackPanel { Spacing = 10 };
        if (ViewModel.BatchTotal > 0)
            panel.Children.Add(new ProgressBar { Minimum = 0, Maximum = ViewModel.BatchTotal, Value = ViewModel.BatchCompleted });
        else
            panel.Children.Add(new ProgressRing { IsActive = true });
        panel.Children.Add(new TextBlock { Text = ViewModel.BatchTotal > 0 ? ViewModel.RunningFormat() : _t.Get("transformationRunningStatus") });
        if (!string.IsNullOrEmpty(ViewModel.ResultBody))
            panel.Children.Add(new ScrollViewer { Content = new TextBlock { Text = ViewModel.ResultBody, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true } });
        return panel;
    }

    private UIElement BuildSingleSaved()
    {
        var panel = new StackPanel { Spacing = 10 };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(new FontIcon { Glyph = "", Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Green) });
        row.Children.Add(new TextBlock { Text = ViewModel.ResultSavedTitle(), VerticalAlignment = VerticalAlignment.Center });
        var open = new Button { Content = _t.Get("aiToolsOpenNoteButton"), Style = (Style)Resources["AccentButtonStyle"], Command = ViewModel.OpenResultNoteCommand };
        row.Children.Add(open);
        panel.Children.Add(row);
        panel.Children.Add(new TextBlock { Text = _t.Get("transformationResultTitle"), Style = (Style)Resources["BodyStrongTextBlockStyle"] });
        panel.Children.Add(new ScrollViewer { Content = new TextBlock { Text = ViewModel.ResultBody, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true } });
        return panel;
    }

    private UIElement BuildBatchToast()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(new FontIcon { Glyph = "", Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Green) });
        row.Children.Add(new TextBlock { Text = ViewModel.BatchSavedFormat(), Style = (Style)Resources["BodyStrongTextBlockStyle"], VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(new Button { Content = _t.Get("aiToolsOpenNoteButton"), Style = (Style)Resources["AccentButtonStyle"], Command = ViewModel.OpenResultNoteCommand });
        return row;
    }

    private UIElement BuildEmpty()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        row.Children.Add(new FontIcon { Glyph = "", FontSize = 28 });
        var col = new StackPanel { Spacing = 6 };
        col.Children.Add(new TextBlock { Text = _t.Get("aiToolsEmptyTitle"), Style = (Style)Resources["BodyStrongTextBlockStyle"] });
        col.Children.Add(new TextBlock { Text = _t.Get("aiToolsEmptyBody"), Foreground = (Microsoft.UI.Xaml.Media.Brush)Resources["TextFillColorSecondaryBrush"], TextWrapping = TextWrapping.Wrap });
        row.Children.Add(col);
        return row;
    }

    private async void OnHistory(object s, RoutedEventArgs e)
    {
        var dlg = new TransformationHistoryDialog(ViewModel.NotebookIdForHistory) { XamlRoot = XamlRoot };
        await dlg.ShowAsync();
    }
    private async void OnEdit(object s, RoutedEventArgs e)
    {
        var dlg = new TransformationEditorDialog() { XamlRoot = XamlRoot };
        await dlg.ShowAsync();
        await ViewModel.ReloadAsync();   // mirror sheet onDismiss reload
        RenderContent();
    }
    private async void OnPreview(object s, RoutedEventArgs e)
    {
        if (ViewModel.SelectedTransformation is not { } tx) return;
        var src = ViewModel.Scope == BatchScope.Source ? ViewModel.SelectedSource : null;
        var dlg = new TransformationPromptPreviewDialog(tx, src) { XamlRoot = XamlRoot };
        await dlg.ShowAsync();
    }
}

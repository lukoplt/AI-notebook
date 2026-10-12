using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Settings;

/// <summary>Settings › Tools: create, edit and delete custom transformation templates.</summary>
public sealed partial class TransformationEditorView : UserControl
{
    public TransformationEditorViewModel ViewModel { get; }

    public TransformationEditorView()
    {
        ViewModel = App.Current.Services.GetRequiredService<TransformationEditorViewModel>();
        var t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();

        NewButton.Content = t.Get("transformationEditorNew");
        NameBox.PlaceholderText = t.Get("transformationEditorNamePlaceholder");
        DescriptionBox.PlaceholderText = t.Get("aiToolsDescriptionPlaceholder");
        TemplateBox.PlaceholderText = t.Get("transformationEditorTemplatePlaceholder");
        SaveButton.Content = t.Get("save");
        DeleteButton.Content = t.Get("deleteButton");
        ScopeSource.Content = t.Get(StringKey.ToolScopeSource);
        ScopeNotebook.Content = t.Get(StringKey.ScopeWholeNotebook);
        ScopeSeg.Header = t.Get(StringKey.ToolScope);

        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(TransformationEditorViewModel.DraftScope) or nameof(TransformationEditorViewModel.Selected))
                SyncScopeSegment();
        };
        ViewModel.Reload();
        SyncScopeSegment();
    }

    private void SyncScopeSegment() =>
        ScopeSeg.SelectedIndex = ViewModel.DraftScope == TransformationScope.Notebook ? 1 : 0;

    private void OnScopeChanged(object sender, SelectionChangedEventArgs e) =>
        ViewModel.DraftScope = ScopeSeg.SelectedIndex == 1 ? TransformationScope.Notebook : TransformationScope.Source;
}

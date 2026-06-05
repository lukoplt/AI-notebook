using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Dialogs;

public sealed partial class TransformationEditorDialog : ContentDialog
{
    public TransformationEditorViewModel ViewModel { get; }
    private readonly ILocalizedStrings _t;

    public TransformationEditorDialog()
    {
        ViewModel = App.Current.Services.GetRequiredService<TransformationEditorViewModel>();
        _t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();

        Title = _t.Get("transformationEditorTitle");
        CloseButtonText = _t.Get("cancelButton");
        NewButton.Content = _t.Get("transformationEditorNew");
        NameBox.PlaceholderText = _t.Get("transformationEditorNamePlaceholder");
        DescriptionBox.PlaceholderText = _t.Get("aiToolsDescriptionPlaceholder");
        TemplateBox.PlaceholderText = _t.Get("transformationEditorTemplatePlaceholder");
        SaveButton.Content = _t.Get("save");
        DeleteButton.Content = _t.Get("deleteButton");

        ViewModel.PropertyChanged += OnVmChanged;
        ViewModel.Reload();
        SyncScopeSegment();
    }

    private void OnVmChanged(object? s, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(TransformationEditorViewModel.DraftScope)
            || e.PropertyName == nameof(TransformationEditorViewModel.Selected))
        {
            SyncScopeSegment();
        }
    }

    private void SyncScopeSegment()
    {
        ScopeSeg.SelectedIndex = ViewModel.DraftScope == TransformationScope.Notebook ? 1 : 0;
    }

    private void OnScopeChanged(object sender, SelectionChangedEventArgs e)
    {
        ViewModel.DraftScope = ScopeSeg.SelectedIndex == 1
            ? TransformationScope.Notebook
            : TransformationScope.Source;
    }
}

using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

public sealed partial class SourceListPage : UserControl
{
    public SourcesViewModel ViewModel { get; }

    private readonly IngestionService _ingestion;
    private readonly LocalizedStrings _strings;

    public SourceListPage(Notebook notebook)
    {
        this.InitializeComponent();
        var sp = App.Current.Services;
        _ingestion = sp.GetRequiredService<IngestionService>();
        _strings = sp.GetRequiredService<LocalizedStrings>();
        var store = sp.GetRequiredService<NotebookStore>();
        ViewModel = new SourcesViewModel(
            store, _strings,
            sp.GetRequiredService<ProviderRouter>(),
            sp.GetRequiredService<ISettingsService>())
        { NotebookId = notebook.Id!.Value };

        HeaderTitle.Text = _strings.Get(StringKey.SourcesSectionTitle);
        AddButton.Content = _strings.Get(StringKey.AddSourceButton);
        EmptyText.Text = _strings.Get(StringKey.NoSourcesEmptyState);
        EmptyAddButton.Content = _strings.Get(StringKey.AddSourceButton);

        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(SourcesViewModel.IsEmpty)) ApplyEmptyState();
        };
        Loaded += async (_, _) => { await ViewModel.LoadAsync(); ApplyEmptyState(); };
    }

    private void ApplyEmptyState()
        => SourceList.Visibility = ViewModel.IsEmpty ? Visibility.Collapsed : Visibility.Visible;

    private async void OnAdd(object sender, RoutedEventArgs e)
    {
        var dialog = new AddSourceDialog(_ingestion, ViewModel.NotebookId, _strings)
        {
            XamlRoot = this.XamlRoot
        };
        await dialog.ShowAsync();
        // Always reload on dismiss (mirrors .sheet onDismiss: reload).
        await ViewModel.LoadAsync();
        ApplyEmptyState();
    }

    private async void OnDeleteRow(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: long id })
            await ViewModel.DeleteAsync(id);
    }

    private async void OnSummarizeRow(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: SourceItem item })
            await ViewModel.SummarizeAsync(item);
    }
}

using System.ComponentModel;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Ollama;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

public sealed partial class ModelManagementDialog : ContentDialog
{
    public ModelManagementViewModel ViewModel { get; }
    private readonly LocalizedStrings _strings;

    public ModelManagementDialog(LocalizedStrings strings)
    {
        _strings = strings;
        this.InitializeComponent();
        var sp = App.Current.Services;
        ViewModel = new ModelManagementViewModel(sp.GetRequiredService<OllamaClient>());

        TitleText.Text = strings.Get(StringKey.ManageModelsTitle);
        PullBox.PlaceholderText = strings.Get(StringKey.ManageModelsPullPlaceholder);
        PullButton.Content = strings.Get(StringKey.ManageModelsPullButton);
        RefreshButton.Content = strings.Get(StringKey.ManageModelsRefreshButton);
        CloseButtonText = strings.Get(StringKey.CancelButton);

        ViewModel.PropertyChanged += OnVmChanged;
        Opened += async (_, _) => await ViewModel.ReloadAsync();
        ApplyState();
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e) => ApplyState();

    private void ApplyState()
    {
        var pulling = ViewModel.Working && !string.IsNullOrEmpty(ViewModel.PullProgress);
        PullBar.Visibility = pulling ? Visibility.Visible : Visibility.Collapsed;
        PullProgressText.Text = ViewModel.PullProgress;
        PullButton.IsEnabled = !ViewModel.Working
            && !string.IsNullOrWhiteSpace(ViewModel.PullName);
        RefreshButton.IsEnabled = !ViewModel.Working;
        if (string.IsNullOrEmpty(ViewModel.ErrorMessage))
        {
            ErrorBar.IsOpen = false;
        }
        else
        {
            ErrorBar.Message = ViewModel.ErrorMessage;
            ErrorBar.IsOpen = true;
        }
    }

    private async void OnPull(object sender, RoutedEventArgs e) => await ViewModel.PullAsync();
    private async void OnRefresh(object sender, RoutedEventArgs e) => await ViewModel.ReloadAsync();

    private async void OnDeleteRow(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string name }) return;
        var confirm = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = _strings.Get(StringKey.ManageModelsDeleteTitle),
            Content = _strings.Get(StringKey.ManageModelsDeleteConfirm),
            PrimaryButtonText = _strings.Get(StringKey.Delete),
            CloseButtonText = _strings.Get(StringKey.Cancel),
            DefaultButton = ContentDialogButton.Close
        };
        if (await confirm.ShowAsync() == ContentDialogResult.Primary)
            await ViewModel.DeleteAsync(name);
    }

    private void OnClose(ContentDialog sender, ContentDialogButtonClickEventArgs args) { }
}

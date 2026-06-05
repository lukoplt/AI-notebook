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

    public ModelManagementDialog(LocalizedStrings strings)
    {
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
        if (sender is Button { Tag: string name }) await ViewModel.DeleteAsync(name);
    }

    private void OnClose(ContentDialog sender, ContentDialogButtonClickEventArgs args) { }
}

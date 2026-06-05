using System.ComponentModel;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml;

namespace AINotebook.App.Views;

public sealed partial class SettingsDialog : ContentDialog
{
    public SettingsViewModel ViewModel { get; }
    private readonly LocalizedStrings _strings;
    private bool _suppress;

    public SettingsDialog(LocalizedStrings strings)
    {
        this.InitializeComponent();
        _strings = strings;
        var sp = App.Current.Services;
        ViewModel = new SettingsViewModel(
            sp.GetRequiredService<ISettingsService>(),
            sp.GetRequiredService<NotebookStore>(),
            sp.GetRequiredService<OllamaClient>(),
            sp.GetRequiredService<EmbeddingWorker>());

        CloseButtonText = "Done";
        ApplyLocalizedText();

        // Language combo: the two AppLanguage display names.
        LanguageCombo.ItemsSource = ViewModel.Languages.Select(l => l.DisplayName()).ToList();
        LanguageCombo.SelectedIndex = ViewModel.Language == AppLanguage.Czech ? 1 : 0;

        VersionValue.Text = ViewModel.Version;
        CurrentModelValue.Text = ViewModel.SelectedEmbeddingModel;

        ViewModel.PropertyChanged += OnVmChanged;
        Opened += async (_, _) => await LoadModelsAsync();
    }

    private void ApplyLocalizedText()
    {
        Title = _strings.Get(StringKey.Settings);
        TitleText.Text = _strings.Get(StringKey.Settings);
        ChatModelCombo.Header = _strings.Get(StringKey.ChatModelPickerLabel);
        EmbedModelCombo.Header = _strings.Get(StringKey.EmbeddingModelPickerLabel);
        ModelsUnavailableText.Text = "Models unavailable — start Ollama or refresh in Manage models.";
        ManageModelsButton.Content = _strings.Get(StringKey.ManageModelsButton);
        EmbeddingSectionTitle.Text = _strings.Get(StringKey.EmbeddingSectionTitle);
        CurrentModelLabel.Text = _strings.Get(StringKey.CurrentModelLabel);
        ReembedButton.Content = _strings.Get(StringKey.ReembedButton);
        VersionLabel.Text = _strings.Get(StringKey.Version);
    }

    private async Task LoadModelsAsync()
    {
        await ViewModel.RefreshModelsAsync();
        PopulateModelCombos();
    }

    private void PopulateModelCombos()
    {
        _suppress = true;

        // Keep the current selection selectable even if Ollama doesn't list it.
        var chatItems = ViewModel.AvailableModels.ToList();
        if (!chatItems.Contains(ViewModel.SelectedChatModel)) chatItems.Add(ViewModel.SelectedChatModel);
        var embedItems = ViewModel.AvailableModels.ToList();
        if (!embedItems.Contains(ViewModel.SelectedEmbeddingModel)) embedItems.Add(ViewModel.SelectedEmbeddingModel);

        var any = ViewModel.AvailableModels.Count > 0;
        ChatModelCombo.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        EmbedModelCombo.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        ModelsUnavailableText.Visibility = any ? Visibility.Collapsed : Visibility.Visible;

        ChatModelCombo.ItemsSource = chatItems;
        EmbedModelCombo.ItemsSource = embedItems;
        ChatModelCombo.SelectedItem = ViewModel.SelectedChatModel;
        EmbedModelCombo.SelectedItem = ViewModel.SelectedEmbeddingModel;

        _suppress = false;
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SettingsViewModel.SelectedEmbeddingModel))
            CurrentModelValue.Text = ViewModel.SelectedEmbeddingModel;
        if (e.PropertyName == nameof(SettingsViewModel.SettingsError))
        {
            if (string.IsNullOrEmpty(ViewModel.SettingsError)) ErrorBar.IsOpen = false;
            else { ErrorBar.Message = ViewModel.SettingsError; ErrorBar.IsOpen = true; }
        }
    }

    private void OnLanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppress) return;
        ViewModel.Language = LanguageCombo.SelectedIndex == 1 ? AppLanguage.Czech : AppLanguage.English;
        // Re-localize this dialog live.
        ApplyLocalizedText();
    }

    private void OnChatModelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppress) return;
        if (ChatModelCombo.SelectedItem is string s) ViewModel.SelectedChatModel = s;
    }

    private void OnEmbedModelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppress) return;
        if (EmbedModelCombo.SelectedItem is string s) ViewModel.SelectedEmbeddingModel = s;
    }

    private async void OnManageModels(object sender, RoutedEventArgs e)
    {
        var dialog = new ModelManagementDialog(_strings) { XamlRoot = this.XamlRoot };
        // ContentDialogs are one-per-thread; hide this one while the child is open.
        this.Hide();
        await dialog.ShowAsync();
        await this.ShowAsync();        // re-open settings
        await LoadModelsAsync();       // refresh on return (mirrors .sheet onDismiss)
    }

    private async void OnReembed(object sender, RoutedEventArgs e)
    {
        var confirm = new ContentDialog
        {
            XamlRoot = this.XamlRoot,
            Title = _strings.Get(StringKey.ReembedConfirm),
            PrimaryButtonText = _strings.Get(StringKey.ReembedConfirmYes),
            CloseButtonText = _strings.Get(StringKey.CancelButton),
            DefaultButton = ContentDialogButton.Close
        };
        this.Hide();
        var result = await confirm.ShowAsync();
        if (result == ContentDialogResult.Primary)
            await ViewModel.ReembedAllAsync();
        await this.ShowAsync();
    }
}

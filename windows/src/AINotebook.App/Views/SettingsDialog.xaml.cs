using System.ComponentModel;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

public sealed partial class SettingsDialog : ContentDialog
{
    public SettingsViewModel ViewModel { get; }
    private readonly LocalizedStrings _strings;
    private readonly NotebookStore _store;
    private bool _suppress;

    public SettingsDialog(LocalizedStrings strings)
    {
        this.InitializeComponent();
        _strings = strings;
        var sp = App.Current.Services;
        _store = sp.GetRequiredService<NotebookStore>();
        ViewModel = new SettingsViewModel(
            sp.GetRequiredService<ISettingsService>(),
            _store,
            sp.GetRequiredService<ProviderRouter>(),
            sp.GetRequiredService<EmbeddingWorker>());

        CloseButtonText = "Done";
        ApplyLocalizedText();

        LanguageCombo.ItemsSource = ViewModel.Languages.Select(l => l.DisplayName()).ToList();
        LanguageCombo.SelectedIndex = ViewModel.Language == AppLanguage.Czech ? 1 : 0;

        VersionValue.Text = ViewModel.Version;
        CurrentModelValue.Text = ViewModel.SelectedEmbeddingModel;

        ViewModel.PropertyChanged += OnVmChanged;
        Opened += async (_, _) => await LoadAllAsync();
    }

    private void ApplyLocalizedText()
    {
        Title = _strings.Get(StringKey.Settings);
        TitleText.Text = _strings.Get(StringKey.Settings);
        ProvidersSectionTitleText.Text = _strings.Get(StringKey.ProvidersSectionTitle);
        AddProviderButton.Content = _strings.Get(StringKey.AddProviderButton);
        ChatProviderCombo.Header = _strings.Get(StringKey.ChatProviderPickerLabel);
        EmbedProviderCombo.Header = _strings.Get(StringKey.EmbeddingProviderPickerLabel);
        ChatModelCombo.Header = _strings.Get(StringKey.ChatModelPickerLabel);
        EmbedModelCombo.Header = _strings.Get(StringKey.EmbeddingModelPickerLabel);
        ModelsUnavailableText.Text = "Models unavailable — start Ollama or refresh in Manage models.";
        ManageModelsButton.Content = _strings.Get(StringKey.ManageModelsButton);
        EmbeddingSectionTitle.Text = _strings.Get(StringKey.EmbeddingSectionTitle);
        CurrentModelLabel.Text = _strings.Get(StringKey.CurrentModelLabel);
        ReembedButton.Content = _strings.Get(StringKey.ReembedButton);
        VersionLabel.Text = _strings.Get(StringKey.Version);
    }

    private async Task LoadAllAsync()
    {
        await ViewModel.RefreshAllAsync();
        PopulateProviderCombos();
        PopulateModelCombos();
        ProvidersList.ItemsSource = ViewModel.Providers;
    }

    private void PopulateProviderCombos()
    {
        _suppress = true;
        var names = ViewModel.Providers.Select(p => p.Name).ToList();

        ChatProviderCombo.ItemsSource = names;
        var chatIdx = ViewModel.Providers.ToList().FindIndex(p => p.Id == ViewModel.SelectedChatProviderId);
        ChatProviderCombo.SelectedIndex = chatIdx >= 0 ? chatIdx : 0;

        EmbedProviderCombo.ItemsSource = new List<string>(names); // separate list
        var embedIdx = ViewModel.Providers.ToList().FindIndex(p => p.Id == ViewModel.SelectedEmbeddingProviderId);
        EmbedProviderCombo.SelectedIndex = embedIdx >= 0 ? embedIdx : 0;
        _suppress = false;
    }

    private void PopulateModelCombos()
    {
        _suppress = true;

        var any = ViewModel.ChatModelsAvailable;
        ChatModelCombo.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        ChatModelCombo.ItemsSource = ViewModel.AvailableChatModels.ToList();
        ChatModelCombo.SelectedItem = ViewModel.SelectedChatModel;

        var embedAny = ViewModel.EmbeddingModelsAvailable;
        EmbedModelCombo.Visibility = embedAny ? Visibility.Visible : Visibility.Collapsed;
        EmbedModelCombo.ItemsSource = ViewModel.AvailableEmbeddingModels.ToList();
        EmbedModelCombo.SelectedItem = ViewModel.SelectedEmbeddingModel;

        ModelsUnavailableText.Visibility = (!any && !embedAny) ? Visibility.Visible : Visibility.Collapsed;

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
        ApplyLocalizedText();
    }

    private async void OnChatProviderChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppress) return;
        var idx = ChatProviderCombo.SelectedIndex;
        if (idx < 0 || idx >= ViewModel.Providers.Count) return;
        var oldId = ViewModel.SelectedChatProviderId;
        var target = ViewModel.Providers[idx];
        if (target.Id == oldId) return;

        // FR-A8 re-gate on picker selection: a cloud/network provider that
        // was never acknowledged (added, declined, but left enabled in the
        // registry) must re-show the privacy gate here — the router enforces
        // this defense-in-depth on every call regardless, but silently
        // falling back or surfacing a raw consent-required chat error would
        // be a confusing dead end for a picker that looked like it "worked".
        if (target.IsCloud && !target.PrivacyAcknowledged)
        {
            var oldIdx = ViewModel.Providers.ToList().FindIndex(p => p.Id == oldId);
            // WinUI allows only one ContentDialog open at a time, and this
            // dialog IS one — hide it while the gate is shown, then re-show
            // (mirrors AddProviderDialog.OnClosing / OnAddProvider et al.).
            this.Hide();
            var gate = new PrivacyGateDialog(_strings) { XamlRoot = this.XamlRoot };
            var gateResult = await gate.ShowAsync();
            await this.ShowAsync();

            if (gateResult != ContentDialogResult.Primary)
            {
                // Declined — revert the combo to the previous selection
                // under _suppress so this handler doesn't re-enter.
                _suppress = true;
                ChatProviderCombo.SelectedIndex = oldIdx >= 0 ? oldIdx : 0;
                _suppress = false;
                return;
            }

            _store.AcknowledgePrivacy(target.Id);
            await ViewModel.RefreshProvidersAsync();
        }

        ViewModel.SelectedChatProviderId = target.Id;
        await ViewModel.RefreshChatModelsAsync();
        PopulateModelCombos();
    }

    private async void OnEmbedProviderChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppress) return;
        var idx = EmbedProviderCombo.SelectedIndex;
        if (idx < 0 || idx >= ViewModel.Providers.Count) return;
        var oldId = ViewModel.SelectedEmbeddingProviderId;
        var target = ViewModel.Providers[idx];
        if (target.Id == oldId) return;

        // FR-A8 re-gate on picker selection — same rationale as the chat
        // picker above.
        if (target.IsCloud && !target.PrivacyAcknowledged)
        {
            var oldIdx = ViewModel.Providers.ToList().FindIndex(p => p.Id == oldId);
            this.Hide();
            var gate = new PrivacyGateDialog(_strings) { XamlRoot = this.XamlRoot };
            var gateResult = await gate.ShowAsync();
            await this.ShowAsync();

            if (gateResult != ContentDialogResult.Primary)
            {
                _suppress = true;
                EmbedProviderCombo.SelectedIndex = oldIdx >= 0 ? oldIdx : 0;
                _suppress = false;
                return;
            }

            _store.AcknowledgePrivacy(target.Id);
            await ViewModel.RefreshProvidersAsync();
        }

        ViewModel.SelectedEmbeddingProviderId = target.Id;
        await ViewModel.RefreshEmbeddingModelsAsync();
        PopulateModelCombos();
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
        this.Hide();
        await dialog.ShowAsync();
        await this.ShowAsync();
        await LoadAllAsync();
    }

    private async void OnAddProvider(object sender, RoutedEventArgs e)
    {
        var dialog = new AddProviderDialog(_strings) { XamlRoot = this.XamlRoot };
        this.Hide();
        await dialog.ShowAsync();
        await this.ShowAsync();
        await LoadAllAsync();
    }

    private async void OnEditProvider(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ProviderConfig cfg })
        {
            var dialog = new AddProviderDialog(_strings, cfg) { XamlRoot = this.XamlRoot };
            this.Hide();
            await dialog.ShowAsync();
            await this.ShowAsync();
            await LoadAllAsync();
        }
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

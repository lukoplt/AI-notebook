using System.ComponentModel;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

/// <summary>
/// Add or edit an AI provider. Pass <paramref name="existing"/> to enter edit mode.
/// </summary>
public sealed partial class AddProviderDialog : ContentDialog
{
    public AddProviderViewModel ViewModel { get; }
    private readonly LocalizedStrings _strings;
    private bool _initializing = true;
    private bool _syncingFields;

    public AddProviderDialog(LocalizedStrings strings, ProviderConfig? existing = null)
    {
        this.InitializeComponent();
        _strings = strings;

        var sp = App.Current.Services;
        ViewModel = new AddProviderViewModel(
            sp.GetRequiredService<ProviderRouter>(),
            sp.GetRequiredService<NotebookStore>(),
            sp.GetRequiredService<ISecretStore>(),
            existing, _ => _strings.Get(StringKey.ProviderPresetCustom),
            sp.GetRequiredService<ISettingsService>());

        var isEdit = existing is not null;
        Title = _strings.Get(isEdit ? StringKey.EditProviderTitle : StringKey.AddProviderTitle);
        PrimaryButtonText = _strings.Get(StringKey.Save);
        CloseButtonText = _strings.Get(StringKey.CancelButton);
        DefaultButton = ContentDialogButton.Primary;

        // Type picker — Ollama can't be changed when editing
        TypeCombo.Header = _strings.Get(StringKey.ProviderTypeLabel);
        TypeCombo.ItemsSource = ViewModel.SelectableTypes.Select(TypeDisplayName).ToList();
        TypeCombo.SelectedIndex = Array.IndexOf(ViewModel.SelectableTypes, ViewModel.SelectedType);
        TypeCombo.IsEnabled = !ViewModel.IsOllamaProvider;

        NameBox.Header = _strings.Get(StringKey.ProviderNameLabel);
        NameBox.Text = ViewModel.Name;

        UrlBox.Header = _strings.Get(StringKey.ProviderUrlLabel);
        UrlBox.Text = ViewModel.BaseUrl;

        KeyBox.Header = _strings.Get(StringKey.ProviderApiKeyLabel);
        KeyBox.PlaceholderText = isEdit && !ViewModel.IsOllamaProvider
            ? "key saved — paste to replace"
            : _strings.Get(StringKey.ProviderApiKeyPlaceholder);

        TestButton.Content = _strings.Get(StringKey.ProviderTestButton);
        PresetComboBox.Header = _strings.Get(StringKey.ProviderPresetLabel);

        if (isEdit && !ViewModel.IsOllamaProvider)
        {
            DeleteButton.Content = _strings.Get(StringKey.ProviderDeleteTitle);
            DeleteButton.Visibility = Visibility.Visible;
        }

        ApplyTypeVisibility(ViewModel.SelectedType);
        UpdatePrimaryButton();
        UpdatePresetHelp();
        ViewModel.PropertyChanged += OnViewModelChanged;
        _initializing = false;

        Closing += OnClosing;
    }

    private static string TypeDisplayName(ProviderType t) => t switch
    {
        ProviderType.Anthropic => "Anthropic (Claude)",
        ProviderType.OpenAI => "OpenAI (ChatGPT)",
        ProviderType.OpenAICompatible => "OpenAI-compatible",
        ProviderType.OpenWebUI => "OpenWebUI (network)",
        _ => "Ollama (local)"
    };

    private void ApplyTypeVisibility(ProviderType t)
    {
        var isCloud = t != ProviderType.Ollama;
        KeyBox.Visibility = isCloud ? Visibility.Visible : Visibility.Collapsed;
        PresetComboBox.Visibility = t == ProviderType.OpenAICompatible ? Visibility.Visible : Visibility.Collapsed;
        PresetHelpText.Visibility = PresetComboBox.Visibility;
    }

    private void UpdatePrimaryButton()
        => IsPrimaryButtonEnabled = ViewModel.CanSave;

    private void OnTypeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_initializing) return;
        var idx = TypeCombo.SelectedIndex;
        if (idx < 0) return;
        var t = ViewModel.SelectableTypes[idx];
        ViewModel.SelectedType = t;
        UrlBox.Text = ViewModel.BaseUrl;
        ApplyTypeVisibility(t);
        UpdatePrimaryButton();
    }

    private void OnFieldChanged(object sender, object e)
    {
        if (_initializing || _syncingFields) return;
        ViewModel.Name = NameBox.Text;
        ViewModel.BaseUrl = UrlBox.Text;
        ViewModel.ApiKey = KeyBox.Password;
        UpdatePrimaryButton();
    }

    private async void OnTest(object sender, RoutedEventArgs e)
    {
        // Sync to VM before testing
        ViewModel.ApiKey = KeyBox.Password;
        ViewModel.BaseUrl = UrlBox.Text;
        await ViewModel.TestAsync();
        UpdateProbeState();
    }

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AddProviderViewModel.BaseUrl))
        {
            _syncingFields = true;
            UrlBox.Text = ViewModel.BaseUrl;
            _syncingFields = false;
        }
        if (e.PropertyName is nameof(AddProviderViewModel.PresetHelp) or nameof(AddProviderViewModel.SelectedPresetId))
            UpdatePresetHelp();
        if (e.PropertyName is nameof(AddProviderViewModel.ProbeResult) or nameof(AddProviderViewModel.IsTesting))
            UpdateProbeState();
        UpdatePrimaryButton();
    }

    private void UpdatePresetHelp() => PresetHelpText.Text = _strings.Get(ViewModel.PresetHelp switch
    {
        "providerPresetLocalHelp" => StringKey.ProviderPresetLocalHelp,
        "providerPresetRemoteHelp" => StringKey.ProviderPresetRemoteHelp,
        _ => StringKey.ProviderPresetCustomHelp
    });

    private void UpdateProbeState()
    {
        TestSpinner.IsActive = ViewModel.IsTesting;
        TestButton.IsEnabled = !ViewModel.IsTesting;
        TestStatusText.Text = "";
        var result = ViewModel.ProbeResult;
        TestSuccessBar.IsOpen = result is not null;
        if (result is null) return;
        switch (result.Status)
        {
            case ProviderProbeStatus.Verified:
                TestSuccessBar.Severity = InfoBarSeverity.Success;
                TestSuccessBar.Message = _strings.Get(StringKey.ProviderListingVerified);
                break;
            case ProviderProbeStatus.ListingUnsupported:
                TestSuccessBar.Severity = InfoBarSeverity.Informational;
                TestSuccessBar.Message = _strings.Get(StringKey.ProviderListingUnsupported);
                break;
            default:
                TestSuccessBar.Severity = InfoBarSeverity.Error;
                TestSuccessBar.Message = ProviderErrorText.Format(
                    result.ErrorCode == "http" ? result.Detail ?? "requestFailed" : result.ErrorCode ?? "requestFailed",
                    _strings.Get);
                break;
        }
    }

    private async void OnDelete(object sender, RoutedEventArgs e)
    {
        var confirm = new ContentDialog
        {
            XamlRoot = this.XamlRoot,
            Title = _strings.Get(StringKey.ProviderDeleteTitle),
            Content = _strings.Get(StringKey.ProviderDeleteConfirm),
            PrimaryButtonText = _strings.Get(StringKey.DeleteButton),
            CloseButtonText = _strings.Get(StringKey.CancelButton),
            DefaultButton = ContentDialogButton.Close
        };
        this.Hide();
        var result = await confirm.ShowAsync();
        if (result == ContentDialogResult.Primary)
        {
            await ViewModel.DeleteAsync();
            // Signal deletion to caller via tag
            Tag = "deleted";
            // Don't reopen — close is final
            return;
        }
        await this.ShowAsync();
    }

    private async void OnClosing(ContentDialog sender, ContentDialogClosingEventArgs args)
    {
        if (args.Result != ContentDialogResult.Primary) return;

        // Sync VM fields from UI controls
        ViewModel.Name = NameBox.Text.Trim();
        ViewModel.BaseUrl = UrlBox.Text;
        ViewModel.ApiKey = KeyBox.Password;
        if (!ViewModel.CanSave)
        {
            args.Cancel = true;
            return;
        }

        // Privacy gate (FR-A8): fires for a NEW cloud/network provider AND for
        // an edit that changes an existing provider's type to a (possibly
        // different) cloud/network type — the stored consent belonged to the
        // previous type and must not silently carry over. Mirrors
        // Sources/AINotebookApp/AddProviderSheet.swift saveTapped()'s
        // `typeChanged = existing.map { $0.type != type } ?? true`.
        var typeChanged = ViewModel.EditingId is null || ViewModel.SelectedType != ViewModel.OriginalType;
        if (ViewModel.SelectedType != ProviderType.Ollama && typeChanged)
        {
            args.Cancel = true; // keep dialog open while gate is shown
            this.Hide();        // hide this dialog so gate can appear
            var gate = new PrivacyGateDialog(_strings) { XamlRoot = this.XamlRoot };
            var gateResult = await gate.ShowAsync();
            if (gateResult == ContentDialogResult.Primary)
                Tag = await ViewModel.SaveConfirmedAsync(acknowledgePrivacy: true);
            // If gate was cancelled, Tag stays null — caller reloads and nothing changed.
            return; // this.Hide() already closed us; don't proceed further
        }

        Tag = await ViewModel.SaveConfirmedAsync(acknowledgePrivacy: false);
    }
}

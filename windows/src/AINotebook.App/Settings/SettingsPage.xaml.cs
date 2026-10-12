using System.ComponentModel;
using AINotebook.App.Services;
using AINotebook.App.Shell;
using AINotebook.App.ViewModels;
using AINotebook.App.Views;
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Settings;

/// <summary>One entry of the settings section list.</summary>
public sealed class SettingsSectionItem
{
    public SettingsSectionItem() : this(SettingsSection.General, "", "") { }
    public SettingsSectionItem(SettingsSection section, string title, string glyph)
    {
        Section = section;
        Title = title;
        Glyph = glyph;
    }

    public SettingsSection Section { get; }
    public string Title { get; }
    public string Glyph { get; }
}

/// <summary>
/// Settings page (spec §2.5): replaces SettingsDialog with the same SettingsViewModel, split into
/// sections. Nested dialogs (privacy gate, provider editor, model manager, re-embed confirm) now
/// open over the page instead of hiding and re-showing a dialog.
/// </summary>
public sealed partial class SettingsPage : Page
{
    public SettingsViewModel ViewModel { get; }
    private readonly LocalizedStrings _strings;
    private readonly NotebookStore _store;
    private readonly NavigationState _nav;
    private bool _suppress;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _indexTimer;

    public SettingsPage(NavigationState nav, SettingsSection section)
    {
        InitializeComponent();
        _nav = nav;
        var sp = App.Current.Services;
        _strings = sp.GetRequiredService<LocalizedStrings>();
        _store = sp.GetRequiredService<NotebookStore>();
        ViewModel = new SettingsViewModel(
            sp.GetRequiredService<ISettingsService>(),
            _store,
            sp.GetRequiredService<ProviderRouter>(),
            sp.GetRequiredService<EmbeddingWorker>(),
            sp.GetRequiredService<UpdateChecker>(),
            sp.GetRequiredService<UpdateState>(),
            sp.GetRequiredService<AINotebook.Core.Ingestion.FolderIngestionRuntime>(),
            _strings.Get);
        DataContext = ViewModel;

        _suppress = true;
        LanguageCombo.ItemsSource = ViewModel.Languages.Select(l => l.DisplayName()).ToList();
        LanguageCombo.SelectedIndex = ViewModel.Language == AppLanguage.Czech ? 1 : 0;
        WebSearchToggle.IsOn = sp.GetRequiredService<ISettingsService>().WebSearchEnabled;
        AutoUpdateToggle.IsOn = ViewModel.AutoCheckUpdates;
        _suppress = false;
        VersionValue.Text = ViewModel.Version;
        CurrentModelValue.Text = ViewModel.SelectedEmbeddingModel;

        ApplyLocalizedText();
        BuildSections(section);

        ViewModel.PropertyChanged += OnVmChanged;
        Loaded += async (_, _) =>
        {
            await LoadAllAsync();
            StartIndexPolling();
        };
        Unloaded += (_, _) => StopIndexPolling();
    }

    /// <summary>Opens another section without rebuilding the page (e.g. "Model settings…" from the composer).</summary>
    public void ShowSection(SettingsSection section)
    {
        var item = SectionList.Items.OfType<SettingsSectionItem>().FirstOrDefault(i => i.Section == section);
        if (item is not null) SectionList.SelectedItem = item;
    }

    private void BuildSections(SettingsSection selected)
    {
        string Glyph(string key) => (string)Application.Current.Resources[key];
        var items = new[]
        {
            new SettingsSectionItem(SettingsSection.General, _strings.Get(StringKey.SettingsGeneral), Glyph("IconSettings")),
            new SettingsSectionItem(SettingsSection.Providers, _strings.Get(StringKey.ProvidersSectionTitle), Glyph("IconProviders")),
            new SettingsSectionItem(SettingsSection.ModelsLimits, _strings.Get(StringKey.SettingsModelsLimits), Glyph("IconModelsLimits")),
            new SettingsSectionItem(SettingsSection.Indexing, _strings.Get(StringKey.SettingsIndexing), Glyph("IconIndexing")),
            new SettingsSectionItem(SettingsSection.Tools, _strings.Get(StringKey.SettingsTools), Glyph("IconRunTool")),
            new SettingsSectionItem(SettingsSection.About, _strings.Get(StringKey.SettingsAbout), Glyph("IconInfo")),
        };
        SectionList.ItemsSource = items;
        SectionList.SelectedItem = items.First(i => i.Section == selected);
    }

    private void OnSectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SectionList.SelectedItem is not SettingsSectionItem item) return;
        SectionTitle.Text = item.Title;
        GeneralSection.Visibility = Show(item.Section == SettingsSection.General);
        ProvidersSection.Visibility = Show(item.Section == SettingsSection.Providers);
        ModelsSection.Visibility = Show(item.Section == SettingsSection.ModelsLimits);
        IndexingSection.Visibility = Show(item.Section == SettingsSection.Indexing);
        ToolsSection.Visibility = Show(item.Section == SettingsSection.Tools);
        AboutSection.Visibility = Show(item.Section == SettingsSection.About);
    }

    private static Visibility Show(bool value) => value ? Visibility.Visible : Visibility.Collapsed;

    private async void OnBack(object sender, RoutedEventArgs e) => await _nav.GoBackAsync();

    private void ApplyLocalizedText()
    {
        BackText.Text = _strings.Get(StringKey.ShellBack);
        LanguageCombo.Header = _strings.Get(StringKey.Language);
        WebSearchToggle.Header = _strings.Get(StringKey.WebSearchToggle);
        AddProviderButton.Content = _strings.Get(StringKey.AddProviderButton);
        ChatProviderCombo.Header = _strings.Get(StringKey.ChatProviderPickerLabel);
        EmbedProviderCombo.Header = _strings.Get(StringKey.EmbeddingProviderPickerLabel);
        ChatModelCombo.Header = _strings.Get(StringKey.ChatModelPickerLabel);
        EmbedModelCombo.Header = _strings.Get(StringKey.EmbeddingModelPickerLabel);
        RefreshChatModelsButton.Content = _strings.Get(StringKey.ProviderRefreshModels);
        RefreshEmbeddingModelsButton.Content = _strings.Get(StringKey.ProviderRefreshModels);
        ChatModelIdTextBox.Header = _strings.Get(StringKey.ProviderManualModelId);
        EmbeddingModelIdTextBox.Header = _strings.Get(StringKey.ProviderManualModelId);
        ApplyChatModelIdButton.Content = _strings.Get(StringKey.ProviderApplyModel);
        ApplyEmbeddingModelIdButton.Content = _strings.Get(StringKey.ProviderApplyModel);
        RuntimeContextTextBox.Header = _strings.Get(StringKey.ProviderRuntimeContext);
        MaxOutputTokensTextBox.Header = _strings.Get(StringKey.ProviderMaxOutputTokens);
        SaveLimitsButton.Content = _strings.Get(StringKey.ProviderLimitsSave);
        ResetLimitsButton.Content = _strings.Get(StringKey.ProviderLimitsReset);
        EmbeddingConversionNotice.Message = _strings.Get(StringKey.ProviderEmbeddingSelectionConverted);
        ManageModelsButton.Content = _strings.Get(StringKey.ManageModelsButton);
        CurrentModelLabel.Text = _strings.Get(StringKey.CurrentModelLabel);
        ReindexButton.Content = _strings.Get(StringKey.ReindexButton);
        ReindexDualSpaceNote.Text = _strings.Get(StringKey.ReindexDualSpaceNote);
        ReindexProgressTitle.Text = _strings.Get(StringKey.ReindexProgress);
        ToolsHint.Text = _strings.Get(StringKey.ToolsPickTemplate);
        VersionLabel.Text = _strings.Get(StringKey.Version);
        LicenseLink.Content = _strings.Get(StringKey.AboutLicense);
        NoticesLink.Content = _strings.Get(StringKey.AboutNotice);
        SourceCodeLink.Content = _strings.Get(StringKey.AboutSourceCode);
        CreditsText.Text = _strings.Get(StringKey.AboutCredits);
        UpdatesHeader.Text = _strings.Get(StringKey.SettingsUpdates);
        LimitsHeader.Text = _strings.Get(StringKey.SettingsLimits);
        AutoUpdateToggle.Header = _strings.Get(StringKey.UpdateAutoCheckToggle);
        CheckUpdatesButton.Content = _strings.Get(StringKey.UpdateCheckNowButton);
        UpdateStatusText.Text = FormatUpdateStatus();
        UpdateProviderState();
    }

    private string FormatUpdateStatus() => ViewModel.CheckStatus switch
    {
        UpdateCheckStatus.Checking => _strings.Get(StringKey.UpdateStatusChecking),
        UpdateCheckStatus.UpToDate => _strings.Get(StringKey.UpdateStatusUpToDate),
        UpdateCheckStatus.Available => string.Format(_strings.Get(StringKey.UpdateStatusAvailable), ViewModel.AvailableVersion),
        UpdateCheckStatus.Failed => _strings.Get(StringKey.UpdateStatusFailed),
        _ => "",
    };

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
        ChatProviderCombo.ItemsSource = ViewModel.Providers.Select(p => p.Name).ToList();
        ChatProviderCombo.SelectedIndex = ViewModel.Providers.ToList().FindIndex(p => p.Id == ViewModel.SelectedChatProviderId);
        EmbedProviderCombo.ItemsSource = ViewModel.EmbeddingProviders.Select(p => p.Name).ToList();
        EmbedProviderCombo.SelectedIndex = ViewModel.EmbeddingProviders.ToList().FindIndex(p => p.Id == ViewModel.SelectedEmbeddingProviderId);
        _suppress = false;
    }

    private void PopulateModelCombos()
    {
        _suppress = true;
        ChatModelCombo.ItemsSource = ViewModel.ChatModels;
        ChatModelCombo.SelectedValue = ViewModel.SelectedChatModel;
        EmbedModelCombo.ItemsSource = ViewModel.EmbeddingModels;
        EmbedModelCombo.SelectedValue = ViewModel.SelectedEmbeddingModel;
        _suppress = false;
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e)
    {
        UpdateProviderState();
        if (e.PropertyName == nameof(SettingsViewModel.SelectedEmbeddingModel))
            CurrentModelValue.Text = ViewModel.SelectedEmbeddingModel;
        if (e.PropertyName == nameof(SettingsViewModel.SettingsError))
        {
            if (string.IsNullOrEmpty(ViewModel.SettingsError)) ErrorBar.IsOpen = false;
            else { ErrorBar.Message = LocalizeProviderError(ViewModel.SettingsError); ErrorBar.IsOpen = true; }
        }
        if (e.PropertyName is nameof(SettingsViewModel.CheckStatus) or nameof(SettingsViewModel.AvailableVersion))
            UpdateStatusText.Text = FormatUpdateStatus();
    }

    // ---------------------------------------------------------------- general

    private void OnLanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppress) return;
        ViewModel.Language = LanguageCombo.SelectedIndex == 1 ? AppLanguage.Czech : AppLanguage.English;
        ApplyLocalizedText();
        var current = (SectionList.SelectedItem as SettingsSectionItem)?.Section ?? SettingsSection.General;
        BuildSections(current);
    }

    private void OnWebSearchToggled(object sender, RoutedEventArgs e)
    {
        if (_suppress) return;
        App.Current.Services.GetRequiredService<ISettingsService>().WebSearchEnabled = WebSearchToggle.IsOn;
    }

    private void OnAutoUpdateToggled(object sender, RoutedEventArgs e)
    {
        if (_suppress) return;
        ViewModel.AutoCheckUpdates = AutoUpdateToggle.IsOn;
    }

    private async void OnCheckUpdates(object sender, RoutedEventArgs e) => await ViewModel.CheckForUpdatesAsync();

    // ---------------------------------------------------------------- providers

    private async void OnAddProvider(object sender, RoutedEventArgs e)
    {
        var dialog = new AddProviderDialog(_strings) { XamlRoot = XamlRoot };
        await dialog.ShowAsync();
        await LoadAllAsync();
    }

    private async void OnEditProvider(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: ProviderConfig cfg }) return;
        var dialog = new AddProviderDialog(_strings, cfg) { XamlRoot = XamlRoot };
        await dialog.ShowAsync();
        await LoadAllAsync();
    }

    private void OnEditProviderLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement element) return;
        var label = _strings.Get(StringKey.EditProviderTitle);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(element, label);
        ToolTipService.SetToolTip(element, label);
    }

    /// <summary>
    /// FR-A8 re-gate on picker selection: a cloud/network provider that was never acknowledged
    /// must show the privacy gate again; declining reverts the picker.
    /// </summary>
    private async Task<bool> PassPrivacyGateAsync(ProviderConfig target)
    {
        if (!target.IsCloud || target.PrivacyAcknowledged) return true;
        var gate = new PrivacyGateDialog(_strings) { XamlRoot = XamlRoot };
        if (await gate.ShowAsync() != ContentDialogResult.Primary) return false;
        _store.AcknowledgePrivacy(target.Id);
        await ViewModel.RefreshProvidersAsync();
        return true;
    }

    // ---------------------------------------------------------------- models & limits

    private async void OnChatProviderChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppress) return;
        var idx = ChatProviderCombo.SelectedIndex;
        if (idx < 0 || idx >= ViewModel.Providers.Count) return;
        var oldId = ViewModel.SelectedChatProviderId;
        var target = ViewModel.Providers[idx];
        if (target.Id == oldId) return;
        if (!await PassPrivacyGateAsync(target))
        {
            _suppress = true;
            ChatProviderCombo.SelectedIndex = ViewModel.Providers.ToList().FindIndex(p => p.Id == oldId);
            _suppress = false;
            return;
        }
        ViewModel.SelectedChatProviderId = target.Id;
        await ViewModel.RefreshChatModelsAsync();
        PopulateProviderCombos();
        PopulateModelCombos();
    }

    private void OnChatModelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppress) return;
        if (ChatModelCombo.SelectedValue is string id) ViewModel.SelectedChatModel = id;
    }

    private async void OnRefreshChatModels(object sender, RoutedEventArgs e)
    {
        await ViewModel.RefreshChatModelsAsync();
        PopulateModelCombos();
    }

    private void OnApplyChatModelId(object sender, RoutedEventArgs e)
    {
        if (ViewModel.ApplyChatModelDraft()) PopulateModelCombos();
    }

    private async void OnManageModels(object sender, RoutedEventArgs e)
    {
        var dialog = new ModelManagementDialog(_strings) { XamlRoot = XamlRoot };
        await dialog.ShowAsync();
        await LoadAllAsync();
    }

    private async void OnSaveLimits(object sender, RoutedEventArgs e) => await ViewModel.SaveLimitsAsync();
    private async void OnResetLimits(object sender, RoutedEventArgs e) => await ViewModel.ResetLimitsAsync();

    // ---------------------------------------------------------------- indexing

    private async void OnEmbedProviderChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppress) return;
        var idx = EmbedProviderCombo.SelectedIndex;
        if (idx < 0 || idx >= ViewModel.EmbeddingProviders.Count) return;
        var oldId = ViewModel.SelectedEmbeddingProviderId;
        var target = ViewModel.EmbeddingProviders[idx];
        if (target.Id == oldId) return;
        if (!await PassPrivacyGateAsync(target))
        {
            _suppress = true;
            EmbedProviderCombo.SelectedIndex = ViewModel.EmbeddingProviders.ToList().FindIndex(p => p.Id == oldId);
            _suppress = false;
            return;
        }
        ViewModel.SelectedEmbeddingProviderId = target.Id;
        await ViewModel.RefreshEmbeddingModelsAsync();
        PopulateProviderCombos();
        PopulateModelCombos();
    }

    private async void OnEmbedModelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppress) return;
        if (EmbedModelCombo.SelectedValue is string id) await ApplyEmbeddingModelAsync(id);
    }

    private async void OnRefreshEmbeddingModels(object sender, RoutedEventArgs e)
    {
        await ViewModel.RefreshEmbeddingModelsAsync();
        PopulateModelCombos();
    }

    private async void OnApplyEmbeddingModelId(object sender, RoutedEventArgs e) =>
        await ApplyEmbeddingModelAsync(ViewModel.EmbeddingModelDraft);

    private async Task ApplyEmbeddingModelAsync(string draft)
    {
        var model = draft.Trim();
        if (model.Length == 0 || model == ViewModel.SelectedEmbeddingModel) return;
        var provider = ViewModel.SelectedEmbeddingProviderId;
        var previousModel = ViewModel.SelectedEmbeddingModel;
        var confirm = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = _strings.Get(StringKey.ReembedConfirm),
            PrimaryButtonText = _strings.Get(StringKey.ReembedConfirmYes),
            CloseButtonText = _strings.Get(StringKey.CancelButton),
            DefaultButton = ContentDialogButton.Close
        };
        var result = await confirm.ShowAsync();
        if (result == ContentDialogResult.Primary && provider == ViewModel.SelectedEmbeddingProviderId && previousModel == ViewModel.SelectedEmbeddingModel)
        {
            ViewModel.EmbeddingModelDraft = model;
            ViewModel.ApplyEmbeddingModelDraft();
            await ViewModel.ReembedAllAsync();
        }
        PopulateModelCombos();
    }

    private void OnEmbeddingConversionNoticeClosed(InfoBar sender, InfoBarClosedEventArgs args) => ViewModel.DismissEmbeddingConversionNotice();

    // WP6: re-index beside the active index — no destructive confirmation; the dual-space note sits next to the action.
    private async void OnReindex(object sender, RoutedEventArgs e) => await ViewModel.ReindexAsync();

    private async void OnRetryIndex(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: long notebookId }) await ViewModel.RetryIndexAsync(notebookId);
    }

    private async void OnDiscardIndex(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: long jobId }) await ViewModel.DiscardIndexAsync(jobId);
    }

    // Presentation polling only while the page is visible (live chat-pause state); ingestion never stops here.
    private void StartIndexPolling()
    {
        _indexTimer ??= Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread().CreateTimer();
        _indexTimer.Interval = TimeSpan.FromSeconds(1);
        _indexTimer.Tick -= OnIndexTick;
        _indexTimer.Tick += OnIndexTick;
        _indexTimer.Start();
        _ = ViewModel.RefreshIndexBuildsAsync();
    }

    private void StopIndexPolling()
    {
        if (_indexTimer is null) return;
        _indexTimer.Stop();
        _indexTimer.Tick -= OnIndexTick;
    }

    private async void OnIndexTick(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args)
    {
        try { await ViewModel.RefreshIndexBuildsAsync(); }
        catch (Exception) { }
    }

    // ---------------------------------------------------------------- shared

    private string LocalizeProviderError(string? error) => ProviderErrorText.Format(error, _strings.Get);

    private void UpdateProviderState()
    {
        if (ViewModel is null) return;
        RefreshChatModelsButton.IsEnabled = !ViewModel.IsLoadingChatModels;
        RefreshEmbeddingModelsButton.IsEnabled = !ViewModel.IsLoadingEmbeddingModels;
        ApplyChatModelIdButton.IsEnabled = !string.IsNullOrWhiteSpace(ViewModel.ChatModelDraft);
        ApplyEmbeddingModelIdButton.IsEnabled = !string.IsNullOrWhiteSpace(ViewModel.EmbeddingModelDraft);
        SetListingBar(ChatListingBar, ViewModel.ChatListingStatus, ViewModel.ChatModelsError);
        SetListingBar(EmbeddingListingBar, ViewModel.EmbeddingListingStatus, ViewModel.EmbeddingModelsError);
        ContextWindowText.Text = _strings.Get(StringKey.ProviderContextWindow) + ": " +
            (ViewModel.Limits?.ContextWindow?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? _strings.Get(StringKey.ProviderContextUnknown));
        LimitsSourceText.Text = ViewModel.Limits?.Source == "user" ? _strings.Get(StringKey.ProviderLimitsUserOverride)
            : ViewModel.Limits?.IsAssumed == true ? _strings.Get(StringKey.ProviderLimitsAssumption) : "";
        LimitsErrorText.Text = LocalizeProviderError(ViewModel.LimitsError);
        LimitsErrorText.Visibility = ViewModel.LimitsError is null ? Visibility.Collapsed : Visibility.Visible;
        SaveLimitsButton.IsEnabled = ViewModel.Limits is not null && !ViewModel.IsLoadingLimits;
        ResetLimitsButton.IsEnabled = !ViewModel.IsLoadingLimits;
        EmbeddingConversionNotice.IsOpen = ViewModel.EmbeddingConversionNotice;
    }

    private void SetListingBar(InfoBar bar, ProviderProbeStatus? status, string? error)
    {
        bar.IsOpen = status is not null;
        bar.Severity = status switch
        {
            ProviderProbeStatus.Verified => InfoBarSeverity.Success,
            ProviderProbeStatus.ListingUnsupported => InfoBarSeverity.Informational,
            _ => InfoBarSeverity.Error
        };
        bar.Message = status switch
        {
            ProviderProbeStatus.Verified => _strings.Get(StringKey.ProviderListingVerified),
            ProviderProbeStatus.ListingUnsupported => _strings.Get(StringKey.ProviderListingUnsupported),
            _ => LocalizeProviderError(error)
        };
    }
}

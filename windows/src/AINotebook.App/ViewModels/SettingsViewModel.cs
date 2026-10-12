using System.Collections.ObjectModel;
using System.Globalization;
using System.Text.Json;
using ProviderModelLimits = AINotebook.Core.Providers.ProviderModelLimits;
using AINotebook.App.Services;
using AINotebook.Core;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AINotebook.App.ViewModels;

/// Raw (non-localized) result of the last "Check for updates now" action.
/// SettingsViewModel has no ILocalizedStrings dependency (unlike some other
/// VMs in this app), so the dialog code-behind — which already holds
/// LocalizedStrings — maps this to display text, mirroring how SettingsError
/// is surfaced today (VM holds raw state, view formats it).
public enum UpdateCheckStatus { Idle, Checking, UpToDate, Available, Failed }

public sealed partial class SettingsViewModel : ObservableObject
{
    private readonly ISettingsService _settings;
    private readonly NotebookStore _store;
    private readonly ProviderRouter _router;
    private readonly EmbeddingWorker _worker;
    private readonly UpdateChecker _checker;
    private readonly UpdateState _updateState;
    private readonly FolderIngestionRuntime? _runtime;
    private readonly Func<StringKey, string> _text;

    /// <summary>One row per notebook with persisted build or bootstrap work (bound by job ID).</summary>
    public ObservableCollection<GenerationProgressRow> IndexBuilds { get; } = new();

    // Models for the currently-selected providers
    public ObservableCollection<ProviderModelInfo> ChatModels { get; } = new();
    public ObservableCollection<ProviderModelInfo> EmbeddingModels { get; } = new();
    public ObservableCollection<ProviderConfig> EmbeddingProviders { get; } = new();
    private int _chatRevision, _embeddingRevision, _limitsRevision, _draftRevision;
    private string _chatModelDraft = "", _embeddingModelDraft = "", _runtimeContextDraft = "", _maxOutputTokensDraft = "";
    private ProviderModelLimits? _limits;
    private string? _limitsError, _chatModelsError, _embeddingModelsError;
    private ProviderProbeStatus? _chatListingStatus, _embeddingListingStatus;
    private bool _isLoadingChatModels, _isLoadingEmbeddingModels, _isLoadingLimits;

    public string ChatModelDraft { get => _chatModelDraft; set => SetProperty(ref _chatModelDraft, value); }
    public string EmbeddingModelDraft { get => _embeddingModelDraft; set => SetProperty(ref _embeddingModelDraft, value); }
    public string RuntimeContextDraft { get => _runtimeContextDraft; set { if (SetProperty(ref _runtimeContextDraft, value)) _draftRevision++; } }
    public string MaxOutputTokensDraft { get => _maxOutputTokensDraft; set { if (SetProperty(ref _maxOutputTokensDraft, value)) _draftRevision++; } }
    public ProviderModelLimits? Limits { get => _limits; private set => SetProperty(ref _limits, value); }
    public string? LimitsError { get => _limitsError; private set => SetProperty(ref _limitsError, value); }
    public string? ChatModelsError { get => _chatModelsError; private set => SetProperty(ref _chatModelsError, value); }
    public string? EmbeddingModelsError { get => _embeddingModelsError; private set => SetProperty(ref _embeddingModelsError, value); }
    public ProviderProbeStatus? ChatListingStatus { get => _chatListingStatus; private set => SetProperty(ref _chatListingStatus, value); }
    public ProviderProbeStatus? EmbeddingListingStatus { get => _embeddingListingStatus; private set => SetProperty(ref _embeddingListingStatus, value); }
    public bool IsLoadingChatModels { get => _isLoadingChatModels; private set => SetProperty(ref _isLoadingChatModels, value); }
    public bool IsLoadingEmbeddingModels { get => _isLoadingEmbeddingModels; private set => SetProperty(ref _isLoadingEmbeddingModels, value); }
    public bool IsLoadingLimits { get => _isLoadingLimits; private set => SetProperty(ref _isLoadingLimits, value); }
    public bool EmbeddingConversionNotice => _store.HasEmbeddingSelectionConversionNotice();
    public void DismissEmbeddingConversionNotice()
    {
        _store.DismissEmbeddingSelectionConversionNotice();
        OnPropertyChanged(nameof(EmbeddingConversionNotice));
    }

    // Configured providers
    public ObservableCollection<ProviderConfig> Providers { get; } = new();

    [ObservableProperty]
    public partial bool ChatModelsAvailable { get; set; }

    [ObservableProperty]
    public partial bool EmbeddingModelsAvailable { get; set; }

    [ObservableProperty]
    public partial string? SettingsError { get; set; }

    public string Version => AINotebookVersion.Current;

    public AppLanguage[] Languages { get; } = [AppLanguage.English, AppLanguage.Czech];

    public SettingsViewModel(
        ISettingsService settings, NotebookStore store, ProviderRouter router, EmbeddingWorker worker,
        UpdateChecker checker, UpdateState updateState, FolderIngestionRuntime? runtime = null,
        Func<StringKey, string>? text = null)
    {
        _runtime = runtime;
        _text = text ?? (key => key.ToString());
        _settings = settings;
        _store = store;
        _router = router;
        _worker = worker;
        _checker = checker;
        _updateState = updateState;
        ChatModelDraft = settings.SelectedChatModel;
        EmbeddingModelDraft = settings.SelectedEmbeddingModel;
    }

    // ── Update check ─────────────────────────────────────────────────────────

    public bool AutoCheckUpdates
    {
        get => _settings.AutoCheckUpdates;
        set { if (_settings.AutoCheckUpdates != value) { _settings.AutoCheckUpdates = value; OnPropertyChanged(); } }
    }

    [ObservableProperty]
    public partial UpdateCheckStatus CheckStatus { get; set; } = UpdateCheckStatus.Idle;

    [ObservableProperty]
    public partial string? AvailableVersion { get; set; }

    [RelayCommand]
    public async Task CheckForUpdatesAsync()
    {
        CheckStatus = UpdateCheckStatus.Checking;
        try
        {
            var info = await _checker.CheckAsync();
            _settings.LastUpdateCheckUtc = DateTimeOffset.UtcNow;
            if (info.IsUpdateAvailable)
            {
                AvailableVersion = info.LatestVersion;
                CheckStatus = UpdateCheckStatus.Available;
                // Feed the same state the ShellPage InfoBar (with the Download
                // button) reads, driven today only by the launch-time hook —
                // otherwise a manual check can only ever report "available"
                // with no way to act on it. Re-show even if the user
                // previously dismissed the banner for an older/same check.
                _updateState.Available = info;
                _updateState.BannerDismissed = false;
            }
            else
            {
                CheckStatus = UpdateCheckStatus.UpToDate;
                // Definitive "no update" clears any previously-shown banner
                // (mirrors the macOS UpdateService invariant). A transient
                // failure below leaves it untouched.
                _updateState.Available = null;
            }
        }
        catch
        {
            CheckStatus = UpdateCheckStatus.Failed;
        }
    }

    // ── Language ────────────────────────────────────────────────────────────

    public AppLanguage Language
    {
        get => _settings.Language;
        set
        {
            if (_settings.Language == value) return;
            // LocalizedStrings listens to the settings change and re-qualifies
            // its resource context; ApplicationLanguages.PrimaryLanguageOverride
            // must not be touched — it throws without MSIX package identity.
            _settings.Language = value;
            OnPropertyChanged();
        }
    }

    // ── Provider selection ───────────────────────────────────────────────────

    public string SelectedChatProviderId
    {
        get => _settings.SelectedChatProviderId;
        set
        {
            if (_settings.SelectedChatProviderId != value)
            {
                _settings.SelectedChatProviderId = value;
                _chatRevision++; ChatModels.Clear(); ChatListingStatus = null; ChatModelsError = null; IsLoadingChatModels = false;
                OnPropertyChanged();
                _ = LoadLimitsAsync();
            }
        }
    }

    public string SelectedEmbeddingProviderId
    {
        get => _settings.SelectedEmbeddingProviderId;
        set
        {
            if (_settings.SelectedEmbeddingProviderId != value)
            {
                _settings.SelectedEmbeddingProviderId = value;
                _embeddingRevision++; EmbeddingModels.Clear(); EmbeddingListingStatus = null; EmbeddingModelsError = null; IsLoadingEmbeddingModels = false;
                OnPropertyChanged();
            }
        }
    }

    // ── Model selection ─────────────────────────────────────────────────────

    public string SelectedChatModel
    {
        get => _settings.SelectedChatModel;
        set
        {
            if (_settings.SelectedChatModel == value) return;
            _settings.SelectedChatModel = value;
            _chatRevision++; IsLoadingChatModels = false;
            ChatModelDraft = value;
            OnPropertyChanged();
            _ = LoadLimitsAsync();
        }
    }

    public string SelectedEmbeddingModel
    {
        get => _settings.SelectedEmbeddingModel;
        set
        {
            if (_settings.SelectedEmbeddingModel != value)
            {
                _settings.SelectedEmbeddingModel = value;
                _embeddingRevision++; IsLoadingEmbeddingModels = false;
                EmbeddingModelDraft = value;
                OnPropertyChanged();
            }
        }
    }

    // ── Data loading ─────────────────────────────────────────────────────────

    public bool ApplyChatModelDraft()
    {
        var model = ChatModelDraft.Trim();
        if (model.Length == 0) return false;
        SelectedChatModel = model;
        ChatModelDraft = model;
        return true;
    }

    // The dialog obtains its re-embedding confirmation before calling this.
    public bool ApplyEmbeddingModelDraft()
    {
        var model = EmbeddingModelDraft.Trim();
        if (model.Length == 0) return false;
        SelectedEmbeddingModel = model;
        EmbeddingModelDraft = model;
        return true;
    }

    public async Task RefreshAllAsync()
    {
        _chatRevision++; _embeddingRevision++; _limitsRevision++;
        await RefreshProvidersAsync();
        await Task.WhenAll(RefreshChatModelsAsync(), RefreshEmbeddingModelsAsync(), LoadLimitsAsync());
        OnPropertyChanged(nameof(EmbeddingConversionNotice));
    }

    public Task RefreshProvidersAsync()
    {
        try
        {
            var list = _store.Providers();
            Providers.Clear(); EmbeddingProviders.Clear();
            foreach (var provider in list)
            {
                Providers.Add(provider);
                if (provider.Type.SupportsEmbeddings()) EmbeddingProviders.Add(provider);
            }
        }
        catch (Exception ex) { SettingsError = ProviderErrorText.Code(ex); }
        return Task.CompletedTask;
    }

    public async Task RefreshChatModelsAsync()
    {
        var revision = ++_chatRevision;
        var id = SelectedChatProviderId;
        var config = _store.Provider(id);
        IsLoadingChatModels = true; ChatModelsError = null; ChatListingStatus = null;
        bool Current() => revision == _chatRevision && id == SelectedChatProviderId && config == _store.Provider(id);
        try
        {
            var models = await _router.DiscoverModelsAsync(id);
            if (!Current()) return;
            ChatModels.Clear(); foreach (var model in models) ChatModels.Add(model);
            ChatModelsAvailable = models.Count > 0;
            ChatListingStatus = ProviderProbeStatus.Verified;
            // provider-listing-limits-v1: discovery may have recorded the window of an assumed model.
            if ((Limits is null || Limits.IsAssumed)
                && models.Any(m => m.Id == SelectedChatModel && m.ContextWindow is not null))
                _ = LoadLimitsAsync();
        }
        catch (ProviderListingUnsupportedException)
        {
            if (Current()) ChatListingStatus = ProviderProbeStatus.ListingUnsupported;
        }
        catch (Exception ex)
        {
            if (Current()) { ChatModelsError = ProviderErrorText.Code(ex); ChatListingStatus = ProviderProbeStatus.Failed; }
        }
        finally { if (revision == _chatRevision) IsLoadingChatModels = false; }
    }

    public async Task RefreshEmbeddingModelsAsync()
    {
        var revision = ++_embeddingRevision;
        var id = SelectedEmbeddingProviderId;
        var config = _store.Provider(id);
        IsLoadingEmbeddingModels = true; EmbeddingModelsError = null; EmbeddingListingStatus = null;
        bool Current() => revision == _embeddingRevision && id == SelectedEmbeddingProviderId && config == _store.Provider(id);
        try
        {
            if (config is not null && !config.Type.SupportsEmbeddings()) throw new ProviderConfigurationException("unsupportedEndpoint");
            var models = await _router.DiscoverModelsAsync(id);
            if (!Current()) return;
            EmbeddingModels.Clear(); foreach (var model in models) EmbeddingModels.Add(model);
            EmbeddingModelsAvailable = models.Count > 0;
            EmbeddingListingStatus = ProviderProbeStatus.Verified;
        }
        catch (ProviderListingUnsupportedException)
        {
            if (Current()) EmbeddingListingStatus = ProviderProbeStatus.ListingUnsupported;
        }
        catch (Exception ex)
        {
            if (Current()) { EmbeddingModelsError = ProviderErrorText.Code(ex); EmbeddingListingStatus = ProviderProbeStatus.Failed; }
        }
        finally { if (revision == _embeddingRevision) IsLoadingEmbeddingModels = false; }
    }

    public async Task LoadLimitsAsync()
    {
        var revision = ++_limitsRevision;
        var draft = _draftRevision;
        var id = SelectedChatProviderId; var model = SelectedChatModel; var config = _store.Provider(id);
        bool Current() => revision == _limitsRevision && id == SelectedChatProviderId && model == SelectedChatModel && config == _store.Provider(id);
        Limits = null; LimitsError = null; IsLoadingLimits = true;
        try
        {
            var limits = await _router.ResolveLimitsAsync(id, model);
            if (Current())
                ShowLimits(limits, draft == _draftRevision);
        }
        catch (Exception ex) { if (Current()) LimitsError = ProviderErrorText.Code(ex); }
        finally { if (revision == _limitsRevision) IsLoadingLimits = false; }
    }

    public Task SaveLimitsAsync()
    {
        try
        {
            if (Limits is null || Limits.ProviderId != SelectedChatProviderId || Limits.Model != SelectedChatModel ||
                !int.TryParse(RuntimeContextDraft.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var runtime) ||
                !int.TryParse(MaxOutputTokensDraft.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var output))
                throw new ProviderConfigurationException("invalidLimits");
            var limits = Limits with { RuntimeContext = runtime, MaxOutputTokens = output, Source = "user" };
            limits.Validate();
            _limitsRevision++; IsLoadingLimits = false;
            _store.SaveProviderModelLimits(limits);
            ShowLimits(limits, true);
        }
        catch (Exception ex) { LimitsError = ProviderErrorText.Code(ex); }
        return Task.CompletedTask;
    }

    public async Task ResetLimitsAsync()
    {
        var revision = ++_limitsRevision; var draft = _draftRevision;
        var id = SelectedChatProviderId; var model = SelectedChatModel; var config = _store.Provider(id);
        bool Current() => revision == _limitsRevision && id == SelectedChatProviderId && model == SelectedChatModel && config == _store.Provider(id);
        LimitsError = null; IsLoadingLimits = true;
        try
        {
            _store.DeleteProviderModelLimits(id, model);
            var limits = await _router.ResolveLimitsAsync(id, model, refresh: true);
            if (Current())
                ShowLimits(limits, draft == _draftRevision);
        }
        catch (Exception ex) { if (Current()) LimitsError = ProviderErrorText.Code(ex); }
        finally { if (revision == _limitsRevision) IsLoadingLimits = false; }
    }

    private void ShowLimits(ProviderModelLimits limits, bool updateDrafts)
    {
        Limits = limits; LimitsError = null;
        if (!updateDrafts) return;
        RuntimeContextDraft = limits.RuntimeContext.ToString(CultureInfo.InvariantCulture);
        MaxOutputTokensDraft = limits.MaxOutputTokens.ToString(CultureInfo.InvariantCulture);
    }

    // Legacy compatibility — keep the old name for callers that only care about Ollama refresh.
    public Task RefreshModelsAsync() => RefreshAllAsync();

    /// <summary>
    /// Re-index without destroying the active index: each notebook gets a fresh build captured from the selected
    /// embedder (a dimension bootstrap when unknown). Never guesses dimensions or substitutes another provider.
    /// </summary>
    [RelayCommand]
    public async Task ReindexAsync()
    {
        try
        {
            if (_runtime is null) { _worker.Kick(); return; }
            foreach (var notebook in await Task.Run(() => _store.Notebooks()))
                await _runtime.Index.RequestReindexAsync(notebook.Id!.Value);
            SettingsError = null;
        }
        catch (Exception ex) { SettingsError = ProviderErrorText.Code(ex); }
        await RefreshIndexBuildsAsync();
    }

    /// <summary>Kept for existing callers: a re-embed is now a non-destructive re-index.</summary>
    public Task ReembedAllAsync() => ReindexAsync();

    /// <summary>Discards building work only (a bootstrap job is cancelled); the active index stays.</summary>
    public async Task DiscardIndexAsync(long jobId)
    {
        try
        {
            if (_runtime is not null) await _runtime.Index.DiscardJobAsync(jobId);
            SettingsError = null;
        }
        catch (Exception ex) { SettingsError = ProviderErrorText.Code(ex); }
        await RefreshIndexBuildsAsync();
    }

    /// <summary>Retry captures the current selection into a new job; exhausted attempts are never reset.</summary>
    public async Task RetryIndexAsync(long notebookId)
    {
        try
        {
            if (_runtime is not null) await _runtime.Index.RequestReindexAsync(notebookId);
            SettingsError = null;
        }
        catch (Exception ex) { SettingsError = ProviderErrorText.Code(ex); }
        await RefreshIndexBuildsAsync();
    }

    public async Task RefreshIndexBuildsAsync()
    {
        if (_runtime is null) return;
        var rows = new List<GenerationProgressRow>();
        foreach (var notebook in await Task.Run(() => _store.Notebooks()))
        {
            var p = await _runtime.Index.ProgressAsync(notebook.Id!.Value);
            if (p.JobId is null && p.GenerationId is null) continue;
            rows.Add(GenerationProgressRow.From(notebook.Id!.Value, notebook.Name, p, _text));
        }
        IndexBuilds.Clear();
        foreach (var row in rows) IndexBuilds.Add(row);
    }
}

/// <summary>Persisted re-index state of one notebook, with localized presentation text.</summary>
public sealed record GenerationProgressRow(long NotebookId, string NotebookName, long? GenerationId, long? JobId, int Done,
    int Total, int Excluded, bool Preparing, bool Failed, bool PausedForChat, bool HasActive, string? ErrorCode)
{
    public string StatusText { get; init; } = "";
    public string ProgressText => $"{Done.ToString(CultureInfo.CurrentCulture)} / {Total.ToString(CultureInfo.CurrentCulture)}";
    public string ExcludedLabel { get; init; } = "";
    public string ExcludedText => Excluded.ToString(CultureInfo.CurrentCulture);
    public string RetryLabel { get; init; } = "";
    public string DiscardLabel { get; init; } = "";
    public bool CanRetry => Failed;
    public bool CanDiscard => JobId is not null && !Failed;

    public static GenerationProgressRow From(long notebookId, string name, GenerationProgress p, Func<StringKey, string> text) =>
        new(notebookId, name, p.GenerationId, p.JobId, p.Done, p.Total, p.Excluded, p.Preparing, p.Failed, p.PausedForChat,
            p.HasActive, p.ErrorCode)
        {
            // Preparing before dimensions are known; failure keeps the existing search; chat pauses only new batches.
            // A failure names its persisted code, never only a generic "failed".
            StatusText = text(p.Failed ? StringKey.ReindexFailed : p.Preparing ? StringKey.ReindexDiscovering
                : p.PausedForChat ? StringKey.ReindexPausedForChat : StringKey.ReindexProgress)
                + (p.Failed && !string.IsNullOrWhiteSpace(p.ErrorCode) ? $" ({p.ErrorCode})" : ""),
            ExcludedLabel = text(StringKey.FolderSkipped),
            RetryLabel = text(StringKey.ReindexRetry),
            DiscardLabel = text(StringKey.ReindexDiscard)
        };
}

/// Shared by provider Settings and Add Provider. Only known error categories
/// and reconstructed HTTP statuses reach the UI; exception bodies stay private.
internal static class ProviderErrorText
{
    internal static string Code(Exception error) => error switch
    {
        ProviderConfigurationException configuration => configuration.Code,
        ProviderContextTooLongException => "contextTooLong",
        ProviderConsentException => "consentRequired",
        ProviderAuthException => "auth",
        ProviderHttpException http => $"HTTP {http.StatusCode}.",
        OllamaException.HttpStatus http => $"HTTP {http.Code}.",
        ProviderRateLimitException => "HTTP 429.",
        JsonException or OllamaException.Decoding => "decoding",
        HttpRequestException or OperationCanceledException => "transport",
        _ => "requestFailed"
    };

    internal static string Format(string? code, Func<StringKey, string> localize)
    {
        if (code is null) return "";
        if (code == "auth") return "HTTP 401/403.";
        if (code.StartsWith("HTTP ", StringComparison.Ordinal) && code.EndsWith(".", StringComparison.Ordinal) &&
            int.TryParse(code.AsSpan(5, code.Length - 6), NumberStyles.None, CultureInfo.InvariantCulture, out var status) &&
            status is >= 100 and <= 599)
            return $"HTTP {status}.";
        return localize(code switch
        {
            "invalidBaseURL" => StringKey.ProviderInvalidRoot,
            "invalidLimits" => StringKey.ProviderLimitsInvalid,
            "contextTooLong" => StringKey.ProviderContextTooLong,
            "consentRequired" => StringKey.ErrorConsentRequired,
            "transport" => StringKey.ProviderConnectionFailed,
            "decoding" => StringKey.ProviderResponseInvalid,
            "missingProvider" or "disabledProvider" => StringKey.ProviderSelectionUnavailable,
            "unsupportedEndpoint" => StringKey.ProviderEndpointUnsupported,
            _ => StringKey.ProviderRequestFailed
        });
    }
}

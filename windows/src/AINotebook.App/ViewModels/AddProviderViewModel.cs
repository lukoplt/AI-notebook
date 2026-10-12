using AINotebook.App.Services;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AINotebook.App.ViewModels;

public sealed partial class AddProviderViewModel : ObservableObject
{
    private readonly ProviderRouter _router;
    private readonly NotebookStore _store;
    private readonly ISecretStore _secrets;
    private readonly ISettingsService? _settings;
    private readonly ProviderConfig? _existing;
    private long _probeRevision;

    public IReadOnlyList<ProviderPreset> Presets { get; }
    public string PresetHelp => Presets.FirstOrDefault(p => p.Id == SelectedPresetId)?.HelpKey ?? "providerPresetCustomHelp";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(PresetHelp))]
    public partial string SelectedPresetId { get; set; } = "custom";

    [ObservableProperty]
    public partial ProviderProbeResult? ProbeResult { get; set; }

    // null = add mode; non-null = edit mode
    public string? EditingId { get; }
    public bool IsOllamaProvider => EditingId == ProviderConfig.OllamaId;

    // The provider's type as it existed before this edit session (null in add
    // mode). Needed so the dialog can detect a type CHANGE — e.g. an edit
    // that switches from one cloud type to another — and re-gate consent for
    // it, instead of silently inheriting the old type's acknowledgement.
    public ProviderType? OriginalType { get; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowUrlAndKey), nameof(ShowKeyOnly))]
    [NotifyPropertyChangedFor(nameof(CanSave))]
    public partial ProviderType SelectedType { get; set; } = ProviderType.Ollama;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanSave))]
    public partial string Name { get; set; } = "";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanSave))]
    public partial string BaseUrl { get; set; } = ProviderType.Ollama.DefaultBaseUrl();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanSave))]
    public partial string ApiKey { get; set; } = "";

    [ObservableProperty]
    public partial string? TestStatus { get; set; }

    [ObservableProperty]
    public partial bool IsTesting { get; set; }

    [ObservableProperty]
    public partial bool TestSucceeded { get; set; }

    // Shows URL + key fields (Anthropic, OpenAI, OpenAI-compatible)
    public bool ShowUrlAndKey => SelectedType != ProviderType.Ollama;
    // Ollama always shows URL, just no key
    public bool ShowKeyOnly => SelectedType == ProviderType.Ollama;

    // Types the user can pick in add-mode (all types; Ollama only for custom base URL override)
    public static ProviderType[] AllTypes { get; } =
        [ProviderType.Ollama, ProviderType.Anthropic, ProviderType.OpenAI,
         ProviderType.OpenAICompatible, ProviderType.OpenWebUI];

    // Settings must confirm a different embedding selection before its current
    // provider can become chat-only, matching the macOS edit-provider picker.
    public ProviderType[] SelectableTypes => AllTypes
        .Where(type => !IsSelectedEmbedder || type.SupportsEmbeddings()).ToArray();
    private bool IsSelectedEmbedder => EditingId is not null && EditingId == _settings?.SelectedEmbeddingProviderId;

    public AddProviderViewModel(
        ProviderRouter router, NotebookStore store, ISecretStore secrets,
        ProviderConfig? existing = null, Func<string, string>? localize = null,
        ISettingsService? settings = null)
    {
        _router = router;
        _store = store;
        _secrets = secrets;
        _settings = settings;
        _existing = existing;
        Presets = ProviderPresets.All.Select(p => p.Id == "custom" && localize is not null
            ? p with { Name = localize("providerPresetCustom") } : p).ToArray();

        if (existing is not null)
        {
            EditingId = existing.Id;
            OriginalType = existing.Type;
            SelectedType = existing.Type;
            Name = existing.Name;
            BaseUrl = existing.BaseUrl;
            // API key is never loaded back to the VM — placeholder shown in view
        }
    }

    partial void OnSelectedTypeChanged(ProviderType value)
    {
        // Auto-fill URL if user hasn't overridden it
        if (string.IsNullOrWhiteSpace(BaseUrl) || BaseUrl == ProviderType.Ollama.DefaultBaseUrl()
            || BaseUrl == ProviderType.Anthropic.DefaultBaseUrl()
            || BaseUrl == ProviderType.OpenAI.DefaultBaseUrl())
        {
            BaseUrl = value.DefaultBaseUrl();
        }
        if (value == ProviderType.OpenAICompatible && SelectedPresetId != "custom" &&
            Presets.FirstOrDefault(p => p.Id == SelectedPresetId) is { } preset)
            BaseUrl = preset.BaseUrl;
        InvalidateProbe();
    }

    partial void OnSelectedPresetIdChanged(string value)
    {
        var preset = Presets.FirstOrDefault(p => p.Id == value);
        if (preset is not null && value != "custom") BaseUrl = preset.BaseUrl;
        InvalidateProbe();
    }

    partial void OnBaseUrlChanged(string value) => InvalidateProbe();
    partial void OnApiKeyChanged(string value) => InvalidateProbe();

    private void InvalidateProbe()
    {
        _probeRevision++;
        ProbeResult = null;
        TestStatus = null;
        TestSucceeded = false;
    }

    public bool CanSave
    {
        get
        {
            if (IsSelectedEmbedder && !SelectedType.SupportsEmbeddings()) return false;
            if (string.IsNullOrWhiteSpace(Name)) return false;
            try { ProviderApiRoot.Normalize(BaseUrl); }
            catch (ProviderConfigurationException) { return false; }
            return SelectedType is not (ProviderType.OpenAI or ProviderType.Anthropic)
                || !string.IsNullOrWhiteSpace(ApiKey)
                || (EditingId is not null && !string.IsNullOrWhiteSpace(_secrets.Load(EditingId)));
        }
    }

    /// <param name="acknowledgePrivacy">
    /// True when the caller just walked the user through (and got acceptance
    /// on) the privacy gate for this save — independent of whether an API key
    /// was entered. A keyless OpenWebUI instance (auth disabled) still sends
    /// note/query data over the network, so consent must be recorded whenever
    /// the gate was accepted, not only when a key happens to be present.
    /// </param>
    public async Task<ProviderConfig?> SaveConfirmedAsync(bool acknowledgePrivacy)
    {
        if (!CanSave) return null;
        var id = EditingId ?? Guid.NewGuid().ToString();
        var type = SelectedType;
        var key = ApiKey;
        var cfg = new ProviderConfig(
            id, type, Name.Trim(), ProviderApiRoot.Normalize(BaseUrl),
            _existing?.Enabled ?? true, type == ProviderType.Ollama || acknowledgePrivacy ||
                (_existing is { PrivacyAcknowledged: true } original && original.Type == type),
            _existing?.CreatedAt ?? DateTime.UtcNow);

        await Task.Run(() =>
        {
            _store.SaveProvider(cfg);
            // Provider edits deliberately preserve stored consent. Record a
            // newly accepted gate explicitly, including keyless providers.
            if (acknowledgePrivacy) _store.AcknowledgePrivacy(id);
        });

        if (type != ProviderType.Ollama && !string.IsNullOrWhiteSpace(key))
            _secrets.Save(id, key);

        return cfg;
    }

    [RelayCommand]
    public async Task TestAsync()
    {
        if (IsTesting) return;
        var revision = ++_probeRevision;
        var type = SelectedType;
        var root = BaseUrl;
        var key = !string.IsNullOrWhiteSpace(ApiKey) ? ApiKey
            : (EditingId != null ? _secrets.Load(EditingId) : null);
        IsTesting = true;
        ProbeResult = null;
        TestStatus = null;
        TestSucceeded = false;
        try
        {
            var result = await _router.ProbeAsync(type, root, key);
            if (revision != _probeRevision) return;
            ProbeResult = result;
            TestSucceeded = result.Status == ProviderProbeStatus.Verified;
            TestStatus = result.Detail;
        }
        catch (Exception)
        {
            if (revision != _probeRevision) return;
            ProbeResult = new(ProviderProbeStatus.Failed, [], "transport", "Unable to retrieve the model listing.");
            TestSucceeded = false;
            TestStatus = ProbeResult.Detail;
        }
        finally { IsTesting = false; }
    }

    [RelayCommand]
    public async Task DeleteAsync()
    {
        if (EditingId is null || IsOllamaProvider) return;
        await Task.Run(() =>
        {
            _store.DeleteProvider(EditingId);
            _secrets.Delete(EditingId);
        });
    }
}

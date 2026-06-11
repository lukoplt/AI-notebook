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

    // null = add mode; non-null = edit mode
    public string? EditingId { get; }
    public bool IsOllamaProvider => EditingId == ProviderConfig.OllamaId;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowUrlAndKey), nameof(ShowKeyOnly))]
    [NotifyCanExecuteChangedFor(nameof(SaveCommand))]
    public partial ProviderType SelectedType { get; set; } = ProviderType.Ollama;

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(SaveCommand))]
    public partial string Name { get; set; } = "";

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(SaveCommand))]
    public partial string BaseUrl { get; set; } = "";

    [ObservableProperty]
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
        [ProviderType.Ollama, ProviderType.Anthropic, ProviderType.OpenAI, ProviderType.OpenAICompatible];

    public AddProviderViewModel(
        ProviderRouter router, NotebookStore store, ISecretStore secrets,
        ProviderConfig? existing = null)
    {
        _router = router;
        _store = store;
        _secrets = secrets;

        if (existing is not null)
        {
            EditingId = existing.Id;
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
        TestStatus = null;
        TestSucceeded = false;
    }

    public bool CanSave =>
        !string.IsNullOrWhiteSpace(Name) &&
        !string.IsNullOrWhiteSpace(BaseUrl) &&
        // Cloud providers require a key for new entries (edit can keep existing)
        (SelectedType == ProviderType.Ollama || EditingId != null || !string.IsNullOrWhiteSpace(ApiKey));

    public async Task<ProviderConfig?> SaveConfirmedAsync()
    {
        var id = EditingId ?? Guid.NewGuid().ToString();
        var cfg = new ProviderConfig(
            id, SelectedType, Name.Trim(), BaseUrl.Trim(),
            true, SelectedType == ProviderType.Ollama,
            DateTime.UtcNow);

        await Task.Run(() => _store.SaveProvider(cfg));

        if (SelectedType != ProviderType.Ollama && !string.IsNullOrWhiteSpace(ApiKey))
            _secrets.Save(id, ApiKey);

        if (SelectedType != ProviderType.Ollama && !string.IsNullOrWhiteSpace(ApiKey))
            await Task.Run(() => _store.AcknowledgePrivacy(id));

        return cfg;
    }

    [RelayCommand]
    public async Task TestAsync()
    {
        IsTesting = true;
        TestStatus = null;
        TestSucceeded = false;
        try
        {
            var key = !string.IsNullOrWhiteSpace(ApiKey) ? ApiKey
                : (EditingId != null ? _secrets.Load(EditingId) ?? "" : "");
            var error = await _router.TestConnectionAsync(SelectedType, BaseUrl.Trim(), key);
            if (error is null)
            {
                TestSucceeded = true;
                TestStatus = null; // view shows success string when TestSucceeded
            }
            else
            {
                TestSucceeded = false;
                TestStatus = error;
            }
        }
        catch (Exception ex)
        {
            TestSucceeded = false;
            TestStatus = ex.Message;
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

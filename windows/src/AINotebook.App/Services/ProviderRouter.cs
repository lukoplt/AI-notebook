using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;

namespace AINotebook.App.Services;

/// <summary>
/// Routes IChatStreaming / IEmbeddingProducing calls to the active provider.
/// Reads provider + model from ISettingsService at every call — no stale state.
/// The `model` parameter passed by legacy callers (ChatEngine etc.) is ignored;
/// the router always uses the live setting.
/// </summary>
public sealed class ProviderRouter : IChatStreaming, IEmbeddingProducing
{
    private readonly ISettingsService _settings;
    private readonly NotebookStore _store;
    private readonly ISecretStore _secrets;
    private readonly OllamaClient _ollama;
    private readonly HttpClient _http;

    // Cached adapters — recreated when provider config changes.
    private readonly ConcurrentDictionary<string, (string hash, IChatStreaming adapter)> _chatCache = new();
    private readonly ConcurrentDictionary<string, (string hash, IEmbeddingProducing adapter)> _embedCache = new();

    public ProviderRouter(
        ISettingsService settings,
        NotebookStore store,
        ISecretStore secrets,
        OllamaClient ollama,
        HttpClient http)
    {
        _settings = settings;
        _store = store;
        _secrets = secrets;
        _ollama = ollama;
        _http = http;
    }

    /// Composite key stored in chunk_embeddings.model: "{providerId}:{model}"
    public string CurrentEmbeddingKey =>
        $"{_settings.SelectedEmbeddingProviderId}:{_settings.SelectedEmbeddingModel}";

    // ── IChatStreaming ──────────────────────────────────────────────────────

    public IAsyncEnumerable<string> StreamAsync(
        string model,   // ignored — router reads live settings
        IReadOnlyList<ChatTurn> messages,
        CancellationToken ct = default)
    {
        var providerId = _settings.SelectedChatProviderId;
        var activeModel = _settings.SelectedChatModel;
        var adapter = GetChatAdapter(providerId);
        return adapter.StreamAsync(activeModel, messages, ct);
    }

    // ── IEmbeddingProducing ─────────────────────────────────────────────────

    public Task<float[][]> EmbedAsync(
        string model,   // ignored — router reads live settings
        IReadOnlyList<string> inputs,
        CancellationToken ct = default)
    {
        var providerId = _settings.SelectedEmbeddingProviderId;
        var activeModel = _settings.SelectedEmbeddingModel;
        var adapter = GetEmbeddingAdapter(providerId);
        return adapter.EmbedAsync(activeModel, inputs, ct);
    }

    // ── Provider discovery (used by Settings UI) ────────────────────────────

    public async Task<IReadOnlyList<ProviderModelInfo>> ListModelsAsync(
        string providerId, CancellationToken ct = default)
    {
        var cfg = _store.Provider(providerId);
        if (cfg is null) return [];
        var key = _secrets.Load(providerId);
        return cfg.Type switch
        {
            ProviderType.Ollama => await ListOllamaModels(cfg.BaseUrl, ct),
            ProviderType.Anthropic => await AnthropicChatAdapter.ListModelsAsync(_http, cfg.BaseUrl, key ?? "", ct),
            ProviderType.OpenAI or ProviderType.OpenAICompatible =>
                await OpenAIChatAdapter.ListModelsAsync(_http, cfg.BaseUrl, key, ct),
            _ => []
        };
    }

    public async Task<string?> TestConnectionAsync(
        ProviderType type, string baseUrl, string apiKey, CancellationToken ct = default)
    {
        try
        {
            IReadOnlyList<ProviderModelInfo> models = type switch
            {
                ProviderType.Anthropic => await AnthropicChatAdapter.ListModelsAsync(_http, baseUrl, apiKey, ct),
                ProviderType.OpenAI or ProviderType.OpenAICompatible =>
                    await OpenAIChatAdapter.ListModelsAsync(_http, baseUrl, apiKey, ct),
                _ => await ListOllamaModels(baseUrl, ct)
            };
            return null; // success
        }
        catch (ProviderAuthException ex) { return ex.Message; }
        catch (Exception ex) { return ex.Message; }
    }

    // ── Private adapter factory ─────────────────────────────────────────────

    private IChatStreaming GetChatAdapter(string providerId)
    {
        var cfg = _store.Provider(providerId) ?? OllamaFallback();
        var key = cfg.IsCloud ? (_secrets.Load(providerId) ?? "") : "";
        var hash = $"{cfg.Type}|{cfg.BaseUrl}|{key.Length}"; // cheap change detection

        if (_chatCache.TryGetValue(providerId, out var cached) && cached.hash == hash)
            return cached.adapter;

        IChatStreaming adapter = cfg.Type switch
        {
            ProviderType.Anthropic => new AnthropicChatAdapter(_http, cfg.BaseUrl, key),
            ProviderType.OpenAI or ProviderType.OpenAICompatible => new OpenAIChatAdapter(_http, cfg.BaseUrl, key),
            _ => new OllamaChatAdapter(_ollama)
        };
        _chatCache[providerId] = (hash, adapter);
        return adapter;
    }

    private IEmbeddingProducing GetEmbeddingAdapter(string providerId)
    {
        var cfg = _store.Provider(providerId) ?? OllamaFallback();
        var key = cfg.IsCloud ? (_secrets.Load(providerId) ?? "") : "";
        var hash = $"{cfg.Type}|{cfg.BaseUrl}|{key.Length}";

        if (_embedCache.TryGetValue(providerId, out var cached) && cached.hash == hash)
            return cached.adapter;

        IEmbeddingProducing adapter = cfg.Type switch
        {
            ProviderType.OpenAI or ProviderType.OpenAICompatible =>
                new OpenAIEmbeddingAdapter(_http, cfg.BaseUrl, key),
            _ => new OllamaEmbeddingAdapter(_ollama)
        };
        _embedCache[providerId] = (hash, adapter);
        return adapter;
    }

    private async Task<IReadOnlyList<ProviderModelInfo>> ListOllamaModels(
        string baseUrl, CancellationToken ct)
    {
        try
        {
            var models = await _ollama.ListModelsAsync(ct);
            return models.Select(m => new ProviderModelInfo(m.Name, null)).ToList();
        }
        catch { return []; }
    }

    private static ProviderConfig OllamaFallback() => new(
        ProviderConfig.OllamaId, ProviderType.Ollama, "Ollama (local)",
        "http://127.0.0.1:11434", true, true, DateTime.UtcNow);
}

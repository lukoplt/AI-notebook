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
///
/// The two interfaces are handled differently (mirrors
/// Sources/AINotebookCore/Providers/ProviderRouter.swift):
///
/// - <see cref="StreamAsync"/> (chat): the `model` parameter is ignored.
///   Legacy callers (ChatEngine etc.) capture their model at launch; the
///   router always reads the live (provider, model) selection so a Settings
///   change takes effect immediately on the next call.
/// - <see cref="EmbedAsync"/>: the `model` parameter is HONORED as a
///   composite `"{providerId}:{rawModel}"` key when it contains a colon.
///   <see cref="AINotebook.Core.Rag.Embedder"/> snapshots this composite key
///   once per drain (via <see cref="CurrentEmbeddingKey"/>) for storage; if
///   the router instead re-sampled the live selection here, a settings
///   change mid-drain could route the network call to a NEW provider while
///   rows get labeled with the OLD key — silently mislabeled vectors.
///   Honoring the passed key keeps the storage label and the network call
///   from ever diverging within a drain. Callers that pass a plain
///   (colon-free) model string — the legacy/direct convenience path used by
///   some tests — still get today's live-selection behavior.
///
/// FR-A8 defense-in-depth: <see cref="GetChatAdapter"/> and
/// <see cref="GetEmbeddingAdapter"/> both throw <see cref="ProviderConsentException"/>
/// for a cloud/network provider whose config is not `PrivacyAcknowledged` —
/// enforced here on every call (not just at the add-provider gate) so a
/// Settings picker re-selection, a stale composite key, or any other path
/// can never route real data to an unacknowledged provider.
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
        string model,   // composite "{providerId}:{rawModel}" key when given — see class doc
        IReadOnlyList<string> inputs,
        CancellationToken ct = default)
    {
        string providerId;
        string activeModel;
        if (ParseCompositeKey(model) is { } parsed)
        {
            (providerId, activeModel) = parsed;
        }
        else
        {
            providerId = _settings.SelectedEmbeddingProviderId;
            activeModel = _settings.SelectedEmbeddingModel;
        }
        var adapter = GetEmbeddingAdapter(providerId);
        return adapter.EmbedAsync(activeModel, inputs, ct);
    }

    /// <summary>
    /// Splits a composite `"{providerId}:{rawModel}"` embedding key on the
    /// FIRST colon only, so raw model names that themselves contain colons
    /// (Ollama tags like `llama3.2:3b`) survive intact in `rawModel`.
    /// Returns null when the string has no colon, or the prefix before the
    /// first colon is empty — both signal "not a composite key"
    /// (legacy/direct callers), and the caller should fall back to the live
    /// selection.
    /// </summary>
    private static (string ProviderId, string RawModel)? ParseCompositeKey(string model)
    {
        var colonIndex = model.IndexOf(':');
        if (colonIndex < 0) return null;
        var providerId = model[..colonIndex];
        if (providerId.Length == 0) return null;
        var rawModel = model[(colonIndex + 1)..];
        return (providerId, rawModel);
    }

    // ── Provider discovery (used by Settings UI) ────────────────────────────

    /// UI-safe: this backs the Settings model pickers, so failures collapse
    /// to an empty list rather than throwing. The underlying Core adapters
    /// (OpenAI/OpenWebUI via the shared OpenAIStyleWire helper) now throw on
    /// ANY failure — macOS parity — so this catch is load-bearing, not
    /// defensive filler: without it, a misconfigured provider would blow up
    /// the picker refresh instead of just showing no models.
    /// <see cref="TestConnectionAsync"/> is the throwing counterpart — it
    /// must NOT catch here, since Test connection needs the real error.
    public async Task<IReadOnlyList<ProviderModelInfo>> ListModelsAsync(
        string providerId, CancellationToken ct = default)
    {
        var cfg = _store.Provider(providerId);
        if (cfg is null) return [];
        var key = _secrets.Load(providerId);
        try
        {
            return cfg.Type switch
            {
                ProviderType.Ollama => await ListOllamaModels(cfg.BaseUrl, ct),
                ProviderType.Anthropic => await AnthropicChatAdapter.ListModelsAsync(_http, cfg.BaseUrl, key ?? "", ct),
                ProviderType.OpenAI or ProviderType.OpenAICompatible =>
                    await OpenAIChatAdapter.ListModelsAsync(_http, cfg.BaseUrl, key, ct),
                ProviderType.OpenWebUI => await OpenWebUIChatAdapter.ListModelsAsync(_http, cfg.BaseUrl, key, ct),
                _ => []
            };
        }
        catch
        {
            return [];
        }
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
                ProviderType.OpenWebUI => await OpenWebUIChatAdapter.ListModelsAsync(_http, baseUrl, apiKey, ct),
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
        // FR-A8 defense-in-depth: without consent, a cloud/network provider
        // must not receive data — checked here (not just at the add-provider
        // gate) so a picker re-selection can never bypass it. Gated BEFORE
        // the adapter cache lookup/hash below: consent is NOT part of the
        // cache hash, and cfg is re-read from the store on every call, so
        // running the check unconditionally (cache hit or miss) means
        // acknowledging consent later takes effect immediately instead of
        // ever serving a stale refusal — and no adapter is ever cached for
        // an unacknowledged config in the first place. The built-in Ollama
        // fallback is never cloud, so it is unaffected.
        if (cfg.IsCloud && !cfg.PrivacyAcknowledged)
            throw new ProviderConsentException("Provider not enabled — confirm data sharing in Settings");

        var key = cfg.IsCloud ? (_secrets.Load(providerId) ?? "") : "";
        var hash = $"{cfg.Type}|{cfg.BaseUrl}|{key.Length}"; // cheap change detection

        if (_chatCache.TryGetValue(providerId, out var cached) && cached.hash == hash)
            return cached.adapter;

        IChatStreaming adapter = cfg.Type switch
        {
            ProviderType.Anthropic => new AnthropicChatAdapter(_http, cfg.BaseUrl, key),
            ProviderType.OpenAI or ProviderType.OpenAICompatible => new OpenAIChatAdapter(_http, cfg.BaseUrl, key),
            ProviderType.OpenWebUI => new OpenWebUIChatAdapter(_http, cfg.BaseUrl, key),
            _ => new OllamaChatAdapter(_ollama)
        };
        _chatCache[providerId] = (hash, adapter);
        return adapter;
    }

    private IEmbeddingProducing GetEmbeddingAdapter(string providerId)
    {
        var cfg = _store.Provider(providerId) ?? OllamaFallback();
        // FR-A8 defense-in-depth: same gate as GetChatAdapter above.
        if (cfg.IsCloud && !cfg.PrivacyAcknowledged)
            throw new ProviderConsentException("Provider not enabled — confirm data sharing in Settings");

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

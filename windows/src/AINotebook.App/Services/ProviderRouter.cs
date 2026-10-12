using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using CoreProviderRouter = AINotebook.Core.Providers.Routing.ProviderRouter;
using ProviderModelLimits = AINotebook.Core.Providers.ProviderModelLimits;

namespace AINotebook.App.Services;

/// <summary>App dependency injection and settings handoff for Core provider routing.</summary>
public sealed class ProviderRouter : IChatStreaming, IEmbeddingProducing, IChatSessionPreparing, IEmbeddingSessionPreparing
{
    private readonly ISettingsService _settings;
    private readonly CoreProviderRouter _core;

    public ProviderRouter(ISettingsService settings, NotebookStore store, ISecretStore secrets,
        OllamaClient ollama, HttpClient http)
    {
        _settings = settings;
        // v19 records this handoff durably because settings live outside SQLite.
        // Complete only after both setting writes succeed; retry after interruption.
        if (store.PendingEmbeddingSelectionConversion() is { } conversion)
        {
            settings.SelectedEmbeddingProviderId = conversion.ProviderId;
            settings.SelectedEmbeddingModel = conversion.Model;
            store.CompleteEmbeddingSelectionConversion();
        }
        _core = new CoreProviderRouter(store,
            () => (settings.SelectedChatProviderId, settings.SelectedChatModel),
            () => (settings.SelectedEmbeddingProviderId, settings.SelectedEmbeddingModel),
            secrets.Load, http);
    }

    public string CurrentEmbeddingKey =>
        $"{_settings.SelectedEmbeddingProviderId}:{_settings.SelectedEmbeddingModel}";

    public IAsyncEnumerable<string> StreamAsync(string model, IReadOnlyList<ChatTurn> messages,
        CancellationToken ct = default) => _core.StreamAsync(model, messages, ct);

    public IAsyncEnumerable<string> StreamAsync(string model, IReadOnlyList<ChatTurn> messages,
        ChatRequestOptions options, CancellationToken ct = default) => _core.StreamAsync(model, messages, options, ct);

    public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs,
        CancellationToken ct = default) => _core.EmbedAsync(model, inputs, ct);

    public Task<ProviderChatSession> PrepareChatAsync(string? model = null,
        CancellationToken ct = default) => _core.PrepareChatAsync(model, ct);

    // Retrieval captures one immutable, generation-bound embedding session per query.
    public Task<ProviderEmbeddingSession> PrepareEmbeddingAsync(GenerationIdentity identity,
        CancellationToken ct = default) => _core.PrepareEmbeddingAsync(identity, ct);

    public Task<IReadOnlyList<ProviderModelInfo>> DiscoverModelsAsync(string providerId,
        CancellationToken ct = default) => _core.DiscoverModelsAsync(providerId, ct);

    public Task<ProviderProbeResult> ProbeAsync(ProviderType type, string baseUrl, string? apiKey,
        CancellationToken ct = default) => _core.ProbeAsync(type, baseUrl, apiKey, ct);

    public Task<ProviderModelLimits> ResolveLimitsAsync(string providerId, string model,
        bool refresh = false, CancellationToken ct = default) => _core.ResolveLimitsAsync(providerId, model, refresh, ct);
}

using AINotebook.Core.Ollama;

namespace AINotebook.Core.Providers;

/// <summary>
/// OpenAI-compatible streaming chat adapter (works for OpenAI, LM Studio, OpenRouter, vLLM).
/// System turn stays in the messages array as role:"system" (standard OpenAI format).
/// Thin wrapper over <see cref="OpenAIStyleWire"/> — the shared request building,
/// status mapping, and SSE loop live there.
/// </summary>
public sealed class OpenAIChatAdapter : IChatStreaming
{
    private const string ChatPath = "/v1/chat/completions";
    private const string ModelsPath = "/v1/models";

    private readonly HttpClient _http;
    private readonly string _baseUrl;
    private readonly string? _apiKey;

    public OpenAIChatAdapter(HttpClient http, string baseUrl, string? apiKey = null)
    {
        _http = http;
        _baseUrl = baseUrl.TrimEnd('/');
        _apiKey = apiKey;
    }

    public IAsyncEnumerable<string> StreamAsync(
        string model,
        IReadOnlyList<ChatTurn> messages,
        CancellationToken ct = default)
    {
        var req = OpenAIStyleWire.BuildChatRequest(_baseUrl, ChatPath, _apiKey, model, messages);
        return OpenAIStyleWire.StreamAsync(_http, req, ct);
    }

    /// <summary>
    /// GET {base}/v1/models → {"data":[{"id","name"?}]}. Throws on ANY
    /// failure (macOS parity) — 401 → ProviderAuthException, other HTTP
    /// failures → ProviderException, network errors / cancellation propagate.
    /// Callers that need a UI-safe empty-list-on-failure surface (the model
    /// picker) must catch at the router layer; Test connection relies on
    /// this throwing so it can report real failures instead of a false
    /// "success" with zero models.
    /// </summary>
    public static Task<IReadOnlyList<ProviderModelInfo>> ListModelsAsync(
        HttpClient http, string baseUrl, string? apiKey, CancellationToken ct = default)
        => OpenAIStyleWire.ListModelsAsync(http, baseUrl, ModelsPath, apiKey, ct);
}

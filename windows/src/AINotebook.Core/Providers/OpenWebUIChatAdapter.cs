using AINotebook.Core.Ollama;

namespace AINotebook.Core.Providers;

/// <summary>
/// OpenWebUI streaming chat adapter. OpenWebUI aggregates models (local Ollama,
/// cloud backends, functions) behind an OpenAI-shaped API rooted at /api, NOT /v1:
/// POST {base}/api/chat/completions, GET {base}/api/models.
/// Bearer key optional — instances may run with auth disabled.
/// Chat-only: OpenWebUI exposes no OpenAI-compatible embeddings endpoint.
/// Thin wrapper over <see cref="OpenAIStyleWire"/> — the shared request building,
/// status mapping, and SSE loop live there.
/// </summary>
public sealed class OpenWebUIChatAdapter : IChatStreaming
{
    private const string ChatPath = "/api/chat/completions";
    private const string ModelsPath = "/api/models";

    private readonly HttpClient _http;
    private readonly string _baseUrl;
    private readonly string? _apiKey;

    public OpenWebUIChatAdapter(HttpClient http, string baseUrl, string? apiKey = null)
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
    /// GET {base}/api/models → {"data":[{"id","name",...}]}. Includes every model the
    /// key's user can access. Throws on ANY failure (macOS parity, via the shared
    /// OpenAIStyleWire helper) — 401 → ProviderAuthException, other HTTP failures →
    /// ProviderException, network errors (HttpRequestException) and cancellation
    /// propagate — so the router's TestConnectionAsync can surface a visible error
    /// message instead of a false "success" with zero models.
    /// </summary>
    public static Task<IReadOnlyList<ProviderModelInfo>> ListModelsAsync(
        HttpClient http, string baseUrl, string? apiKey, CancellationToken ct = default)
        => OpenAIStyleWire.ListModelsAsync(http, baseUrl, ModelsPath, apiKey, ct);
}

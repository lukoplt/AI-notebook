using System.Net;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;

namespace AINotebook.Core.Providers;

/// <summary>
/// Anthropic Messages API streaming adapter.
/// System prompt is extracted from the first ChatTurn with Role.System
/// and placed in the top-level "system" field (Anthropic API requirement).
/// </summary>
public sealed class AnthropicChatAdapter : IChatStreaming
{
    private readonly HttpClient _http;
    private readonly string _baseUrl;
    private readonly string _apiKey;

    private const string AnthropicVersion = "2023-06-01";
    private const int MaxTokens = 8192;

    public AnthropicChatAdapter(HttpClient http, string baseUrl, string apiKey)
    {
        _http = http;
        _baseUrl = baseUrl.TrimEnd('/');
        _apiKey = apiKey;
    }

    public async IAsyncEnumerable<string> StreamAsync(
        string model,
        IReadOnlyList<ChatTurn> messages,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        // Extract optional leading system turn.
        string? system = null;
        int start = 0;
        if (messages.Count > 0 && messages[0].Role == ChatRole.System)
        {
            system = messages[0].Content;
            start = 1;
        }

        var wireMessages = new List<object>();
        for (var i = start; i < messages.Count; i++)
        {
            wireMessages.Add(new
            {
                role = messages[i].Role == ChatRole.Assistant ? "assistant" : "user",
                content = messages[i].Content
            });
        }

        var body = new Dictionary<string, object>
        {
            ["model"] = model,
            ["max_tokens"] = MaxTokens,
            ["stream"] = true,
            ["messages"] = wireMessages
        };
        if (system is not null) body["system"] = system;

        var json = JsonSerializer.Serialize(body);
        using var req = new HttpRequestMessage(HttpMethod.Post, $"{_baseUrl}/v1/messages")
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json")
        };
        req.Headers.Add("x-api-key", _apiKey);
        req.Headers.Add("anthropic-version", AnthropicVersion);
        req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));

        using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);

        if (resp.StatusCode == HttpStatusCode.Unauthorized)
            throw new ProviderAuthException("Anthropic: invalid API key (401).");
        if (resp.StatusCode == (HttpStatusCode)429)
            throw new ProviderRateLimitException("Anthropic: rate limit exceeded (429).");
        if (!resp.IsSuccessStatusCode)
            throw new ProviderException($"Anthropic: HTTP {(int)resp.StatusCode}.");

        using var stream = await resp.Content.ReadAsStreamAsync(ct);
        using var reader = new StreamReader(stream);

        string? line;
        while ((line = await reader.ReadLineAsync(ct)) is not null)
        {
            if (!line.StartsWith("data: ", StringComparison.Ordinal)) continue;
            var data = line["data: ".Length..];
            if (data == "[DONE]") yield break;

            JsonElement root;
            try { root = JsonSerializer.Deserialize<JsonElement>(data); }
            catch { continue; }

            if (!root.TryGetProperty("type", out var typeProp)) continue;
            var type = typeProp.GetString();

            if (type == "content_block_delta"
                && root.TryGetProperty("delta", out var delta)
                && delta.TryGetProperty("type", out var dt)
                && dt.GetString() == "text_delta"
                && delta.TryGetProperty("text", out var text))
            {
                var token = text.GetString();
                if (!string.IsNullOrEmpty(token)) yield return token;
            }
            else if (type == "message_delta"
                && root.TryGetProperty("delta", out var md)
                && md.TryGetProperty("stop_reason", out var sr)
                && sr.GetString() == "refusal")
            {
                throw new ProviderRefusalException("Anthropic: request refused by safety classifier.");
            }
            else if (type == "message_stop")
            {
                yield break;
            }
        }
    }

    /// List models via GET /v1/models; returns empty list on failure.
    public static async Task<IReadOnlyList<ProviderModelInfo>> ListModelsAsync(
        HttpClient http, string baseUrl, string apiKey, CancellationToken ct = default)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, $"{baseUrl.TrimEnd('/')}/v1/models");
            req.Headers.Add("x-api-key", apiKey);
            req.Headers.Add("anthropic-version", AnthropicVersion);
            using var resp = await http.SendAsync(req, ct);
            if (!resp.IsSuccessStatusCode) return [];
            var json = await resp.Content.ReadAsStringAsync(ct);
            var root = JsonSerializer.Deserialize<JsonElement>(json);
            if (!root.TryGetProperty("data", out var data)) return [];
            var result = new List<ProviderModelInfo>();
            foreach (var item in data.EnumerateArray())
            {
                var id = item.TryGetProperty("id", out var idp) ? idp.GetString() : null;
                var name = item.TryGetProperty("display_name", out var np) ? np.GetString() : null;
                if (id is not null) result.Add(new ProviderModelInfo(id, name));
            }
            return result;
        }
        catch { return []; }
    }

    // Default model IDs shown when API discovery fails.
    public static readonly IReadOnlyList<ProviderModelInfo> DefaultModels =
    [
        new("claude-opus-4-8", "Claude Opus 4.8"),
        new("claude-sonnet-4-6", "Claude Sonnet 4.6"),
        new("claude-haiku-4-5", "Claude Haiku 4.5"),
        new("claude-fable-5", "Claude Fable 5"),
    ];
}

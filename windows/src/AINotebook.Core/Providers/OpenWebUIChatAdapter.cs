using System.Net;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;

namespace AINotebook.Core.Providers;

/// <summary>
/// OpenWebUI streaming chat adapter. OpenWebUI aggregates models (local Ollama,
/// cloud backends, functions) behind an OpenAI-shaped API rooted at /api, NOT /v1:
/// POST {base}/api/chat/completions, GET {base}/api/models.
/// Bearer key optional — instances may run with auth disabled.
/// Chat-only: OpenWebUI exposes no OpenAI-compatible embeddings endpoint.
/// </summary>
public sealed class OpenWebUIChatAdapter : IChatStreaming
{
    private readonly HttpClient _http;
    private readonly string _baseUrl;
    private readonly string? _apiKey;

    public OpenWebUIChatAdapter(HttpClient http, string baseUrl, string? apiKey = null)
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
        var wireMessages = messages.Select(m => new
        {
            role = m.Role switch
            {
                ChatRole.System => "system",
                ChatRole.Assistant => "assistant",
                _ => "user"
            },
            content = m.Content
        }).ToList();

        var body = new { model, messages = wireMessages, stream = true };
        var json = JsonSerializer.Serialize(body);

        using var req = new HttpRequestMessage(HttpMethod.Post, $"{_baseUrl}/api/chat/completions")
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json")
        };
        if (!string.IsNullOrEmpty(_apiKey))
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);
        req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));

        using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);

        if (resp.StatusCode == HttpStatusCode.Unauthorized)
            throw new ProviderAuthException("Invalid API key (401).");
        if (resp.StatusCode == (HttpStatusCode)429)
            throw new ProviderRateLimitException("Rate limit exceeded (429).");
        if (!resp.IsSuccessStatusCode)
            throw new ProviderException($"HTTP {(int)resp.StatusCode}.");

        using var stream = await resp.Content.ReadAsStreamAsync(ct);
        using var reader = new StreamReader(stream);

        string? line;
        while ((line = await reader.ReadLineAsync(ct)) is not null)
        {
            if (!line.StartsWith("data: ", StringComparison.Ordinal)) continue;
            var data = line["data: ".Length..].Trim();
            if (data == "[DONE]") yield break;

            JsonElement root;
            try { root = JsonSerializer.Deserialize<JsonElement>(data); }
            catch { continue; }

            if (!root.TryGetProperty("choices", out var choices)) continue;
            foreach (var choice in choices.EnumerateArray())
            {
                if (!choice.TryGetProperty("delta", out var delta)) continue;
                if (delta.TryGetProperty("content", out var content))
                {
                    var token = content.GetString();
                    if (!string.IsNullOrEmpty(token)) yield return token;
                }
            }
        }
    }

    /// <summary>
    /// GET {base}/api/models → {"data":[{"id","name",...}]}. Includes every model the
    /// key's user can access. Throws ProviderAuthException on 401 so Test connection
    /// can report an invalid key; other failures return an empty list.
    /// </summary>
    public static async Task<IReadOnlyList<ProviderModelInfo>> ListModelsAsync(
        HttpClient http, string baseUrl, string? apiKey, CancellationToken ct = default)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, $"{baseUrl.TrimEnd('/')}/api/models");
            if (!string.IsNullOrEmpty(apiKey))
                req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
            using var resp = await http.SendAsync(req, ct);
            if (resp.StatusCode == HttpStatusCode.Unauthorized)
                throw new ProviderAuthException("Invalid API key (401).");
            if (!resp.IsSuccessStatusCode) return [];
            var json = await resp.Content.ReadAsStringAsync(ct);
            var root = JsonSerializer.Deserialize<JsonElement>(json);
            if (!root.TryGetProperty("data", out var data)) return [];
            var result = new List<ProviderModelInfo>();
            foreach (var item in data.EnumerateArray())
            {
                var id = item.TryGetProperty("id", out var idp) ? idp.GetString() : null;
                if (id is null) continue;
                var name = item.TryGetProperty("name", out var np) ? np.GetString() : null;
                result.Add(new ProviderModelInfo(id, name));
            }
            return result.OrderBy(m => m.Label, StringComparer.OrdinalIgnoreCase).ToList();
        }
        catch (ProviderAuthException) { throw; }
        catch { return []; }
    }
}

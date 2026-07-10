using System.Net;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;

namespace AINotebook.Core.Providers;

/// <summary>
/// Shared request building, status mapping, and the single OpenAI-shape SSE
/// stream runner used by the OpenAI, OpenAI-compatible, and OpenWebUI
/// adapters — the C# mirror of Sources/AINotebookCore/Providers/ProviderWire.swift.
/// <see cref="AnthropicChatAdapter"/> also reuses <see cref="ThrowForStatus"/>
/// for its status mapping (its request shape and SSE event loop otherwise
/// differ too much from the OpenAI shape to share).
/// </summary>
internal static class OpenAIStyleWire
{
    private static string WireRole(ChatRole role) => role switch
    {
        ChatRole.System => "system",
        ChatRole.Assistant => "assistant",
        _ => "user"
    };

    /// Builds the POST {baseUrl}{path} request: JSON body {model, messages, stream:true},
    /// optional Bearer auth, Accept: text/event-stream.
    internal static HttpRequestMessage BuildChatRequest(
        string baseUrl, string path, string? apiKey, string model, IReadOnlyList<ChatTurn> messages)
    {
        var wireMessages = messages.Select(m => new
        {
            role = WireRole(m.Role),
            content = m.Content
        }).ToList();

        var body = new { model, messages = wireMessages, stream = true };
        var json = JsonSerializer.Serialize(body);

        var req = new HttpRequestMessage(HttpMethod.Post, $"{baseUrl.TrimEnd('/')}{path}")
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json")
        };
        if (!string.IsNullOrEmpty(apiKey))
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
        return req;
    }

    /// No-op for 2xx; otherwise the FR-A10 mapping: 401 → auth, 429 → rate
    /// limit, any other non-success → generic ProviderException.
    internal static void ThrowForStatus(HttpResponseMessage resp)
    {
        if (resp.StatusCode == HttpStatusCode.Unauthorized)
            throw new ProviderAuthException("Invalid API key (401).");
        if (resp.StatusCode == (HttpStatusCode)429)
            throw new ProviderRateLimitException("Rate limit exceeded (429).");
        if (!resp.IsSuccessStatusCode)
            throw new ProviderException($"HTTP {(int)resp.StatusCode}.");
    }

    /// The one OpenAI-shape SSE runner: send, map status, split lines, parse
    /// deltas, honor [DONE].
    internal static async IAsyncEnumerable<string> StreamAsync(
        HttpClient http, HttpRequestMessage req, [EnumeratorCancellation] CancellationToken ct = default)
    {
        using var resp = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        ThrowForStatus(resp);

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

    /// GET {baseUrl}{path} → {"data":[{"id","name"?}]}. Throws on ANY
    /// failure — 401 → ProviderAuthException, other non-success →
    /// ProviderException, network errors / cancellation propagate as-is
    /// (macOS parity: listOpenAIStyleModels never silently swallows).
    /// Sorted by Label, ordinal case-insensitive.
    internal static async Task<IReadOnlyList<ProviderModelInfo>> ListModelsAsync(
        HttpClient http, string baseUrl, string path, string? apiKey, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, $"{baseUrl.TrimEnd('/')}{path}");
        if (!string.IsNullOrEmpty(apiKey))
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);

        using var resp = await http.SendAsync(req, ct);
        ThrowForStatus(resp);

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
}

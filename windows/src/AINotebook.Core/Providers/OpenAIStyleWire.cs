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

    internal static IReadOnlyList<ChatTurn> CanonicalMessages(IReadOnlyList<ChatTurn> turns)
    {
        var systems = turns.Where(x => x.Role == ChatRole.System).Select(x => x.Content).ToArray();
        var rest = turns.Where(x => x.Role != ChatRole.System).ToList();
        if (systems.Length != 0) rest.Insert(0, new(ChatRole.System, string.Join("\n\n", systems)));
        return rest;
    }

    /// Builds the chat request with canonical messages and an output limit,
    /// optional Bearer auth, Accept: text/event-stream.
    internal static HttpRequestMessage BuildChatRequest(
        string baseUrl, ProviderType type, string? apiKey, string model,
        IReadOnlyList<ChatTurn> messages, ChatRequestOptions options)
    {
        options.Validate();
        var url = ProviderApiRoot.Build(type, baseUrl, ProviderEndpoint.Chat);
        var wireMessages = CanonicalMessages(messages).Select(m => new
        {
            role = WireRole(m.Role),
            content = m.Content
        }).ToList();

        var body = new { model, messages = wireMessages, stream = true, max_tokens = options.MaxOutputTokens };
        var json = JsonSerializer.Serialize(body);

        var req = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json")
        };
        if (!string.IsNullOrEmpty(apiKey))
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
        return req;
    }

    /// No-op for 2xx; 401/403 map to auth, 429 to rate limit, others to typed HTTP status.
    internal static void ThrowForStatus(HttpResponseMessage resp)
    {
        if (resp.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            throw new ProviderAuthException($"Authentication failed ({(int)resp.StatusCode}).");
        if (resp.StatusCode == (HttpStatusCode)429)
            throw new ProviderRateLimitException("Rate limit exceeded (429).", RetryAfter(resp));
        if (!resp.IsSuccessStatusCode)
            throw new ProviderHttpException((int)resp.StatusCode);
    }

    // Error content is untrusted and may be arbitrarily large. Never buffer a
    // successful stream or include provider response text in an exception.
    internal static async Task ThrowForChatStatusAsync(
        HttpResponseMessage resp, ProviderType type, CancellationToken ct)
    {
        if (resp.IsSuccessStatusCode) return;
        if ((int)resp.StatusCode == 413) throw new ProviderContextTooLongException();

        await using var stream = await resp.Content.ReadAsStreamAsync(ct);
        var bytes = new byte[65_536];
        var total = 0;
        while (total < bytes.Length)
        {
            var count = await stream.ReadAsync(bytes.AsMemory(total, bytes.Length - total), ct);
            if (count == 0) break;
            total += count;
        }

        if (IsContextTooLong(bytes.AsMemory(0, total), type))
            throw new ProviderContextTooLongException();
        ThrowForStatus(resp);
    }

    private static bool IsContextTooLong(ReadOnlyMemory<byte> bytes, ProviderType type)
    {
        try
        {
            using var json = JsonDocument.Parse(bytes);
            if (json.RootElement.ValueKind != JsonValueKind.Object ||
                !json.RootElement.TryGetProperty("error", out var error) ||
                error.ValueKind != JsonValueKind.Object) return false;

            if (error.TryGetProperty("code", out var code) && code.ValueKind == JsonValueKind.String &&
                code.GetString() is "context_length_exceeded" or "prompt_too_long") return true;

            return type == ProviderType.Anthropic &&
                error.TryGetProperty("type", out var errorType) && errorType.ValueKind == JsonValueKind.String &&
                errorType.GetString() == "invalid_request_error" &&
                error.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.String &&
                message.GetString()!.StartsWith("prompt is too long", StringComparison.Ordinal);
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException)
        {
            return false;
        }
    }

    /// <summary>
    /// The server's Retry-After hint, or null when it sent none. HTTP allows
    /// both forms — delta-seconds and an HTTP-date — and HttpClient parses them
    /// into <c>Delta</c> and <c>Date</c> respectively, so both are handled.
    /// A past or negative date yields null rather than a negative delay.
    /// (macOS reads the same header in ProviderWire.error(forStatus:), but only
    /// the delta-seconds form.)
    /// </summary>
    private static TimeSpan? RetryAfter(HttpResponseMessage resp)
    {
        var header = resp.Headers.RetryAfter;
        if (header is null) return null;
        if (header.Delta is { } delta)
            return delta > TimeSpan.Zero ? delta : null;
        if (header.Date is { } date)
        {
            var wait = date - DateTimeOffset.UtcNow;
            return wait > TimeSpan.Zero ? wait : null;
        }
        return null;
    }

    /// The one OpenAI-shape SSE runner: send, map status, split lines, parse
    /// deltas, honor [DONE].
    internal static async IAsyncEnumerable<string> StreamAsync(
        HttpClient http, HttpRequestMessage req, [EnumeratorCancellation] CancellationToken ct = default)
    {
        using var request = req;
        using var resp = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        await ThrowForChatStatusAsync(resp, ProviderType.OpenAICompatible, ct);

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

    /// GET the exact root's models endpoint → {"data":[{"id","name"?}]}. Throws on ANY
    /// failure — 401 → ProviderAuthException, other non-success →
    /// ProviderException, network errors / cancellation propagate as-is
    /// (macOS parity: listOpenAIStyleModels never silently swallows).
    /// Sorted by Label, ordinal case-insensitive.
    /// <summary>The raw model listing body after status mapping (discovery and limit refresh share it).</summary>
    internal static async Task<string> ListingJsonAsync(
        HttpClient http, string baseUrl, ProviderType type, string? apiKey, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get,
            ProviderApiRoot.Build(type, baseUrl, ProviderEndpoint.Models));
        if (!string.IsNullOrEmpty(apiKey))
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);

        using var resp = await http.SendAsync(req, ct);
        ThrowForStatus(resp);
        return await resp.Content.ReadAsStringAsync(ct);
    }

    internal static async Task<IReadOnlyList<ProviderModelInfo>> ListModelsAsync(
        HttpClient http, string baseUrl, ProviderType type, string? apiKey, CancellationToken ct = default)
    {
        var json = await ListingJsonAsync(http, baseUrl, type, apiKey, ct);
        var root = JsonSerializer.Deserialize<JsonElement>(json);
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("data", out var data) ||
            data.ValueKind != JsonValueKind.Array)
            throw new JsonException("Expected a data array.");

        var result = new List<ProviderModelInfo>();
        foreach (var item in data.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object || !item.TryGetProperty("id", out var id) ||
                id.ValueKind != JsonValueKind.String)
                throw new JsonException("Expected a model ID string.");
            string? name = null;
            if (item.TryGetProperty("name", out var np) && np.ValueKind != JsonValueKind.Null)
            {
                if (np.ValueKind != JsonValueKind.String) throw new JsonException("Expected a model name string.");
                name = ModelString(np);
            }
            // provider-listing-limits-v1; ProviderDiscovery keeps it only for OpenWebUI / OpenAI-compatible.
            result.Add(new ProviderModelInfo(ModelString(id), name, ProviderLimitPolicy.ContextWindowFromListingItem(item)));
        }
        return result.OrderBy(m => m.Label, StringComparer.OrdinalIgnoreCase).ToList();
    }

    private static string ModelString(JsonElement value)
    {
        try { return value.GetString()!; }
        catch (InvalidOperationException)
        {
            // JsonDocument accepts unpaired surrogate escapes until GetString.
            throw new JsonException("Invalid model listing string.");
        }
    }
}

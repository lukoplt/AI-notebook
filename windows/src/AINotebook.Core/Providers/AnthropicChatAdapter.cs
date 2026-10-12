using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;

namespace AINotebook.Core.Providers;

/// <summary>
/// Anthropic Messages API streaming adapter.
/// All system turns are joined in their original order
/// and placed in the top-level "system" field (Anthropic API requirement).
/// </summary>
public sealed class AnthropicChatAdapter : IChatStreaming
{
    private readonly HttpClient _http;
    private readonly string _baseUrl;
    private readonly string _apiKey;

    private const string AnthropicVersion = "2023-06-01";

    public AnthropicChatAdapter(HttpClient http, string baseUrl, string apiKey)
    {
        _http = http;
        _baseUrl = baseUrl;
        _apiKey = apiKey;
    }

    public IAsyncEnumerable<string> StreamAsync(
        string model,
        IReadOnlyList<ChatTurn> messages,
        CancellationToken ct = default)
        => StreamAsync(model, messages, ChatRequestOptions.Defaults, ct);

    public async IAsyncEnumerable<string> StreamAsync(
        string model,
        IReadOnlyList<ChatTurn> messages,
        ChatRequestOptions options,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        options.Validate();
        var canonical = OpenAIStyleWire.CanonicalMessages(messages);
        string? system = null;
        int start = 0;
        if (canonical.Count > 0 && canonical[0].Role == ChatRole.System)
        {
            system = canonical[0].Content;
            start = 1;
        }

        var wireMessages = new List<object>();
        for (var i = start; i < canonical.Count; i++)
        {
            wireMessages.Add(new
            {
                role = canonical[i].Role == ChatRole.Assistant ? "assistant" : "user",
                content = canonical[i].Content
            });
        }

        var body = new Dictionary<string, object>
        {
            ["model"] = model,
            ["max_tokens"] = options.MaxOutputTokens,
            ["stream"] = true,
            ["messages"] = wireMessages
        };
        if (system is not null) body["system"] = system;

        var json = JsonSerializer.Serialize(body);
        using var req = new HttpRequestMessage(HttpMethod.Post,
            ProviderApiRoot.Build(ProviderType.Anthropic, _baseUrl, ProviderEndpoint.Chat))
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json")
        };
        req.Headers.Add("x-api-key", _apiKey);
        req.Headers.Add("anthropic-version", AnthropicVersion);
        req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));

        using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);

        await OpenAIStyleWire.ThrowForChatStatusAsync(resp, ProviderType.Anthropic, ct);

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

    /// Lists models via GET /v1/models; transport, HTTP and schema failures propagate.
    public static async Task<IReadOnlyList<ProviderModelInfo>> ListModelsAsync(
        HttpClient http, string baseUrl, string apiKey, CancellationToken ct = default)
    {
        var url = ProviderApiRoot.Build(ProviderType.Anthropic, baseUrl, ProviderEndpoint.Models);
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.Add("x-api-key", apiKey);
        req.Headers.Add("anthropic-version", AnthropicVersion);
        using var resp = await http.SendAsync(req, ct);
        OpenAIStyleWire.ThrowForStatus(resp);
        var json = await resp.Content.ReadAsStringAsync(ct);
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("data", out var data) ||
            data.ValueKind != JsonValueKind.Array)
            throw new JsonException("Expected a model data array.");
        var result = new List<ProviderModelInfo>();
        foreach (var item in data.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object || !item.TryGetProperty("id", out var id) ||
                id.ValueKind != JsonValueKind.String)
                throw new JsonException("Expected a model ID string.");
            string? name = null;
            if (item.TryGetProperty("display_name", out var displayName) && displayName.ValueKind != JsonValueKind.Null)
            {
                if (displayName.ValueKind != JsonValueKind.String)
                    throw new JsonException("Expected a model display name string.");
                name = ModelString(displayName);
            }
            result.Add(new ProviderModelInfo(ModelString(id), name));
        }
        return result;
    }

    private static string ModelString(JsonElement value)
    {
        try { return value.GetString()!; }
        catch (InvalidOperationException)
        {
            throw new JsonException("Invalid model listing string.");
        }
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

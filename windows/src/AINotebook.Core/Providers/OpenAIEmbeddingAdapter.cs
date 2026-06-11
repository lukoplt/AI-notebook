using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Ollama;

namespace AINotebook.Core.Providers;

/// <summary>
/// OpenAI-compatible embeddings adapter: POST /v1/embeddings.
/// Works for OpenAI, LM Studio, OpenRouter, vLLM, and any other
/// server that implements the OpenAI embeddings endpoint.
/// </summary>
public sealed class OpenAIEmbeddingAdapter : IEmbeddingProducing
{
    private readonly HttpClient _http;
    private readonly string _baseUrl;
    private readonly string? _apiKey;

    public OpenAIEmbeddingAdapter(HttpClient http, string baseUrl, string? apiKey = null)
    {
        _http = http;
        _baseUrl = baseUrl.TrimEnd('/');
        _apiKey = apiKey;
    }

    public async Task<float[][]> EmbedAsync(
        string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
    {
        var body = new { model, input = inputs };
        var json = JsonSerializer.Serialize(body);

        using var req = new HttpRequestMessage(HttpMethod.Post, $"{_baseUrl}/v1/embeddings")
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json")
        };
        if (!string.IsNullOrEmpty(_apiKey))
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);

        using var resp = await _http.SendAsync(req, ct);

        if (resp.StatusCode == HttpStatusCode.Unauthorized)
            throw new ProviderAuthException("Invalid API key (401).");
        if (!resp.IsSuccessStatusCode)
            throw new ProviderException($"Embedding request failed: HTTP {(int)resp.StatusCode}.");

        var respJson = await resp.Content.ReadAsStringAsync(ct);
        var root = JsonSerializer.Deserialize<JsonElement>(respJson);
        if (!root.TryGetProperty("data", out var data))
            throw new ProviderException("Embedding response missing 'data' field.");

        var items = data.EnumerateArray().ToList();
        var result = new float[items.Count][];
        for (var i = 0; i < items.Count; i++)
        {
            if (!items[i].TryGetProperty("embedding", out var embProp))
                throw new ProviderException("Embedding response missing 'embedding' field.");
            var values = embProp.EnumerateArray().Select(v => v.GetSingle()).ToArray();
            result[i] = values;
        }
        return result;
    }
}

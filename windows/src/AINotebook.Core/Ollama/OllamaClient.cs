using System.Net.Http.Json;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;

namespace AINotebook.Core.Ollama;

public sealed class OllamaClient
{
    private readonly HttpClient _http;
    private static readonly JsonSerializerOptions Json = OllamaJson.Options;

    public Uri BaseUrl { get; }

    public OllamaClient(HttpClient? http = null, Uri? baseUrl = null)
    {
        BaseUrl = baseUrl ?? new Uri("http://127.0.0.1:11434");
        _http = http ?? new HttpClient();
        if (_http.BaseAddress is null) _http.BaseAddress = BaseUrl;
    }

    /// Best-effort 1.5s probe of /api/tags. true iff a 2xx response arrives.
    public async Task<bool> DetectAsync(TimeSpan? timeout = null, CancellationToken ct = default)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout ?? TimeSpan.FromSeconds(1.5));
        try
        {
            using var resp = await _http.GetAsync("api/tags", HttpCompletionOption.ResponseHeadersRead, cts.Token);
            return resp.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }

    public async Task<IReadOnlyList<OllamaModel>> ListModelsAsync(CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, "api/tags");
        using var resp = await SendAsync(req, ct);
        var body = await resp.Content.ReadAsStringAsync(ct);
        EnsureSuccess(resp, body);
        try
        {
            return JsonSerializer.Deserialize<OllamaModelList>(body, Json)!.Models;
        }
        catch (Exception e)
        {
            throw new OllamaException.Decoding(e.ToString());
        }
    }

    public async Task<double[][]> EmbedAsync(string model, IReadOnlyList<string> input, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, "api/embed")
        {
            Content = JsonContent.Create(new OllamaEmbedRequest(model, input), options: Json),
        };
        using var resp = await SendAsync(req, ct);
        var body = await resp.Content.ReadAsStringAsync(ct);
        EnsureSuccess(resp, body);
        try
        {
            return JsonSerializer.Deserialize<OllamaEmbedResponse>(body, Json)!.Embeddings;
        }
        catch (Exception e)
        {
            throw new OllamaException.Decoding(e.ToString());
        }
    }

    public async Task DeleteModelAsync(string name, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Delete, "api/delete")
        {
            // Compact, key-ordered exactly as Swift's ["name": name] encode.
            Content = new StringContent($$"""{"name":"{{name}}"}""", Encoding.UTF8, "application/json"),
        };
        HttpResponseMessage resp;
        try
        {
            resp = await _http.SendAsync(req, ct);
        }
        catch (Exception)
        {
            // deleteModel maps a missing/failed response to httpStatus(0,"").
            throw new OllamaException.HttpStatus(0, "");
        }
        using (resp)
        {
            if (!resp.IsSuccessStatusCode)
            {
                var body = await resp.Content.ReadAsStringAsync(ct);
                throw new OllamaException.HttpStatus((int)resp.StatusCode, body);
            }
        }
    }

    public IAsyncEnumerable<OllamaChatChunk> ChatAsync(
        string model,
        IReadOnlyList<OllamaChatMessage> messages,
        OllamaChatOptions? options = null,
        CancellationToken ct = default)
    {
        var payload = new OllamaChatRequest(model, messages, Stream: true, options);
        return StreamNdjsonAsync<OllamaChatChunk>("api/chat", payload, c => c.Done, ct);
    }

    public IAsyncEnumerable<OllamaPullEvent> PullModelAsync(string name, CancellationToken ct = default)
    {
        var payload = new { name };
        return StreamNdjsonAsync<OllamaPullEvent>("api/pull", payload, e => e.IsTerminalSuccess, ct);
    }

    private async IAsyncEnumerable<T> StreamNdjsonAsync<T>(
        string path,
        object payload,
        Func<T, bool> isTerminal,
        [EnumeratorCancellation] CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, path)
        {
            Content = JsonContent.Create(payload, options: Json),
        };

        HttpResponseMessage resp;
        try
        {
            resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new OllamaException.Timeout();
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new OllamaException.NotReachable();
        }

        using (resp)
        {
            if (!resp.IsSuccessStatusCode)
            {
                // Capture up to 10000 bytes of the error body.
                await using var es = await resp.Content.ReadAsStreamAsync(ct);
                var buf = new byte[10_000];
                var total = 0;
                while (total < buf.Length)
                {
                    var read = await es.ReadAsync(buf.AsMemory(total, buf.Length - total), ct);
                    if (read == 0) break;
                    total += read;
                }
                throw new OllamaException.HttpStatus(
                    (int)resp.StatusCode,
                    Encoding.UTF8.GetString(buf, 0, total));
            }

            await using var stream = await resp.Content.ReadAsStreamAsync(ct);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            while (true)
            {
                string? line;
                try
                {
                    line = await reader.ReadLineAsync(ct);
                }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested)
                {
                    throw new OllamaException.Timeout();
                }
                if (line is null) yield break;        // stream ended w/o terminal: finish cleanly
                if (line.Length == 0) continue;        // skip blank lines

                T value;
                try
                {
                    value = JsonSerializer.Deserialize<T>(line, Json)!;
                }
                catch (Exception e)
                {
                    throw new OllamaException.Decoding(e.ToString());
                }
                yield return value;
                if (isTerminal(value)) yield break;
            }
        }
    }

    private async Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct)
    {
        try
        {
            return await _http.SendAsync(req, ct);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new OllamaException.Timeout();
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new OllamaException.NotReachable();
        }
    }

    private static void EnsureSuccess(HttpResponseMessage resp, string body)
    {
        if (!resp.IsSuccessStatusCode)
            throw new OllamaException.HttpStatus((int)resp.StatusCode, body);
    }
}

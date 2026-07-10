using System.Net;
using System.Net.Http.Headers;
using System.Text;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using Xunit;

namespace AINotebook.Core.Tests.Providers;

public class OpenWebUISseTests
{
    private static HttpClient MakeClient(string body, HttpStatusCode status = HttpStatusCode.OK)
        => new(new StubHandler(status, body));

    private static string SseBody(params string[] jsonLines) =>
        string.Join("\n", jsonLines.Select(j => $"data: {j}")) + "\n";

    // ── Streaming ────────────────────────────────────────────────────────────

    [Fact]
    public async Task Streams_delta_content_tokens()
    {
        var sse = SseBody(
            """{"choices":[{"delta":{"content":"Hello"},"index":0}]}""",
            """{"choices":[{"delta":{"content":", LAN"},"index":0}]}""",
            "[DONE]");
        var adapter = new OpenWebUIChatAdapter(MakeClient(sse), "http://192.168.1.50:3000", "sk-key");
        var tokens = new List<string>();
        await foreach (var t in adapter.StreamAsync("llama3.2", [new ChatTurn(ChatRole.User, "hi")]))
            tokens.Add(t);
        Assert.Equal(["Hello", ", LAN"], tokens);
    }

    [Fact]
    public async Task Posts_to_api_chat_completions_not_v1()
    {
        Uri? uri = null;
        var handler = new CapturingHandler(HttpStatusCode.OK, "data: [DONE]\n",
            (u, _, _) => uri = u);
        var adapter = new OpenWebUIChatAdapter(new HttpClient(handler), "http://host:3000/", "k");
        await foreach (var _ in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")])) { }
        Assert.Equal("http://host:3000/api/chat/completions", uri!.ToString());
    }

    [Fact]
    public async Task Request_body_carries_model_messages_and_stream_flag()
    {
        string? body = null;
        var handler = new CapturingHandler(HttpStatusCode.OK, "data: [DONE]\n",
            (_, b, _) => body = b);
        var adapter = new OpenWebUIChatAdapter(new HttpClient(handler), "http://host:3000", "k");
        var turns = new[]
        {
            new ChatTurn(ChatRole.System, "Be concise."),
            new ChatTurn(ChatRole.User, "Hello")
        };
        await foreach (var _ in adapter.StreamAsync("llama3.2", turns)) { }
        Assert.NotNull(body);
        Assert.Contains("\"model\":\"llama3.2\"", body!);
        Assert.Contains("\"role\":\"system\"", body!);
        Assert.Contains("\"stream\":true", body!);
    }

    [Fact]
    public async Task Sends_bearer_header_when_key_present()
    {
        HttpRequestHeaders? headers = null;
        var handler = new CapturingHandler(HttpStatusCode.OK, "data: [DONE]\n",
            (_, _, h) => headers = h);
        var adapter = new OpenWebUIChatAdapter(new HttpClient(handler), "http://host:3000", "sk-abc");
        await foreach (var _ in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")])) { }
        Assert.Equal("Bearer", headers!.Authorization!.Scheme);
        Assert.Equal("sk-abc", headers.Authorization.Parameter);
    }

    [Fact]
    public async Task Omits_auth_header_when_key_missing()
    {
        HttpRequestHeaders? headers = null;
        var handler = new CapturingHandler(HttpStatusCode.OK, "data: [DONE]\n",
            (_, _, h) => headers = h);
        var adapter = new OpenWebUIChatAdapter(new HttpClient(handler), "http://host:3000", null);
        await foreach (var _ in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")])) { }
        Assert.Null(headers!.Authorization);
    }

    [Fact]
    public async Task Stops_on_DONE_sentinel()
    {
        var sse =
            """data: {"choices":[{"delta":{"content":"A"},"index":0}]}""" + "\n" +
            "data: [DONE]\n" +
            """data: {"choices":[{"delta":{"content":"SHOULD_NOT_APPEAR"},"index":0}]}""" + "\n";
        var adapter = new OpenWebUIChatAdapter(MakeClient(sse), "http://host:3000", "k");
        var tokens = new List<string>();
        await foreach (var t in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")]))
            tokens.Add(t);
        Assert.Equal(["A"], tokens);
    }

    [Fact]
    public async Task Skips_malformed_json_lines()
    {
        var sse =
            "data: not-json\n" +
            """data: {"choices":[{"delta":{"content":"ok"},"index":0}]}""" + "\n" +
            "data: [DONE]\n";
        var adapter = new OpenWebUIChatAdapter(MakeClient(sse), "http://host:3000", "k");
        var tokens = new List<string>();
        await foreach (var t in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")]))
            tokens.Add(t);
        Assert.Equal(["ok"], tokens);
    }

    [Fact]
    public async Task Throws_ProviderAuthException_on_401()
    {
        var adapter = new OpenWebUIChatAdapter(MakeClient("", HttpStatusCode.Unauthorized),
            "http://host:3000", "bad-key");
        await Assert.ThrowsAsync<ProviderAuthException>(async () =>
        {
            await foreach (var _ in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")])) { }
        });
    }

    [Fact]
    public async Task Throws_ProviderRateLimitException_on_429()
    {
        var adapter = new OpenWebUIChatAdapter(MakeClient("", (HttpStatusCode)429),
            "http://host:3000", "k");
        await Assert.ThrowsAsync<ProviderRateLimitException>(async () =>
        {
            await foreach (var _ in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")])) { }
        });
    }

    // ── Model listing ────────────────────────────────────────────────────────

    [Fact]
    public async Task Lists_models_from_api_models_with_display_names()
    {
        Uri? uri = null;
        var handler = new CapturingHandler(HttpStatusCode.OK,
            """{"data":[{"id":"gpt-4o","name":"GPT-4o (cloud)"},{"id":"llama3.2","name":"Llama 3.2"}]}""",
            (u, _, _) => uri = u);
        var models = await OpenWebUIChatAdapter.ListModelsAsync(
            new HttpClient(handler), "http://host:3000/", "k");
        Assert.Equal("http://host:3000/api/models", uri!.ToString());
        Assert.Equal(2, models.Count);
        Assert.Contains(models, m => m.Id == "llama3.2" && m.DisplayName == "Llama 3.2");
        Assert.Contains(models, m => m.Id == "gpt-4o" && m.DisplayName == "GPT-4o (cloud)");
    }

    [Fact]
    public async Task ListModels_throws_auth_exception_on_401()
    {
        await Assert.ThrowsAsync<ProviderAuthException>(() =>
            OpenWebUIChatAdapter.ListModelsAsync(
                MakeClient("", HttpStatusCode.Unauthorized), "http://host:3000", "bad"));
    }

    [Fact]
    public async Task ListModels_throws_ProviderException_on_server_error()
    {
        // Behavior change (macOS parity, shared OpenAIStyleWire helper): the
        // old adapter-local code swallowed any non-401 non-success status to
        // an empty list. The shared helper throws on ANY failure so Test
        // connection can no longer report a false "success" with zero models.
        await Assert.ThrowsAsync<ProviderException>(() =>
            OpenWebUIChatAdapter.ListModelsAsync(
                MakeClient("", HttpStatusCode.InternalServerError), "http://host:3000", "k"));
    }

    [Fact]
    public async Task ListModels_propagates_network_errors()
    {
        var http = new HttpClient(new ThrowingHandler());
        await Assert.ThrowsAsync<HttpRequestException>(() =>
            OpenWebUIChatAdapter.ListModelsAsync(http, "http://host:3000", "k"));
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private sealed class StubHandler(HttpStatusCode status, string body) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var resp = new HttpResponseMessage(status)
            {
                Content = new StringContent(body, Encoding.UTF8, "text/event-stream")
            };
            return Task.FromResult(resp);
        }
    }

    private sealed class CapturingHandler(
        HttpStatusCode status, string body,
        Action<Uri?, string, HttpRequestHeaders> capture) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var content = request.Content is not null ? await request.Content.ReadAsStringAsync(ct) : "";
            capture(request.RequestUri, content, request.Headers);
            return new HttpResponseMessage(status)
            {
                Content = new StringContent(body, Encoding.UTF8, "text/event-stream")
            };
        }
    }

    private sealed class ThrowingHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
            => throw new HttpRequestException("connection refused");
    }
}

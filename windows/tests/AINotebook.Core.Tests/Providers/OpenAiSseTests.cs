using System.Net;
using System.Text;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Ollama;
using Xunit;

namespace AINotebook.Core.Tests.Providers;

public class OpenAiSseTests
{
    private static HttpClient MakeClient(string sseBody, HttpStatusCode status = HttpStatusCode.OK)
    {
        var handler = new StubHandler(status, sseBody);
        return new HttpClient(handler);
    }

    private static string SseBody(params string[] jsonLines) =>
        string.Join("\n", jsonLines.Select(j => $"data: {j}")) + "\n";

    // ── Happy path ───────────────────────────────────────────────────────────

    [Fact]
    public async Task Streams_delta_content_tokens()
    {
        var sse = SseBody(
            """{"choices":[{"delta":{"content":"Hello"},"index":0}]}""",
            """{"choices":[{"delta":{"content":", world"},"index":0}]}""",
            "[DONE]");

        var adapter = new OpenAIChatAdapter(MakeClient(sse), "https://api.openai.com", "sk-key");
        var tokens = new List<string>();
        await foreach (var t in adapter.StreamAsync("gpt-4o", [new ChatTurn(ChatRole.User, "hi")]))
            tokens.Add(t);

        Assert.Equal(["Hello", ", world"], tokens);
    }

    [Fact]
    public async Task Stops_on_DONE_sentinel()
    {
        var sse =
            """data: {"choices":[{"delta":{"content":"A"},"index":0}]}""" + "\n" +
            "data: [DONE]\n" +
            """data: {"choices":[{"delta":{"content":"SHOULD_NOT_APPEAR"},"index":0}]}""" + "\n";

        var adapter = new OpenAIChatAdapter(MakeClient(sse), "https://api.openai.com", "sk-key");
        var tokens = new List<string>();
        await foreach (var t in adapter.StreamAsync("gpt-4o", [new ChatTurn(ChatRole.User, "hi")]))
            tokens.Add(t);

        Assert.Equal(["A"], tokens);
    }

    [Fact]
    public async Task System_turn_stays_in_messages_array()
    {
        string? capturedBody = null;
        var handler = new CapturingHandler(HttpStatusCode.OK,
            "data: [DONE]\n",
            b => capturedBody = b);

        var adapter = new OpenAIChatAdapter(new HttpClient(handler), "https://api.openai.com", "key");
        var turns = new[]
        {
            new ChatTurn(ChatRole.System, "Be concise."),
            new ChatTurn(ChatRole.User, "Hello")
        };
        await foreach (var _ in adapter.StreamAsync("gpt-4o", turns)) { }

        Assert.NotNull(capturedBody);
        Assert.Contains("\"role\":\"system\"", capturedBody!);
        Assert.Contains("Be concise.", capturedBody!);
    }

    [Fact]
    public async Task Streams_multiple_choices_delta()
    {
        // If multiple choices come back, all delta content should be yielded.
        var sse = SseBody(
            """{"choices":[{"delta":{"content":"A"},"index":0},{"delta":{"content":"B"},"index":1}]}""",
            "[DONE]");

        var adapter = new OpenAIChatAdapter(MakeClient(sse), "https://api.openai.com", "key");
        var tokens = new List<string>();
        await foreach (var t in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")]))
            tokens.Add(t);

        Assert.Equal(["A", "B"], tokens);
    }

    // ── Error cases ──────────────────────────────────────────────────────────

    [Fact]
    public async Task Throws_ProviderAuthException_on_401()
    {
        var adapter = new OpenAIChatAdapter(MakeClient("", HttpStatusCode.Unauthorized),
            "https://api.openai.com", "bad-key");
        await Assert.ThrowsAsync<ProviderAuthException>(async () =>
        {
            await foreach (var _ in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")])) { }
        });
    }

    [Fact]
    public async Task Throws_ProviderRateLimitException_on_429()
    {
        var adapter = new OpenAIChatAdapter(MakeClient("", (HttpStatusCode)429),
            "https://api.openai.com", "key");
        await Assert.ThrowsAsync<ProviderRateLimitException>(async () =>
        {
            await foreach (var _ in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")])) { }
        });
    }

    [Fact]
    public async Task Skips_malformed_json_lines()
    {
        var sse =
            "data: not-json\n" +
            """data: {"choices":[{"delta":{"content":"ok"},"index":0}]}""" + "\n" +
            "data: [DONE]\n";

        var adapter = new OpenAIChatAdapter(MakeClient(sse), "https://api.openai.com", "key");
        var tokens = new List<string>();
        await foreach (var t in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")]))
            tokens.Add(t);

        Assert.Equal(["ok"], tokens);
    }

    // ── Model listing (macOS parity: ListModels throws on ANY failure — the
    // shared OpenAIStyleWire helper never silently swallows to an empty list,
    // so Settings "Test connection" can no longer report a false success) ────

    [Fact]
    public async Task Lists_models_with_display_names()
    {
        var models = await OpenAIChatAdapter.ListModelsAsync(
            MakeClient("""{"data":[{"id":"gpt-4o","name":"GPT-4o"},{"id":"gpt-4o-mini"}]}"""),
            "https://api.openai.com", "sk-key");
        Assert.Equal(2, models.Count);
        Assert.Contains(models, m => m.Id == "gpt-4o" && m.DisplayName == "GPT-4o");
        Assert.Contains(models, m => m.Id == "gpt-4o-mini" && m.DisplayName == null);
    }

    [Fact]
    public async Task ListModels_throws_ProviderAuthException_on_401()
    {
        await Assert.ThrowsAsync<ProviderAuthException>(() =>
            OpenAIChatAdapter.ListModelsAsync(
                MakeClient("", HttpStatusCode.Unauthorized), "https://api.openai.com", "bad-key"));
    }

    [Fact]
    public async Task ListModels_throws_ProviderException_on_other_non_success()
    {
        await Assert.ThrowsAsync<ProviderException>(() =>
            OpenAIChatAdapter.ListModelsAsync(
                MakeClient("", HttpStatusCode.InternalServerError), "https://api.openai.com", "key"));
    }

    [Fact]
    public async Task ListModels_propagates_network_errors()
    {
        var http = new HttpClient(new ThrowingHandler());
        await Assert.ThrowsAsync<HttpRequestException>(() =>
            OpenAIChatAdapter.ListModelsAsync(http, "https://api.openai.com", "key"));
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
        HttpStatusCode status, string body, Action<string> capture) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var content = request.Content is not null ? await request.Content.ReadAsStringAsync(ct) : "";
            capture(content);
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

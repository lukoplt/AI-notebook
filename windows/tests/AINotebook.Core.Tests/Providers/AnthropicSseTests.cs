using System.Net;
using System.Text;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Ollama;
using Xunit;

namespace AINotebook.Core.Tests.Providers;

public class AnthropicSseTests
{
    // ── SSE helpers ──────────────────────────────────────────────────────────

    private static HttpClient MakeClient(string sseBody, HttpStatusCode status = HttpStatusCode.OK)
    {
        var handler = new StubHandler(status, sseBody);
        return new HttpClient(handler);
    }

    private static string SseBody(params string[] jsonLines) =>
        string.Join("\n", jsonLines.Select(j => $"data: {j}")) + "\n";

    // ── Happy path ───────────────────────────────────────────────────────────

    [Fact]
    public async Task Streams_text_delta_tokens()
    {
        var sse = SseBody(
            """{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}""",
            """{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world"}}""",
            """{"type":"message_stop"}""");

        var adapter = new AnthropicChatAdapter(MakeClient(sse), "https://api.anthropic.com", "key");
        var turns = new[] { new ChatTurn(ChatRole.User, "hi") };

        var tokens = new List<string>();
        await foreach (var t in adapter.StreamAsync("claude-opus-4-8", turns))
            tokens.Add(t);

        Assert.Equal(["Hello", ", world"], tokens);
    }

    [Fact]
    public async Task Stops_on_message_stop_event()
    {
        // Content after message_stop must be ignored.
        var sse = SseBody(
            """{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"A"}}""",
            """{"type":"message_stop"}""",
            """{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"SHOULD_NOT_APPEAR"}}""");

        var adapter = new AnthropicChatAdapter(MakeClient(sse), "https://api.anthropic.com", "key");
        var tokens = new List<string>();
        await foreach (var t in adapter.StreamAsync("claude-opus-4-8", [new ChatTurn(ChatRole.User, "hi")]))
            tokens.Add(t);

        Assert.Equal(["A"], tokens);
    }

    [Fact]
    public async Task Extracts_system_turn_into_top_level_system_field()
    {
        // The adapter must NOT include the system turn in the messages array.
        // We verify by checking that the request body is well-formed.
        string? capturedBody = null;
        var handler = new CapturingHandler(HttpStatusCode.OK,
            """data: {"type":"message_stop"}""" + "\n",
            b => capturedBody = b);
        var adapter = new AnthropicChatAdapter(new HttpClient(handler), "https://api.anthropic.com", "key");

        var turns = new[]
        {
            new ChatTurn(ChatRole.System, "Be helpful."),
            new ChatTurn(ChatRole.User, "Hello")
        };
        await foreach (var _ in adapter.StreamAsync("claude-opus-4-8", turns)) { }

        Assert.NotNull(capturedBody);
        Assert.Contains("\"system\":\"Be helpful.\"", capturedBody!);
        // System turn must NOT appear in "messages"
        Assert.DoesNotContain("\"role\":\"system\"", capturedBody!);
    }

    // ── Error cases ──────────────────────────────────────────────────────────

    [Fact]
    public async Task Throws_ProviderAuthException_on_401()
    {
        var adapter = new AnthropicChatAdapter(MakeClient("", HttpStatusCode.Unauthorized),
            "https://api.anthropic.com", "bad-key");
        await Assert.ThrowsAsync<ProviderAuthException>(async () =>
        {
            await foreach (var _ in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")])) { }
        });
    }

    [Fact]
    public async Task Throws_ProviderRateLimitException_on_429()
    {
        var adapter = new AnthropicChatAdapter(MakeClient("", (HttpStatusCode)429),
            "https://api.anthropic.com", "key");
        await Assert.ThrowsAsync<ProviderRateLimitException>(async () =>
        {
            await foreach (var _ in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")])) { }
        });
    }

    [Fact]
    public async Task Throws_ProviderRefusalException_on_refusal_stop_reason()
    {
        var sse = SseBody(
            """{"type":"message_delta","delta":{"stop_reason":"refusal"}}""");
        var adapter = new AnthropicChatAdapter(MakeClient(sse), "https://api.anthropic.com", "key");
        await Assert.ThrowsAsync<ProviderRefusalException>(async () =>
        {
            await foreach (var _ in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")])) { }
        });
    }

    [Fact]
    public async Task Skips_malformed_json_lines()
    {
        var sse =
            "data: not-json\n" +
            """data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}""" + "\n" +
            """data: {"type":"message_stop"}""" + "\n";

        var adapter = new AnthropicChatAdapter(MakeClient(sse), "https://api.anthropic.com", "key");
        var tokens = new List<string>();
        await foreach (var t in adapter.StreamAsync("m", [new ChatTurn(ChatRole.User, "hi")]))
            tokens.Add(t);

        Assert.Equal(["ok"], tokens);
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
}

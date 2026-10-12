using System.Net;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Ollama;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Providers;

public class AnthropicSseTests
{
    public static IEnumerable<object[]> DiscoveryFailures => SharedFixtures.Json("contracts/provider-probe-v1.json")
        .GetProperty("cases").EnumerateArray()
        .Where(c => c.GetProperty("type").GetString() == "anthropic" && c.GetProperty("expectedStatus").GetString() == "failed")
        .Select(c => new object[] { c.GetProperty("name").GetString()!, c.GetProperty("response").GetString()!, c.GetProperty("statusCode").GetInt32(), c.GetProperty("errorCode").GetString()! });

    [Theory]
    [MemberData(nameof(DiscoveryFailures))]
    public async Task Discovery_propagates_fixture_failures(string name, string response, int status, string errorCode)
    {
        var stub = new StubHttpMessageHandler();
        if (response == "transport") stub.ConnectionRefused();
        else stub.Json(response == "malformed" ? "{}" : "{\"error\":\"denied\"}", status);
        using var http = new HttpClient(stub);

        var error = await Assert.ThrowsAnyAsync<Exception>(() =>
            AnthropicChatAdapter.ListModelsAsync(http, "https://unit.example/proxy", "key"));

        switch (errorCode)
        {
            case "auth": Assert.IsType<ProviderAuthException>(error); break;
            case "http" when status == 429: Assert.IsType<ProviderRateLimitException>(error); break;
            case "http": Assert.Equal(status, Assert.IsType<ProviderHttpException>(error).StatusCode); break;
            case "decoding": Assert.IsType<JsonException>(error); break;
            case "transport": Assert.IsType<HttpRequestException>(error); break;
            default: Assert.Fail($"Unexpected fixture error: {name}"); break;
        }
        Assert.Single(stub.AllRequests);
        Assert.Equal(HttpMethod.Get, stub.LastRequest!.Method);
        Assert.Equal("https://unit.example/proxy/v1/models", stub.LastRequest.RequestUri!.AbsoluteUri);
    }

    [Theory]
    [InlineData("[]")]
    [InlineData("{\"data\":null}")]
    [InlineData("{\"data\":{}}")]
    [InlineData("{\"data\":[{}]}")]
    [InlineData("{\"data\":[{\"id\":7}]}")]
    [InlineData("{\"data\":[{\"id\":\"m\",\"display_name\":7}]}")]
    [InlineData("{\"data\":[{\"id\":\"\\uD800\"}]}")]
    public async Task Discovery_rejects_invalid_success_schemas(string body)
    {
        using var http = new HttpClient(new StubHttpMessageHandler().Json(body));
        await Assert.ThrowsAsync<JsonException>(() =>
            AnthropicChatAdapter.ListModelsAsync(http, "https://unit.example", "key"));
    }

    [Fact]
    public async Task Discovery_preserves_ids_labels_order_and_valid_empty_results()
    {
        using var http = new HttpClient(new StubHttpMessageHandler()
            .Json("{\"data\":[{\"id\":\"vendor/m:tag\",\"display_name\":\"Friendly\"},{\"id\":\"m2\"}]}")
            .Json("{\"data\":[]}"));
        var models = await AnthropicChatAdapter.ListModelsAsync(http, "https://unit.example", "key");
        Assert.Equal(new[] { new ProviderModelInfo("vendor/m:tag", "Friendly"), new ProviderModelInfo("m2", null) }, models);
        Assert.Empty(await AnthropicChatAdapter.ListModelsAsync(http, "https://unit.example", "key"));
    }

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
        Assert.Contains("\"max_tokens\":1024", capturedBody!);
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

using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Providers;

public class ProviderTransportContractTests
{
    [Fact]
    public async Task CustomOllamaRootWinsOverSharedClientBaseAddress()
    {
        var stub = new StubHttpMessageHandler().Json("""{"models":[]}""");
        using var http = new HttpClient(stub) { BaseAddress = new Uri("http://127.0.0.1:11434") };
        var client = new OllamaClient(http, new Uri("http://gpu-box:11434/proxy/ollama"));
        await client.ListModelsAsync();
        Assert.Equal("http://gpu-box:11434/proxy/ollama/api/tags", stub.LastRequest!.RequestUri!.AbsoluteUri);
        Assert.Equal("http://127.0.0.1:11434/", http.BaseAddress!.AbsoluteUri);
    }
    [Fact]
    public void ApiRootFixture()
    {
        foreach (var c in SharedFixtures.Json("contracts/api-root-v1.json").GetProperty("cases").EnumerateArray())
        {
            var type = ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!);
            var endpoint = Enum.Parse<ProviderEndpoint>(c.GetProperty("endpoint").GetString()!, true);
            Uri Build()
            {
                var root = c.GetProperty("baseURL").GetString()!;
                if (c.GetProperty("legacy").GetBoolean()) root = ProviderApiRoot.ConvertLegacy(type, root);
                return ProviderApiRoot.Build(type, root, endpoint);
            }
            if (c.TryGetProperty("expectedError", out var error))
                Assert.Equal(error.GetString(), Assert.Throws<ProviderConfigurationException>(() => Build()).Code);
            else Assert.Equal(c.GetProperty("expectedURL").GetString(), Build().AbsoluteUri);
        }
    }
    private static IChatStreaming Adapter(ProviderType type, string root, HttpClient http) => type switch
    {
        ProviderType.Ollama => new OllamaChatAdapter(new OllamaClient(http, new Uri(root))),
        ProviderType.Anthropic => new AnthropicChatAdapter(http, root, "k"),
        ProviderType.OpenWebUI => new OpenWebUIChatAdapter(http, root, "k"),
        _ => new OpenAIChatAdapter(http, root, "k")
    };
    private static string Finish(ProviderType type) => type switch
    {
        ProviderType.Ollama => "{\"model\":\"m\",\"created_at\":\"\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}\n",
        ProviderType.Anthropic => "data: {\"type\":\"message_stop\"}\n",
        _ => "data: [DONE]\n"
    };
    [Fact]
    public async Task OptionsReachEveryAdapter()
    {
        foreach (var c in SharedFixtures.Json("contracts/provider-options-v1.json").GetProperty("cases").EnumerateArray())
        {
            var type = ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!);
            var stub = new StubHttpMessageHandler().Json(Finish(type));
            using var http = new HttpClient(stub);
            var options = new ChatRequestOptions(c.GetProperty("runtimeContext").GetInt32(), c.GetProperty("maxOutputTokens").GetInt32());
            await foreach (var _ in Adapter(type, "https://unit.example/proxy/v1", http)
                .StreamAsync("m", [new(ChatRole.User, "Q")], options)) { }
            using var json = JsonDocument.Parse(stub.LastRequestBody!);
            var body = json.RootElement;
            var expected = c.GetProperty("expected");
            if (type == ProviderType.Ollama)
            {
                Assert.True(JsonElement.DeepEquals(expected.GetProperty("options"), body.GetProperty("options")));
                Assert.False(body.TryGetProperty("max_tokens", out _));
            }
            else
            {
                Assert.Equal(expected.GetProperty("max_tokens").GetInt32(), body.GetProperty("max_tokens").GetInt32());
                Assert.False(body.TryGetProperty("options", out _));
                Assert.False(body.TryGetProperty("num_ctx", out _));
                Assert.False(body.TryGetProperty("num_predict", out _));
            }
        }
    }
    [Fact]
    public async Task WireOrderAndMultipleSystems()
    {
        var rows = SharedFixtures.Json("contracts/wire-order-v1.json").GetProperty("cases").EnumerateArray()
            .Concat(SharedFixtures.Json("contracts/provider-systems-v1.json").GetProperty("cases").EnumerateArray());
        foreach (var c in rows)
        {
            var type = ProviderTypeExtensions.FromStorageString(c.GetProperty(c.TryGetProperty("provider", out _) ? "provider" : "type").GetString()!);
            var input = c.GetProperty("input");
            var turns = new List<ChatTurn>();
            if (input.ValueKind == JsonValueKind.Array)
                turns.AddRange(input.EnumerateArray().Select(x => new ChatTurn(Enum.Parse<ChatRole>(x.GetProperty("role").GetString()!, true), x.GetProperty("content").GetString()!)));
            else
            {
                turns.Add(new(ChatRole.System, input.GetProperty("rulesText").GetString()!));
                var instructions = input.GetProperty("userInstructions").GetString()!;
                if (!string.IsNullOrWhiteSpace(instructions)) turns.Add(new(ChatRole.System, instructions));
                turns.AddRange(input.GetProperty("history").EnumerateArray().Select(x => new ChatTurn(Enum.Parse<ChatRole>(x.GetProperty("role").GetString()!, true), x.GetProperty("content").GetString()!)));
                turns.Add(new(ChatRole.User, input.GetProperty("finalUserContent").GetString()!));
            }
            var stub = new StubHttpMessageHandler().Json(Finish(type));
            using var http = new HttpClient(stub);
            await foreach (var _ in Adapter(type, "https://unit.example/root", http).StreamAsync("m", turns)) { }
            using var json = JsonDocument.Parse(stub.LastRequestBody!);
            var expected = c.GetProperty("expected");
            Assert.True(JsonElement.DeepEquals(expected.GetProperty("messages"), json.RootElement.GetProperty("messages")), c.GetProperty("name").GetString());
            if (expected.TryGetProperty("system", out var system))
                Assert.Equal(system.GetString(), json.RootElement.GetProperty("system").GetString());
            else Assert.False(json.RootElement.TryGetProperty("system", out _));
        }
    }

    [Fact]
    public async Task FixtureUrlsAtHttpBoundary()
    {
        foreach (var c in SharedFixtures.Json("contracts/api-root-v1.json").GetProperty("cases").EnumerateArray())
        {
            if (!c.TryGetProperty("expectedURL", out var expected)) continue;
            var type = ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!);
            var root = c.GetProperty("baseURL").GetString()!;
            if (c.GetProperty("legacy").GetBoolean()) root = ProviderApiRoot.ConvertLegacy(type, root);
            var endpoint = Enum.Parse<ProviderEndpoint>(c.GetProperty("endpoint").GetString()!, true);
            var body = endpoint switch
            {
                ProviderEndpoint.Chat => Finish(type),
                ProviderEndpoint.Models => type == ProviderType.Ollama ? "{\"models\":[]}" : "{\"data\":[]}",
                _ => type == ProviderType.Ollama ? "{\"embeddings\":[[1,0]]}" : "{\"data\":[{\"embedding\":[1,0]}]}"
            };
            var stub = new StubHttpMessageHandler().Json(body);
            using var http = new HttpClient(stub) { BaseAddress = new Uri("https://wrong.example/") };
            switch (endpoint)
            {
                case ProviderEndpoint.Chat:
                    await foreach (var _ in Adapter(type, root, http).StreamAsync("m", [new(ChatRole.User, "Q")])) { }
                    break;
                case ProviderEndpoint.Models:
                    switch (type)
                    {
                        case ProviderType.Ollama: await new OllamaClient(http, new Uri(root)).ListModelsAsync(); break;
                        case ProviderType.Anthropic: await AnthropicChatAdapter.ListModelsAsync(http, root, "k"); break;
                        case ProviderType.OpenWebUI: await OpenWebUIChatAdapter.ListModelsAsync(http, root, "k"); break;
                        default: await OpenAIChatAdapter.ListModelsAsync(http, root, "k"); break;
                    }
                    break;
                case ProviderEndpoint.Embeddings:
                    if (type == ProviderType.Ollama) await new OllamaClient(http, new Uri(root)).EmbedAsync("m", ["x"]);
                    else await new OpenAIEmbeddingAdapter(http, root, "k").EmbedAsync("m", ["x"]);
                    break;
            }
            Assert.Single(stub.AllRequests);
            Assert.Equal(expected.GetString(), stub.LastRequest!.RequestUri!.AbsoluteUri);
        }
    }

    [Fact]
    public async Task InvalidFixtureRootsAndUnsupportedEndpointsSendNoRequests()
    {
        foreach (var c in SharedFixtures.Json("contracts/api-root-v1.json").GetProperty("cases").EnumerateArray())
        {
            if (!c.TryGetProperty("expectedError", out var expected)) continue;
            var type = ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!);
            var stub = new StubHttpMessageHandler();
            using var http = new HttpClient(stub);
            var error = await Assert.ThrowsAsync<ProviderConfigurationException>(async () =>
            {
                var root = c.GetProperty("baseURL").GetString()!;
                if (c.GetProperty("legacy").GetBoolean()) root = ProviderApiRoot.ConvertLegacy(type, root);
                var endpoint = Enum.Parse<ProviderEndpoint>(c.GetProperty("endpoint").GetString()!, true);
                if (endpoint == ProviderEndpoint.Chat)
                    await Drain(Adapter(type, root, http));
                else
                    ProviderApiRoot.Build(type, root, endpoint);
            });
            Assert.Equal(expected.GetString(), error.Code);
            Assert.Empty(stub.AllRequests);
        }
    }

    [Fact]
    public async Task InvalidOptionsSendNoRequests()
    {
        var invalid = SharedFixtures.Json("contracts/provider-limits-v1.json").GetProperty("cases")
            .EnumerateArray().Where(c => c.TryGetProperty("user", out _))
            .Select(c => c.GetProperty("user"))
            .Select(u => new ChatRequestOptions(u.GetProperty("runtimeContext").GetInt32(), u.GetProperty("maxOutputTokens").GetInt32()))
            .Where(o => o.RuntimeContext <= 0 || o.MaxOutputTokens <= 0 || o.MaxOutputTokens >= o.RuntimeContext)
            .Concat([new(-1, 1), new(4096, -1), new(4096, 4097)]);
        foreach (var type in Enum.GetValues<ProviderType>())
        foreach (var options in invalid)
        {
            var stub = new StubHttpMessageHandler();
            using var http = new HttpClient(stub);
            var error = await Assert.ThrowsAsync<ProviderConfigurationException>(async () =>
            {
                await foreach (var _ in Adapter(type, "https://unit.example/root", http)
                    .StreamAsync("m", [new(ChatRole.User, "Q")], options)) { }
            });
            Assert.Equal("invalidLimits", error.Code);
            Assert.Empty(stub.AllRequests);
        }
    }

    [Fact]
    public async Task InvalidRootsAlsoBlockDiscoveryAndEmbeddingTransports()
    {
        var invalid = SharedFixtures.Json("contracts/api-root-v1.json").GetProperty("cases")
            .EnumerateArray().Where(c => c.TryGetProperty("expectedError", out var error) &&
                error.GetString() == "invalidBaseURL");
        foreach (var c in invalid)
        {
            var root = c.GetProperty("baseURL").GetString()!;
            var stub = new StubHttpMessageHandler();
            using var http = new HttpClient(stub);
            var calls = new Func<Task>[]
            {
                () => OpenAIChatAdapter.ListModelsAsync(http, root, "k"),
                () => OpenWebUIChatAdapter.ListModelsAsync(http, root, "k"),
                () => AnthropicChatAdapter.ListModelsAsync(http, root, "k"),
                () => new OpenAIEmbeddingAdapter(http, root, "k").EmbedAsync("m", ["x"])
            };
            foreach (var call in calls)
                Assert.Equal("invalidBaseURL", (await Assert.ThrowsAsync<ProviderConfigurationException>(call)).Code);
            foreach (var type in new[] { ProviderType.Anthropic, ProviderType.OpenWebUI })
                Assert.Equal("invalidBaseURL", Assert.Throws<ProviderConfigurationException>(() =>
                    ProviderApiRoot.Build(type, root, ProviderEndpoint.Embeddings)).Code);
            Assert.Empty(stub.AllRequests);
        }
    }

    [Fact]
    public async Task OllamaValidatesOriginalAuthorityBeforeEveryOperation()
    {
        // Uri itself repairs this fixture host to 127.0.0.1; validation must use OriginalString.
        var c = SharedFixtures.Json("contracts/api-root-v1.json").GetProperty("cases")
            .EnumerateArray().Single(c => c.GetProperty("name").GetString() == "openai_compatible-chat-62");
        var stub = new StubHttpMessageHandler();
        using var http = new HttpClient(stub);
        var client = new OllamaClient(http, new Uri(c.GetProperty("baseURL").GetString()!));
        var calls = new Func<Task>[]
        {
            () => client.DetectAsync(), () => client.ListModelsAsync(),
            () => client.EmbedAsync("m", ["x"]), () => client.ShowAsync("m"),
            () => client.DeleteModelAsync("m"), () => Drain(new OllamaChatAdapter(client)),
            async () => { await foreach (var _ in client.PullModelAsync("m")) { } }
        };
        foreach (var call in calls)
            Assert.Equal("invalidBaseURL", (await Assert.ThrowsAsync<ProviderConfigurationException>(call)).Code);
        Assert.Empty(stub.AllRequests);
        Assert.Null(http.BaseAddress);
    }

    [Fact]
    public async Task LegacyOverloadsSendContractDefaults()
    {
        var expected = SharedFixtures.Json("contracts/constants-v1.json").GetProperty("providers");
        Assert.Equal(expected.GetProperty("defaultRuntimeContext").GetInt32(), ChatRequestOptions.Defaults.RuntimeContext);
        Assert.Equal(expected.GetProperty("defaultMaxOutputTokens").GetInt32(), ChatRequestOptions.Defaults.MaxOutputTokens);
        foreach (var type in Enum.GetValues<ProviderType>())
        {
            var stub = new StubHttpMessageHandler().Json(Finish(type));
            using var http = new HttpClient(stub);
            await Drain(Adapter(type, "https://unit.example/root", http));
            using var document = JsonDocument.Parse(stub.LastRequestBody!);
            var body = document.RootElement;
            if (type == ProviderType.Ollama)
            {
                Assert.Equal(ChatRequestOptions.Defaults.RuntimeContext, body.GetProperty("options").GetProperty("num_ctx").GetInt32());
                Assert.Equal(ChatRequestOptions.Defaults.MaxOutputTokens, body.GetProperty("options").GetProperty("num_predict").GetInt32());
            }
            else Assert.Equal(ChatRequestOptions.Defaults.MaxOutputTokens, body.GetProperty("max_tokens").GetInt32());
        }
    }

    [Fact]
    public async Task LengthErrorsUseSharedFixtures()
    {
        foreach (var c in SharedFixtures.Json("contracts/provider-errors-v1.json").GetProperty("cases").EnumerateArray())
        {
            var type = ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!);
            var status = c.GetProperty("statusCode").GetInt32();
            var stub = new StubHttpMessageHandler().Json(c.GetProperty("body").GetRawText(), status);
            using var http = new HttpClient(stub);
            var tokens = new List<string>();
            var error = await Record.ExceptionAsync(async () =>
            {
                await foreach (var token in Adapter(type, "https://unit.example/root", http)
                    .StreamAsync("m", [new(ChatRole.User, "Q")])) tokens.Add(token);
            });
            if (c.GetProperty("expectedError").GetString() == "contextTooLong")
                Assert.IsType<ProviderContextTooLongException>(error);
            else Assert.Equal(status, Assert.IsType<ProviderHttpException>(error).StatusCode);
            Assert.Single(stub.AllRequests);
            Assert.Empty(tokens);
        }
    }

    [Fact]
    public async Task MalformedErrorBodiesRemainHttpErrors()
    {
        foreach (var type in Enum.GetValues<ProviderType>())
        foreach (var body in new[]
        {
            "not json", "[]", "null", "{\"error\":null}", "{\"error\":[]}", "{\"error\":{\"code\":3}}",
            """{"error":{"code":"\ud800"}}""",
            """{"error":{"type":"\ud800","message":"prompt is too long"}}""",
            """{"error":{"type":"invalid_request_error","message":"\ud800"}}"""
        })
        {
            var stub = new StubHttpMessageHandler().Json(body, 400);
            using var http = new HttpClient(stub);
            var error = await Assert.ThrowsAsync<ProviderHttpException>(() => Drain(Adapter(type, "https://unit.example/root", http)));
            Assert.Equal(400, error.StatusCode);
            Assert.Single(stub.AllRequests);
        }
    }

    [Fact]
    public async Task MalformedModelListsFailAndEmptyListsSucceed()
    {
        foreach (var type in new[] { ProviderType.OpenAI, ProviderType.OpenAICompatible, ProviderType.OpenWebUI, ProviderType.Ollama })
        {
            var field = type == ProviderType.Ollama ? "models" : "data";
            var id = type == ProviderType.Ollama ? "name" : "id";
            var bodies = new[] { "{}", "null", "[]", $"{{\"{field}\":null}}", $"{{\"{field}\":{{}}}}",
                $"{{\"{field}\":[{{}}]}}", $"{{\"{field}\":[null]}}", $"{{\"{field}\":[{{\"{id}\":null}}]}}",
                $"{{\"{field}\":[{{\"{id}\":12}}]}}",
                $$"""{"{{field}}":[{"{{id}}":"\ud800"}]}""" };
            foreach (var body in bodies)
            {
                var stub = new StubHttpMessageHandler().Json(body);
                using var http = new HttpClient(stub);
                var error = await Record.ExceptionAsync(() => ListModels(type, http));
                if (type == ProviderType.Ollama) Assert.IsType<OllamaException.Decoding>(error);
                else Assert.IsType<JsonException>(error);
                Assert.Single(stub.AllRequests);
            }
            var empty = new StubHttpMessageHandler().Json($"{{\"{field}\":[]}}");
            using var emptyHttp = new HttpClient(empty);
            await ListModels(type, emptyHttp);
            Assert.Single(empty.AllRequests);
        }
    }

    private static async Task ListModels(ProviderType type, HttpClient http)
    {
        const string root = "https://unit.example/root";
        if (type == ProviderType.Ollama) Assert.Empty(await new OllamaClient(http, new Uri(root)).ListModelsAsync());
        else if (type == ProviderType.OpenWebUI) Assert.Empty(await OpenWebUIChatAdapter.ListModelsAsync(http, root, "k"));
        else Assert.Empty(await OpenAIChatAdapter.ListModelsAsync(http, root, "k"));
    }

    [Fact]
    public async Task EveryOllamaEndpointRetainsProxyRootWithoutMutatingBaseAddress()
    {
        var c = SharedFixtures.Json("contracts/provider-routing-v1.json").GetProperty("cases").EnumerateArray()
            .Single(x => x.GetProperty("operation").GetString() == "ollamaEndpoints");
        var root = c.GetProperty("root").GetString()!;
        var stub = new StubHttpMessageHandler().Json("{\"models\":[]}").Json("{\"models\":[]}")
            .Json("{\"embeddings\":[[1,0]]}").Json(Finish(ProviderType.Ollama))
            .Json("{\"model_info\":{}}").Json("").Json("{\"status\":\"success\"}\n");
        using var http = new HttpClient(stub);
        var client = new OllamaClient(http, new Uri(root));
        Assert.True(await client.DetectAsync());
        await client.ListModelsAsync();
        await client.EmbedAsync("m:tag", ["x"]);
        await Drain(new OllamaChatAdapter(client));
        Assert.Equal("{\"model_info\":{}}", await client.ShowAsync("m:tag"));
        Assert.Equal(HttpMethod.Post, stub.LastRequest!.Method);
        using (var body = JsonDocument.Parse(stub.LastRequestBody!))
            Assert.Equal("m:tag", body.RootElement.GetProperty("model").GetString());
        await client.DeleteModelAsync("m:tag");
        await foreach (var _ in client.PullModelAsync("m:tag")) { }
        Assert.Null(http.BaseAddress);
        Assert.Equal(new[] { "api/tags", "api/tags", "api/embed", "api/chat", "api/show", "api/delete", "api/pull" }
            .Select(path => root + "/" + path), stub.AllRequests.Select(r => r.RequestUri!.AbsoluteUri));
    }

    [Fact]
    public async Task ShowValidatesResponseAndPreservesHttpStatus()
    {
        var badJson = new StubHttpMessageHandler().Json("not json");
        using var http = new HttpClient(badJson);
        await Assert.ThrowsAsync<OllamaException.Decoding>(() => new OllamaClient(http).ShowAsync("m"));
        var unsupported = new StubHttpMessageHandler().Json("{}", 404);
        using var otherHttp = new HttpClient(unsupported);
        var error = await Assert.ThrowsAsync<OllamaException.HttpStatus>(() => new OllamaClient(otherHttp).ShowAsync("m"));
        Assert.Equal(404, error.Code);
    }

    private static async Task Drain(IChatStreaming adapter)
    {
        await foreach (var _ in adapter.StreamAsync("m", [new(ChatRole.User, "Q")])) { }
    }

    [Theory]
    [InlineData("https://unit.example/proxy%2Fteam/%7euser/v1")]
    [InlineData("https://unit.example/proxy/a/../v1")]
    public async Task NormalizationAndDispatchPreserveProxyPath(string root)
    {
        Assert.Equal(root, ProviderApiRoot.Normalize("\u00a0" + root + "///\u00a0"));
        var stub = new StubHttpMessageHandler().Json("data: [DONE]\n");
        using var http = new HttpClient(stub);
        await Drain(new OpenAIChatAdapter(http, root, "k"));
        Assert.Single(stub.AllRequests);
        Assert.Equal(root + "/chat/completions", stub.LastRequest!.RequestUri!.AbsoluteUri);
    }

    [Fact]
    public async Task ChatErrorBodyReadsAreBounded()
    {
        foreach (var type in Enum.GetValues<ProviderType>())
        {
            var body = "{\"padding\":\"" + new string('x', 70_000) +
                "\",\"error\":{\"code\":\"context_length_exceeded\"}}";
            using var stream = new CountingStream(System.Text.Encoding.UTF8.GetBytes(body));
            using var http = new HttpClient(new StreamHandler(stream));
            var error = await Assert.ThrowsAsync<ProviderHttpException>(() =>
                Drain(Adapter(type, "https://unit.example/root", http)));
            Assert.Equal(400, error.StatusCode);
            Assert.Equal(65_536, stream.BytesRead);
        }
    }

    private sealed class CountingStream(byte[] bytes) : MemoryStream(bytes)
    {
        public int BytesRead { get; private set; }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
        {
            var count = await base.ReadAsync(buffer, ct);
            BytesRead += count;
            return count;
        }
    }

    private sealed class StreamHandler(Stream stream) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.BadRequest)
            {
                Content = new StreamContent(stream)
            });
    }
}

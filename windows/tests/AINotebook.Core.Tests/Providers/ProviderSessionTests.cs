using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

using ProviderRouter = AINotebook.Core.Providers.Routing.ProviderRouter;

namespace AINotebook.Core.Tests.Providers;

public class ProviderSessionTests
{
    [Fact]
    public async Task ProbeFixture()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        foreach (var c in SharedFixtures.Json("contracts/provider-probe-v1.json").GetProperty("cases").EnumerateArray())
        {
            var type = ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!);
            var response = c.GetProperty("response").GetString();
            var stub = new StubHttpMessageHandler();
            if (response == "transport") stub.ConnectionRefused();
            else
            {
                var body = response switch
                {
                    "validEmpty" => type == ProviderType.Ollama ? "{\"models\":[]}" : "{\"data\":[]}",
                    "validOne" => type == ProviderType.Ollama ? "{\"models\":[{\"name\":\"m:tag\",\"modified_at\":\"\",\"size\":0,\"digest\":\"d\",\"details\":{}}]}" : "{\"data\":[{\"id\":\"m:tag\"}]}",
                    "malformed" => "{}",
                    _ => "{\"error\":\"denied\"}"
                };
                stub.Json(body, c.GetProperty("statusCode").GetInt32());
            }
            using var http = new HttpClient(stub);
            var router = new ProviderRouter(store, () => ("p", "m"), () => ("p", "m"), _ => "k", http);
            var result = await router.ProbeAsync(type, "https://unit.example/root", "k");
            Assert.Equal(Enum.Parse<ProviderProbeStatus>(c.GetProperty("expectedStatus").GetString()!, true), result.Status);
            Assert.Equal(c.GetProperty("errorCode").ValueKind == JsonValueKind.Null ? null : c.GetProperty("errorCode").GetString(), result.ErrorCode);
            Assert.False(result.GenerationVerified);
            Assert.Single(stub.AllRequests);
            Assert.Equal(HttpMethod.Get, stub.LastRequest!.Method);
        }
    }
    [Fact]
    public async Task EqualLengthKeyRotationDoesNotReuseAnOldAdapter()
    {
        var c = SharedFixtures.Json("contracts/provider-routing-v1.json").GetProperty("cases").EnumerateArray()
            .Single(x => x.GetProperty("operation").GetString() == "snapshot");
        using var store = new NotebookStore(StorePath.InMemory);
        var config = new ProviderConfig("p", ProviderType.OpenAICompatible, "P", c.GetProperty("oldRoot").GetString()!, true, true, DateTime.UtcNow);
        store.SaveProvider(config);
        var key = c.GetProperty("oldKey").GetString()!;
        var model = c.GetProperty("oldModel").GetString()!;
        store.SaveProviderModelLimits(new("p", model, null, 4096, 333, "user"));
        var stub = new StubHttpMessageHandler().Json("data: [DONE]\n").Json("data: [DONE]\n");
        using var http = new HttpClient(stub);
        var router = new ProviderRouter(store, () => ("p", model), () => ("p", model), _ => key, http);
        var first = await router.PrepareChatAsync();
        key = c.GetProperty("newKey").GetString()!; // Same length; all other cache inputs unchanged.
        var second = await router.PrepareChatAsync();
        await foreach (var _ in first.StreamAsync([new(ChatRole.User, "Q")])) { }
        await foreach (var _ in second.StreamAsync([new(ChatRole.User, "Q")])) { }
        Assert.Equal(new[] { "key-A", "key-B" }, stub.AllRequests.Select(r => r.Headers.Authorization!.Parameter));
    }
    private static JsonElement RoutingCase(string name) => SharedFixtures.Json("contracts/provider-routing-v1.json")
        .GetProperty("cases").EnumerateArray().Single(c => c.GetProperty("name").GetString() == name);
    private static ProviderConfig Config(ProviderType type = ProviderType.OpenAICompatible, string root = "https://unit.example/v1") =>
        new("p", type, "P", root, true, true, DateTime.UtcNow);
    private static async Task Drain(IAsyncEnumerable<string> stream) { await foreach (var _ in stream) { } }

    [Fact]
    public async Task CapturedRootKeyModelAndLimitsSurviveChanges()
    {
        var c = RoutingCase("capture-and-rotate");
        using var store = new NotebookStore(StorePath.InMemory);
        var config = Config(root: c.GetProperty("oldRoot").GetString()!);
        store.SaveProvider(config);
        var model = c.GetProperty("oldModel").GetString()!;
        var key = c.GetProperty("oldKey").GetString()!;
        store.SaveProviderModelLimits(new("p", model, null, c.GetProperty("oldContext").GetInt32(), c.GetProperty("oldOutput").GetInt32(), "user"));
        var handler = new CaptureHandler();
        using var http = new HttpClient(handler);
        var router = new ProviderRouter(store, () => ("p", model), () => ("p", "embed"), _ => key, http);
        var first = await router.PrepareChatAsync();
        store.SaveProvider(config with { BaseUrl = c.GetProperty("newRoot").GetString()! });
        model = c.GetProperty("newModel").GetString()!;
        key = c.GetProperty("newKey").GetString()!;
        store.SaveProviderModelLimits(new("p", model, null, c.GetProperty("newContext").GetInt32(), c.GetProperty("newOutput").GetInt32(), "user"));
        var second = await router.PrepareChatAsync();
        foreach (var session in new[] { first, first, second }) await Drain(session.StreamAsync([new(ChatRole.User, "Q")]));
        var expected = c.GetProperty("expectedAttempts").EnumerateArray().Select(x => x.GetString()!).ToArray();
        Assert.Equal(expected.Select(x => c.GetProperty(x + "Root").GetString() + "/chat/completions"), handler.Requests.Select(x => x.Url));
        Assert.Equal(expected.Select(x => c.GetProperty(x + "Key").GetString()), handler.Requests.Select(x => x.Key));
        Assert.Equal(expected.Select(x => c.GetProperty(x + "Model").GetString()), handler.Requests.Select(x => JsonDocument.Parse(x.Body).RootElement.GetProperty("model").GetString()));
        Assert.Equal(expected.Select(x => c.GetProperty(x + "Output").GetInt32()), handler.Requests.Select(x => JsonDocument.Parse(x.Body).RootElement.GetProperty("max_tokens").GetInt32()));
        Assert.Equal(c.GetProperty("oldContext").GetInt32(), first.Limits.RuntimeContext);
        Assert.Equal("p:" + c.GetProperty("oldModel").GetString(), first.StorageKey);
        var serialized = JsonSerializer.Serialize(first);
        Assert.DoesNotContain(key, serialized);
        Assert.DoesNotContain(c.GetProperty("oldKey").GetString()!, serialized);
    }

    [Fact]
    public async Task RoutingPrivacyAndConfigurationFixturesNeverSendData()
    {
        foreach (var c in SharedFixtures.Json("contracts/provider-routing-v1.json").GetProperty("cases").EnumerateArray())
        {
            if (!c.TryGetProperty("expectedError", out var error)) continue;
            using var store = new NotebookStore(StorePath.InMemory);
            var config = Config(ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!)) with
            {
                Enabled = !c.TryGetProperty("enabled", out var enabled) || enabled.GetBoolean(),
                PrivacyAcknowledged = !c.TryGetProperty("acknowledged", out var consent) || consent.GetBoolean()
            };
            if (!c.TryGetProperty("missing", out var missing) || !missing.GetBoolean()) store.SaveProvider(config);
            var stub = new StubHttpMessageHandler();
            using var http = new HttpClient(stub);
            var router = new ProviderRouter(store, () => ("p", "m:tag"), () => ("p", "m:tag"), _ => "k", http);
            var operation = c.GetProperty("operation").GetString();
            Func<Task> action = () => router.PrepareChatAsync();
            if (operation == "embed") action = () => router.EmbedAsync("p:m:tag", ["x"]);
            long? notebookId = null;
            if (operation == "backgroundEmbed")
            {
                var nb = store.CreateNotebook("N");
                notebookId = nb.Id;
                var source = store.CreateSource(nb.Id!.Value, SourceType.Text, "S", null, null);
                store.ReplaceChunks(source.Id!.Value, [new ChunkDraft("pending", 1, null)]);
                action = () => new AINotebook.Core.Rag.Embedder(store, router, "p:m:tag").EmbedAllPendingAsync();
            }
            if (error.GetString() == "consentRequired") await Assert.ThrowsAsync<ProviderConsentException>(action);
            else Assert.Equal(error.GetString(), (await Assert.ThrowsAsync<ProviderConfigurationException>(action)).Code);
            Assert.Equal(c.GetProperty("expectedRequests").GetInt32(), stub.AllRequests.Count);
            if (notebookId is not null) Assert.Empty(store.Embeddings(notebookId.Value, "p:m:tag"));
        }
    }

    [Fact]
    public async Task ConsentRecheckedAfterCachingButAuthorizedSessionKeepsSnapshot()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var config = Config(); store.SaveProvider(config);
        using var http = new HttpClient(new CaptureHandler());
        var router = new ProviderRouter(store, () => ("p", "m"), () => ("p", "e"), _ => null, http);
        var session = await router.PrepareChatAsync();
        store.SaveProvider(config with { PrivacyAcknowledged = false });
        // SaveProvider preserves consent; revoke explicitly using the store API.
        lock (store.Gate)
        {
            using var cmd = store.Connection.CreateCommand();
            cmd.CommandText = "UPDATE providers SET privacy_acknowledged=0 WHERE id='p'";
            cmd.ExecuteNonQuery();
        }
        await Assert.ThrowsAsync<ProviderConsentException>(() => router.PrepareChatAsync());
        await Drain(session.StreamAsync([]));
    }

    [Fact]
    public async Task KeyRemovalAndTypeChangeReplaceAdapter()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var config = Config(); store.SaveProvider(config);
        string? key = "secret";
        var handler = new CaptureHandler(); using var http = new HttpClient(handler);
        var router = new ProviderRouter(store, () => ("p", "m"), () => ("p", "e"), _ => key, http);
        var first = await router.PrepareChatAsync();
        key = null;
        var second = await router.PrepareChatAsync();
        store.SaveProvider(config with { Type = ProviderType.OpenWebUI });
        var third = await router.PrepareChatAsync();
        await Drain(first.StreamAsync([])); await Drain(second.StreamAsync([])); await Drain(third.StreamAsync([]));
        Assert.Equal(new string?[] { "secret", null, null }, handler.Requests.Select(x => x.Key));
        Assert.EndsWith("/api/chat/completions", handler.Requests[2].Url);
    }

    [Fact]
    public async Task CustomOllamaRootReachesAllFourEndpoints()
    {
        var c = RoutingCase("custom-ollama");
        using var store = new NotebookStore(StorePath.InMemory);
        var root = c.GetProperty("root").GetString()!;
        store.SaveProvider(Config(ProviderType.Ollama, root));
        store.SaveProviderModelLimits(new("p", "m:tag", null, 4096, 333, "user"));
        var handler = new CaptureHandler((request, _) => Task.FromResult(request.RequestUri!.AbsolutePath.EndsWith("api/chat")
            ? Response("{\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}\n")
            : request.RequestUri.AbsolutePath.EndsWith("api/embed") ? Response("{\"embeddings\":[[1,0]]}")
            : request.RequestUri.AbsolutePath.EndsWith("api/tags") ? Response("{\"models\":[]}")
            : Response("{\"model_info\":{}}")));
        using var http = new HttpClient(handler) { BaseAddress = new Uri("http://wrong.example") };
        var router = new ProviderRouter(store, () => ("p", "m:tag"), () => ("p", "m:tag"), _ => null, http);
        await Drain(router.StreamAsync("stale", []));
        await router.EmbedAsync("p:m:tag", ["x"]);
        await router.DiscoverModelsAsync("p");
        store.DeleteProviderModelLimits("p", "m:tag");
        Assert.True((await router.ResolveLimitsAsync("p", "m:tag", refresh: true)).IsAssumed);
        Assert.Equal(c.GetProperty("paths").EnumerateArray().Select(x => root + "/" + x.GetString()), handler.Requests.Select(x => x.Url));
        using var body = JsonDocument.Parse(handler.Requests[0].Body);
        Assert.Equal(4096, body.RootElement.GetProperty("options").GetProperty("num_ctx").GetInt32());
        Assert.Equal(333, body.RootElement.GetProperty("options").GetProperty("num_predict").GetInt32());
        Assert.Equal("m:tag", JsonDocument.Parse(handler.Requests[3].Body).RootElement.GetProperty("model").GetString());
    }

    [Fact]
    public async Task FixtureInflightMetadataCannotRestoreLimitsForAnOldEndpoint()
    {
        var cases = SharedFixtures.Json("contracts/provider-store-v1.json").GetProperty("cases")
            .EnumerateArray().Where(c => c.TryGetProperty("operation", out var operation) &&
                operation.GetString() == "inflightEndpointChange").ToArray();
        Assert.NotEmpty(cases);
        foreach (var c in cases)
        {
            using var store = new NotebookStore(StorePath.InMemory);
            var id = c.GetProperty("providerId").GetString()!;
            var model = c.GetProperty("model").GetString()!;
            var oldRoot = c.GetProperty("oldRoot").GetString()!;
            var newRoot = c.GetProperty("newRoot").GetString()!;
            var provider = Config(ProviderType.Ollama, oldRoot) with { Id = id };
            store.SaveProvider(provider);
            var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var handler = new CaptureHandler(async (request, ct) =>
            {
                if (!request.RequestUri!.AbsolutePath.EndsWith("api/show"))
                    return Response("{\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}\n");
                var oldEndpoint = request.RequestUri.AbsoluteUri.StartsWith(oldRoot, StringComparison.Ordinal);
                if (oldEndpoint)
                {
                    started.SetResult();
                    await resume.Task.WaitAsync(ct);
                }
                var window = c.GetProperty(oldEndpoint ? "oldWindow" : "newWindow").GetInt32();
                return Response(JsonSerializer.Serialize(new Dictionary<string, object>
                {
                    ["model_info"] = new Dictionary<string, object>
                    {
                        ["general.architecture"] = "llama", ["llama.context_length"] = window
                    }
                }));
            });
            using var http = new HttpClient(handler);
            var router = new ProviderRouter(store, () => (id, model), () => (id, model), _ => null, http);
            var preparing = router.PrepareChatAsync();
            await started.Task.WaitAsync(TimeSpan.FromSeconds(10));
            store.SaveProvider(provider with { BaseUrl = newRoot });
            var newCache = c.GetProperty("newCache").GetString();
            if (newCache == "auto") await router.PrepareChatAsync();
            if (newCache == "user")
                store.SaveProviderModelLimits(ProviderLimitPolicy.Automatic(id, ProviderType.Ollama, model,
                    c.GetProperty("newWindow").GetInt32()) with { Source = "user" });
            resume.SetResult();

            var captured = await preparing;
            Assert.Equal(c.GetProperty("expectedCapturedWindow").GetInt32(), captured.Limits.ContextWindow);
            var cached = store.ProviderModelLimits(id, model);
            if (c.GetProperty("expectedCachedWindow").ValueKind == JsonValueKind.Null) Assert.Null(cached);
            else Assert.Equal(c.GetProperty("expectedCachedWindow").GetInt32(), cached!.ContextWindow);
            var current = await router.PrepareChatAsync();
            Assert.Equal(c.GetProperty("expectedNewRuntime").GetInt32(), current.Limits.RuntimeContext);
            Assert.Equal(c.GetProperty("newWindow").GetInt32(), store.ProviderModelLimits(id, model)!.ContextWindow);
            Assert.Equal(newCache == "user" ? "user" : "auto", current.Limits.Source);
            var metadata = handler.Requests.ToArray();
            Assert.Equal(newCache == "user" ? new[] { oldRoot + "/api/show" }
                : new[] { oldRoot + "/api/show", newRoot + "/api/show" }, metadata.Select(r => r.Url));

            await Drain(captured.StreamAsync([]));
            await Drain(current.StreamAsync([]));
            Assert.Equal(new[] { oldRoot + "/api/chat", newRoot + "/api/chat" },
                handler.Requests.Skip(metadata.Length).Select(r => r.Url));
        }
    }

    [Fact]
    public async Task ShowUsesCapturedRootAndUserWinsRefreshRace()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var config = Config(ProviderType.Ollama, "http://old.example/proxy"); store.SaveProvider(config);
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var handler = new CaptureHandler(async (request, ct) =>
        {
            if (!request.RequestUri!.AbsolutePath.EndsWith("api/show")) return Response("{\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}\n");
            started.SetResult(); await resume.Task.WaitAsync(ct);
            return Response("{\"model_info\":{\"general.architecture\":\"llama\",\"llama.context_length\":32768}}");
        });
        using var http = new HttpClient(handler);
        var router = new ProviderRouter(store, () => ("p", "m:tag"), () => ("p", "e"), _ => null, http);
        var preparing = router.PrepareChatAsync(); await started.Task;
        store.SaveProvider(config with { BaseUrl = "http://new.example" });
        var user = new AINotebook.Core.Providers.ProviderModelLimits("p", "m:tag", 32768, 4096, 333, "user");
        store.SaveProviderModelLimits(user);
        resume.SetResult();
        var session = await preparing;
        Assert.Equal(user, session.Limits);
        await Drain(session.StreamAsync([]));
        Assert.All(handler.Requests, r => Assert.StartsWith(config.BaseUrl, r.Url));
        Assert.Equal(user, await router.ResolveLimitsAsync("p", "m:tag", true));
        Assert.Equal(2, handler.Requests.Count);
    }

    [Fact]
    public async Task OllamaShowMetadataFixturesAndUnsupportedStatuses()
    {
        var rows = SharedFixtures.Json("contracts/provider-limits-v1.json").GetProperty("cases").EnumerateArray();
        foreach (var c in rows.Where(c => c.TryGetProperty("show", out _)))
        {
            using var store = new NotebookStore(StorePath.InMemory); store.SaveProvider(Config(ProviderType.Ollama));
            var stub = new StubHttpMessageHandler().Json(c.GetProperty("show").GetRawText()); using var http = new HttpClient(stub);
            var router = new ProviderRouter(store, () => ("p", "m"), () => ("p", "e"), _ => null, http);
            var limits = await router.ResolveLimitsAsync("p", "m");
            var expected = c.GetProperty("expected");
            Assert.Equal(expected.GetProperty("runtimeContext").GetInt32(), limits.RuntimeContext);
            Assert.Equal(expected.GetProperty("isAssumed").GetBoolean(), limits.IsAssumed);
            Assert.Single(stub.AllRequests);
        }
        foreach (var status in new[] { 404, 405, 501, 401, 500 })
        {
            using var store = new NotebookStore(StorePath.InMemory); store.SaveProvider(Config(ProviderType.Ollama));
            var stub = new StubHttpMessageHandler().Json("{}", status); using var http = new HttpClient(stub);
            var router = new ProviderRouter(store, () => ("p", "m"), () => ("p", "e"), _ => null, http);
            if (status is 404 or 405 or 501) Assert.True((await router.ResolveLimitsAsync("p", "m")).IsAssumed);
            else await Assert.ThrowsAsync<OllamaException.HttpStatus>(() => router.ResolveLimitsAsync("p", "m"));
        }
    }

    [Fact]
    public async Task RawOverrideDirectSelectionAndExplicitOptionsRemainDistinct()
    {
        using var store = new NotebookStore(StorePath.InMemory); store.SaveProvider(Config());
        store.SaveProviderModelLimits(new("p", "selected", 8192, 4096, 333, "user"));
        var handler = new CaptureHandler(); using var http = new HttpClient(handler);
        var router = new ProviderRouter(store, () => ("p", "selected"), () => ("p", "e"), _ => null, http);
        Assert.Equal("m:tag", (await router.PrepareChatAsync("m:tag")).Model);
        Assert.Equal("m:tag", (await router.PrepareChatAsync("p:m:tag")).Model);
        await Drain(router.StreamAsync("stale:tag", []));
        await Drain(router.StreamAsync("stale", [], new ChatRequestOptions(8192, 777)));
        Assert.All(handler.Requests, x => Assert.Equal("selected", JsonDocument.Parse(x.Body).RootElement.GetProperty("model").GetString()));
        Assert.Equal(777, JsonDocument.Parse(handler.Requests[1].Body).RootElement.GetProperty("max_tokens").GetInt32());
        Assert.Equal(333, store.ProviderModelLimits("p", "selected")!.MaxOutputTokens);
        await Assert.ThrowsAsync<ProviderConfigurationException>(() => Drain(router.StreamAsync("stale", [], new ChatRequestOptions(16000, 777))));
        await Assert.ThrowsAsync<ProviderConfigurationException>(() => Drain(router.StreamAsync("stale", [], new ChatRequestOptions(1, 1))));
        Assert.Equal(2, handler.Requests.Count);
        var missing = await Assert.ThrowsAsync<ProviderConfigurationException>(() => router.PrepareChatAsync(Guid.NewGuid() + ":m"));
        Assert.Equal("missingProvider", missing.Code);
    }

    [Fact]
    public async Task ProbeAndDiscoveryCancellationAndInvalidRoots()
    {
        using var store = new NotebookStore(StorePath.InMemory); store.SaveProvider(Config());
        var stub = new StubHttpMessageHandler(); using var http = new HttpClient(stub);
        var router = new ProviderRouter(store, () => ("p", "m"), () => ("p", "e"), _ => null, http);
        var result = await router.ProbeAsync(ProviderType.OpenAI, "https://user:secret@host", "secret");
        Assert.Equal(ProviderProbeStatus.Failed, result.Status); Assert.Equal("invalidBaseURL", result.ErrorCode);
        Assert.DoesNotContain("secret", result.Detail ?? ""); Assert.Empty(stub.AllRequests);
        using var cts = new CancellationTokenSource(); cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => router.ProbeAsync(ProviderType.OpenAI, "https://host", null, cts.Token));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => router.DiscoverModelsAsync("p", cts.Token));
        Assert.Empty(stub.AllRequests);
    }

    /// <summary>provider-listing-limits-v1: discovery stores advertised windows; an explicit refresh re-reads the
    /// listing; chat-path resolution sends no extra request; user limits always win.</summary>
    [Theory]
    [InlineData(ProviderType.OpenWebUI)]
    [InlineData(ProviderType.OpenAICompatible)]
    public async Task ListingWindowsBecomeAutomaticLimits(ProviderType type)
    {
        using var store = new NotebookStore(StorePath.InMemory);
        store.SaveProvider(Config(type, "https://unit.example/root"));
        lock (store.Gate) store.SaveProviderModelLimits(new("p", "pinned", null, 4096, 512, "user"));
        var responses = new Queue<HttpResponseMessage>([
            Response("""{"data":[{"id":"big","max_model_len":131072},{"id":"small","context_length":4096},{"id":"pinned","max_model_len":65536},{"id":"plain"}]}"""),
            Response("""{"data":[{"id":"plain","info":{"params":{"num_ctx":24576}}}]}"""),
            Response("{}", 500),
        ]);
        var handler = new CaptureHandler((_, _) => Task.FromResult(responses.Dequeue()));
        using var http = new HttpClient(handler);
        var router = new ProviderRouter(store, () => ("p", "big"), () => ("p", "big"), _ => null, http);
        var models = await router.DiscoverModelsAsync("p");
        Assert.Equal(new[] { "big", "pinned", "plain", "small" }, models.Select(m => m.Id));
        Assert.Equal(new int?[] { 131_072, 65_536, null, 4_096 }, models.Select(m => m.ContextWindow));
        lock (store.Gate)
        {
            Assert.Equal(32_768, store.ProviderModelLimits("p", "big")!.RuntimeContext);
            Assert.Equal(4_096, store.ProviderModelLimits("p", "small")!.RuntimeContext);
            Assert.Equal("user", store.ProviderModelLimits("p", "pinned")!.Source);
            Assert.Null(store.ProviderModelLimits("p", "plain"));
        }
        Assert.True((await router.ResolveLimitsAsync("p", "plain")).IsAssumed);
        Assert.Single(handler.Requests);
        var refreshed = await router.ResolveLimitsAsync("p", "plain", refresh: true);
        Assert.Equal(24_576, refreshed.ContextWindow);
        Assert.Equal(24_576, refreshed.RuntimeContext);
        Assert.False(refreshed.IsAssumed);
        lock (store.Gate) store.DeleteProviderModelLimits("p", "plain");
        Assert.True((await router.ResolveLimitsAsync("p", "plain", refresh: true)).IsAssumed);
        Assert.Equal(3, handler.Requests.Count);
    }

    private static HttpResponseMessage Response(string body, int status = 200) => new((System.Net.HttpStatusCode)status) { Content = new StringContent(body) };
    private sealed class CaptureHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>>? respond = null) : HttpMessageHandler
    {
        internal readonly List<(string Url, string? Key, string Body)> Requests = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(ct);
            lock (Requests) Requests.Add((request.RequestUri!.AbsoluteUri, request.Headers.Authorization?.Parameter, body));
            return respond is null ? Response("data: [DONE]\n") : await respond(request, ct);
        }
    }
}

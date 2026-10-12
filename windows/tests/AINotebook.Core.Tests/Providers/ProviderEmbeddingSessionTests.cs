using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

using CoreProviderRouter = AINotebook.Core.Providers.Routing.ProviderRouter;

namespace AINotebook.Core.Tests.Providers;

public sealed class ProviderEmbeddingSessionTests
{
    private const string EmbeddingResponse = """{"data":[{"embedding":[1,0]}]}""";

    [Fact]
    public void EndpointIdentityFixture()
    {
        int executed = 0;
        foreach (var c in Cases())
        {
            if (!c.TryGetProperty("expectedEndpointRevision", out var expected)) continue;
            executed++;
            var type = ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!);
            Assert.Equal(expected.GetString(), EmbeddingEndpointRevision.Make(type, c.GetProperty("normalizedRoot").GetString()!));
            if (c.TryGetProperty("newEndpointRevision", out var moved))
                Assert.Equal(moved.GetString(), EmbeddingEndpointRevision.Make(type, c.GetProperty("newRoot").GetString()!));
        }
        var change = Case("root-change");
        Assert.Equal(change.GetProperty("generationEndpointRevision").GetString(),
            EmbeddingEndpointRevision.Make(ProviderType.OpenAICompatible, change.GetProperty("oldRoot").GetString()!));
        Assert.Equal(change.GetProperty("newEndpointRevision").GetString(),
            EmbeddingEndpointRevision.Make(ProviderType.OpenAICompatible, change.GetProperty("newRoot").GetString()!));
        Assert.Equal(3, executed);
    }

    [Fact]
    public async Task CapturedRootKeyAndModelSurviveSettingsMutation()
    {
        var c = Case("key-rotation");
        var moved = Case("root-change");
        using var store = new NotebookStore(StorePath.InMemory);
        string id = c.GetProperty("providerId").GetString()!, root = c.GetProperty("oldRoot").GetString()!;
        string key = c.GetProperty("oldKey").GetString()!, model = c.GetProperty("rawModel").GetString()!;
        var config = new ProviderConfig(id, ProviderType.OpenAICompatible, "P", root, true, true, DateTime.UtcNow);
        store.SaveProvider(config);
        var handler = new StubHttpMessageHandler().Json(EmbeddingResponse);
        using var http = new HttpClient(handler);
        var router = new CoreProviderRouter(store, () => (id, model), () => (id, model), _ => key, http);
        var identity = Identity(id, EmbeddingEndpointRevision.Make(config.Type, root), model, "1");
        var session = await router.PrepareEmbeddingAsync(identity);
        Assert.Empty(handler.AllRequests);
        Assert.Equal(id + ":" + model, session.StorageKey);
        Assert.Equal(c.GetProperty("expectedEndpointRevision").GetString(), session.EndpointRevision);
        Assert.Null(session.Status);
        store.SaveProvider(config with { BaseUrl = moved.GetProperty("newRoot").GetString()! });
        key = c.GetProperty("newKey").GetString()!;
        model = c.GetProperty("newModel").GetString()!;
        var vectors = await session.EmbedAsync(c.GetProperty("inputs").EnumerateArray().Select(x => x.GetString()!).ToArray());
        Assert.Equal(new[] { 1f, 0f }, Assert.Single(vectors));
        var expected = c.GetProperty("expectedRequest");
        Assert.Single(handler.AllRequests);
        Assert.Equal(expected.GetProperty("url").GetString(), handler.LastRequest!.RequestUri!.AbsoluteUri);
        Assert.Equal(expected.GetProperty("authorization").GetString(), handler.LastRequest.Headers.Authorization!.ToString());
        using var body = JsonDocument.Parse(handler.LastRequestBody!);
        Assert.Equal(expected.GetProperty("model").GetString(), body.RootElement.GetProperty("model").GetString());
        Assert.Equal(expected.GetProperty("inputs").EnumerateArray().Select(x => x.GetString()),
            body.RootElement.GetProperty("input").EnumerateArray().Select(x => x.GetString()));
    }

    [Fact]
    public async Task MismatchedEndpointAndChatOnlySendNothing()
    {
        int executed = 0;
        foreach (string name in new[] { "root-change", "chat-only-anthropic", "chat-only-openwebui" })
        {
            executed++;
            var c = Case(name);
            var type = ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!);
            using var store = new NotebookStore(StorePath.InMemory);
            string root = c.TryGetProperty("newRoot", out var newRoot) ? newRoot.GetString()! : c.GetProperty("root").GetString()!;
            store.SaveProvider(new ProviderConfig("p", type, "P", root, true, true, DateTime.UtcNow));
            var handler = new StubHttpMessageHandler().Json(EmbeddingResponse);
            using var http = new HttpClient(handler);
            var router = new CoreProviderRouter(store, () => ("p", "m"), () => ("p", "m"), _ => "k", http);
            string endpoint = c.TryGetProperty("generationEndpointRevision", out var generation)
                ? generation.GetString()! : EmbeddingEndpointRevision.Make(type, c.GetProperty("normalizedRoot").GetString()!);
            var identity = Identity("p", endpoint, c.GetProperty("model").GetString()!, c.GetProperty("queryFormatVersion").GetString()!);
            Assert.Equal(c.GetProperty("expectedError").GetString(), await ErrorCode(() => router.PrepareEmbeddingAsync(identity)));
            Assert.Equal(c.GetProperty("requests").GetInt32(), handler.AllRequests.Count);
        }
        Assert.Equal(3, executed);
    }

    [Fact]
    public async Task FormatsAndModelTags()
    {
        // Modern format "1": a tagged raw model is preserved byte-for-byte.
        foreach (string name in new[] { "root", "proxy", "key-rotation" })
        {
            var c = Case(name);
            var type = ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!);
            var (store, handler, http, router) = Router(type, c.GetProperty("root").GetString()!, "p", "selected");
            using (store) using (http)
            {
                string model = c.GetProperty("model").GetString()!;
                var session = await router.PrepareEmbeddingAsync(Identity("p", c.GetProperty("expectedEndpointRevision").GetString()!,
                    model, c.GetProperty("queryFormatVersion").GetString()!));
                handler.Json(type == ProviderType.Ollama ? """{"embeddings":[[1,0]]}""" : EmbeddingResponse);
                await session.EmbedAsync(Inputs(c));
                Assert.Equal(c.GetProperty("requests").GetInt32(), handler.AllRequests.Count);
                using var body = JsonDocument.Parse(handler.LastRequestBody!);
                Assert.Equal(model, body.RootElement.GetProperty("model").GetString());
                Assert.Equal(c.GetProperty("expectedInputs").EnumerateArray().Select(x => x.GetString()),
                    body.RootElement.GetProperty("input").EnumerateArray().Select(x => x.GetString()));
            }
        }

        // Legacy identities: whole stored key; a first-colon split only for a registered provider id,
        // an unknown prefix is a bare model tag of the captured selection.
        foreach (string name in new[] { "legacy", "legacy-bare", "legacy-unresolved", "legacy-bare-tag",
            "legacy-bare-size-tag", "legacy-unknown-prefix", "legacy-empty-prefix", "legacy-unresolved-type" })
        {
            var c = Case(name);
            string selectedProvider = c.TryGetProperty("selectedProviderId", out var sp) ? sp.GetString()! : "provider-a";
            string selectedModel = c.TryGetProperty("selectedModel", out var sm) ? sm.GetString()! : "selected";
            var (store, handler, http, router) = Router(ProviderType.OpenAICompatible, c.GetProperty("root").GetString()!,
                "provider-a", selectedModel, selectedProvider);
            using (store) using (http)
            {
                string storedKey = c.GetProperty("storedKey").GetString()!;
                var identity = new GenerationIdentity("legacy", "legacy", storedKey, null, 2, "legacy", "legacy", "legacy", "legacy");
                if (c.GetProperty("expectedError").ValueKind == JsonValueKind.String)
                {
                    Assert.Equal(c.GetProperty("expectedError").GetString(), await ErrorCode(() => router.PrepareEmbeddingAsync(identity)));
                    Assert.Equal(c.GetProperty("requests").GetInt32(), handler.AllRequests.Count);
                    continue;
                }
                var session = await router.PrepareEmbeddingAsync(identity);
                Assert.Equal(storedKey, session.StorageKey);
                Assert.Equal(c.GetProperty("expectedStatus").GetString(), session.Status);
                handler.Json(EmbeddingResponse);
                await session.EmbedAsync(Inputs(c));
                Assert.Equal(c.GetProperty("requests").GetInt32(), handler.AllRequests.Count);
                using var body = JsonDocument.Parse(handler.LastRequestBody!);
                Assert.Equal(c.GetProperty("rawModel").GetString(), body.RootElement.GetProperty("model").GetString());
                Assert.Equal(c.GetProperty("expectedInputs").EnumerateArray().Select(x => x.GetString()),
                    body.RootElement.GetProperty("input").EnumerateArray().Select(x => x.GetString()));
            }
        }

        var unknown = Case("unknown-format");
        var (unknownStore, unknownHandler, unknownHttp, unknownRouter) = Router(ProviderType.OpenAICompatible, unknown.GetProperty("root").GetString()!, "p", "m");
        using (unknownStore) using (unknownHttp)
        {
            var identity = Identity("p", EmbeddingEndpointRevision.Make(ProviderType.OpenAICompatible, unknown.GetProperty("normalizedRoot").GetString()!),
                unknown.GetProperty("model").GetString()!, unknown.GetProperty("queryFormatVersion").GetString()!);
            Assert.Equal(unknown.GetProperty("expectedError").GetString(), await ErrorCode(() => unknownRouter.PrepareEmbeddingAsync(identity)));
            Assert.Equal(unknown.GetProperty("requests").GetInt32(), unknownHandler.AllRequests.Count);
        }
    }

    [Fact]
    public async Task PrivacyGateRunsBeforeSessionCreation()
    {
        var c = Case("proxy");
        using var store = new NotebookStore(StorePath.InMemory);
        string root = c.GetProperty("root").GetString()!;
        store.SaveProvider(new ProviderConfig("p", ProviderType.OpenAICompatible, "P", root, true, false, DateTime.UtcNow));
        var handler = new StubHttpMessageHandler().Json(EmbeddingResponse);
        using var http = new HttpClient(handler);
        var router = new CoreProviderRouter(store, () => ("p", "m"), () => ("p", "m"), _ => "k", http);
        var identity = Identity("p", c.GetProperty("expectedEndpointRevision").GetString()!, "m", "1");
        await Assert.ThrowsAsync<ProviderConsentException>(() => router.PrepareEmbeddingAsync(identity));
        // A legacy identity resolving to the same remote provider is gated identically.
        var legacy = new GenerationIdentity("legacy", "legacy", "p:m", null, 2, "legacy", "legacy", "legacy", "legacy");
        await Assert.ThrowsAsync<ProviderConsentException>(() => router.PrepareEmbeddingAsync(legacy));
        Assert.Empty(handler.AllRequests);
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => router.PrepareEmbeddingAsync(identity, cancelled.Token));
        Assert.Empty(handler.AllRequests);
    }

    private static (NotebookStore Store, StubHttpMessageHandler Handler, HttpClient Http, CoreProviderRouter Router) Router(
        ProviderType type, string root, string providerId, string selectedModel, string? selectedProvider = null)
    {
        var store = new NotebookStore(StorePath.InMemory);
        store.SaveProvider(new ProviderConfig(providerId, type, "P", root, true, true, DateTime.UtcNow));
        var handler = new StubHttpMessageHandler();
        var http = new HttpClient(handler);
        var selection = (selectedProvider ?? providerId, selectedModel);
        return (store, handler, http, new CoreProviderRouter(store, () => selection, () => selection, _ => "k", http));
    }

    private static async Task<string?> ErrorCode(Func<Task> action)
    {
        try { await action(); return null; }
        catch (RetrievalException error) { return error.Code; }
        catch (ProviderConfigurationException error) { return error.Code; }
    }

    private static GenerationIdentity Identity(string providerId, string endpoint, string model, string format) =>
        new(providerId, endpoint, model, null, 2, "l2", format, "1", "2");

    private static string[] Inputs(JsonElement c) => c.GetProperty("inputs").EnumerateArray().Select(x => x.GetString()!).ToArray();

    private static IEnumerable<JsonElement> Cases() =>
        SharedFixtures.Json("contracts/retrieval-session-v1.json").GetProperty("cases").EnumerateArray();

    private static JsonElement Case(string name) => Cases().Single(c => c.GetProperty("name").GetString() == name);
}

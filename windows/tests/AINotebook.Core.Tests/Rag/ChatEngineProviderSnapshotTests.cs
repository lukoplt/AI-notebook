using System.Text.Json;
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

using ProviderRouter = AINotebook.Core.Providers.Routing.ProviderRouter;

namespace AINotebook.Core.Tests.Rag;

public class ChatEngineProviderSnapshotTests
{
    [Fact]
    public async Task CapturePrecedesRetrievalAndSurvivesRetry()
    {
        var c = SharedFixtures.Json("contracts/provider-routing-v1.json").GetProperty("cases").EnumerateArray()
            .Single(x => x.GetProperty("operation").GetString() == "snapshot");
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var session = store.CreateChatSession(nb.Id!.Value, "T");
        var source = store.CreateSource(nb.Id.Value, SourceType.Text, "S", null, null);
        store.ReplaceChunks(source.Id!.Value, [new ChunkDraft("evidence", 1, null)]);
        store.StoreEmbedding(store.Chunks(source.Id.Value)[0].Id!.Value, "embed", new EmbeddingVector([1f, 0f]));
        var root = c.GetProperty("oldRoot").GetString()!;
        var model = c.GetProperty("oldModel").GetString()!;
        var key = c.GetProperty("oldKey").GetString()!;
        store.SaveProvider(new("p", ProviderType.OpenAICompatible, "P", root, true, true, DateTime.UtcNow));
        store.SaveProviderModelLimits(new("p", model, null, 4096, 333, "user"));
        var stub = new CaptureHandler([429, 200, 200]);
        using var http = new HttpClient(stub);
        var router = new ProviderRouter(store, () => ("p", model), () => ("p", "embed"), _ => key, http);
        var embedding = new MockEmbeddingClient(_ =>
        {
            root = c.GetProperty("newRoot").GetString()!;
            model = c.GetProperty("newModel").GetString()!;
            key = c.GetProperty("newKey").GetString()!;
            store.SaveProvider(new("p", ProviderType.OpenAICompatible, "P", root, true, true, DateTime.UtcNow));
            store.SaveProviderModelLimits(new("p", model, null, 8192, 777, "user"));
            return [1f, 0f];
        });
        var engine = new ChatEngine(store, new Retriever(store, embedding, "embed"), router,
            "stale-launch-model", retryAttempts: 1, retryBackoffMillis: 1);
        var first = await engine.SendAsync(session.Id!.Value, nb.Id.Value, "Q", onToken: _ => { });
        var second = await engine.SendAsync(session.Id.Value, nb.Id.Value, "Q2", onToken: _ => { });
        Assert.Equal(2, embedding.Calls.Count);
        Assert.Equal(new[] { 333, 333, 777 }, stub.Requests.Select(r => JsonDocument.Parse(r.Body).RootElement.GetProperty("max_tokens").GetInt32()));
        Assert.Equal(new[] { "model:old", "model:old", "model:new" }, stub.Requests.Select(r => JsonDocument.Parse(r.Body).RootElement.GetProperty("model").GetString()));
        Assert.Equal("p:model:old", first.Model);
        Assert.Equal("p:model:new", second.Model);
        Assert.Equal(new[] { c.GetProperty("oldRoot").GetString(), c.GetProperty("oldRoot").GetString(), c.GetProperty("newRoot").GetString() }
            .Select(x => x + "/chat/completions"), stub.Requests.Select(r => r.Url));
        Assert.Equal(new[] { "key-A", "key-A", "key-B" }, stub.Requests.Select(r => r.Key));
    }
    [Theory]
    [InlineData("m:tag", "p", "m:tag", true)]
    [InlineData("q:vendor/m:tag", "q", "vendor/m:tag", false)]
    public async Task ExplicitRawAndQualifiedOverridesAreCaptured(string requested, string provider, string raw, bool ollama)
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N"); var session = store.CreateChatSession(nb.Id!.Value, "T");
        store.SaveProvider(new("p", ollama ? ProviderType.Ollama : ProviderType.OpenAICompatible, "P", "http://old.example/v1", true, true, DateTime.UtcNow));
        store.SaveProvider(new("q", ProviderType.OpenAICompatible, "Q", "http://other.example/v1", true, true, DateTime.UtcNow));
        store.SaveProviderModelLimits(new(provider, raw, null, 4096, 333, "user"));
        var handler = new CaptureHandler([200]); using var http = new HttpClient(handler);
        var router = new ProviderRouter(store, () => ("p", "selected"), () => ("p", "embed"), _ => null, http);
        var engine = new ChatEngine(store, new Retriever(store, new MockEmbeddingClient(), "embed"), router, "stale");
        var result = await engine.SendAsync(session.Id!.Value, nb.Id.Value, "Q", model: requested);
        Assert.Equal(provider + ":" + raw, result.Model);
        Assert.Equal(raw, JsonDocument.Parse(Assert.Single(handler.Requests).Body).RootElement.GetProperty("model").GetString());
    }

    [Theory]
    [InlineData("missingProvider")]
    [InlineData("disabledProvider")]
    [InlineData("consentRequired")]
    [InlineData("invalidBaseURL")]
    public async Task FailedPreparationDoesNotRetrieveSendOrPersist(string failure)
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N"); var session = store.CreateChatSession(nb.Id!.Value, "T");
        var source = store.CreateSource(nb.Id.Value, SourceType.Text, "S", null, null);
        store.ReplaceChunks(source.Id!.Value, [new ChunkDraft("evidence", 1, null)]);
        store.StoreEmbedding(store.Chunks(source.Id.Value)[0].Id!.Value, "embed", new EmbeddingVector([1f, 0f]));
        if (failure != "missingProvider")
            store.SaveProvider(new("p", ProviderType.OpenAICompatible, "P", failure == "invalidBaseURL" ? "invalid" : "https://host/v1", failure != "disabledProvider", failure != "consentRequired", DateTime.UtcNow));
        var handler = new CaptureHandler([200]); using var http = new HttpClient(handler);
        var embedding = new MockEmbeddingClient();
        var router = new ProviderRouter(store, () => ("p", "m"), () => ("p", "e"), _ => null, http);
        var engine = new ChatEngine(store, new Retriever(store, embedding, "embed"), router, "stale");
        var error = await Record.ExceptionAsync(() => engine.SendAsync(session.Id!.Value, nb.Id.Value, "Q"));
        if (failure == "consentRequired") Assert.IsType<ProviderConsentException>(error);
        else Assert.Equal(failure, Assert.IsType<ProviderConfigurationException>(error).Code);
        Assert.Empty(embedding.Calls); Assert.Empty(handler.Requests); Assert.Empty(store.Messages(session.Id!.Value));
    }

    [Fact]
    public async Task CancelledRetryDoesNotStartAnotherRequest()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N"); var session = store.CreateChatSession(nb.Id!.Value, "T");
        store.SaveProvider(new("p", ProviderType.OpenAICompatible, "P", "https://host/v1", true, true, DateTime.UtcNow));
        using var cts = new CancellationTokenSource();
        var handler = new CaptureHandler([429, 200]); using var http = new HttpClient(handler);
        var router = new ProviderRouter(store, () => ("p", "m"), () => ("p", "e"), _ => null, http);
        var engine = new ChatEngine(store, new Retriever(store, new MockEmbeddingClient(), "embed"), router, "stale", retryBackoffMillis: 1);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => engine.SendAsync(session.Id!.Value, nb.Id.Value, "Q", onRetry: cts.Cancel, ct: cts.Token));
        Assert.Single(handler.Requests);
        Assert.Single(store.Messages(session.Id!.Value));
    }

    [Fact]
    public async Task ContextLengthRejectionIsTerminal()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N"); var session = store.CreateChatSession(nb.Id!.Value, "T");
        store.SaveProvider(new("p", ProviderType.OpenAICompatible, "P", "https://host/v1", true, true, DateTime.UtcNow));
        var handler = new CaptureHandler([413]); using var http = new HttpClient(handler);
        var router = new ProviderRouter(store, () => ("p", "m"), () => ("p", "e"), _ => null, http);
        var engine = new ChatEngine(store, new Retriever(store, new MockEmbeddingClient(), "embed"), router, "stale", retryBackoffMillis: 1);
        var retries = 0;
        await Assert.ThrowsAsync<ProviderContextTooLongException>(() => engine.SendAsync(session.Id!.Value, nb.Id.Value, "Q", onRetry: () => retries++));
        Assert.Single(handler.Requests); Assert.Equal(0, retries);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task HttpTimeoutRetriesButCallerCancellationIsTerminal(bool cancelCaller)
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N"); var session = store.CreateChatSession(nb.Id!.Value, "T");
        store.SaveProvider(new("p", ProviderType.OpenAICompatible, "P", "https://host/v1", true, true, DateTime.UtcNow));
        using var cts = new CancellationTokenSource();
        var attempts = 0;
        var handler = new CaptureHandler([200], () =>
        {
            if (++attempts != 1) return;
            if (cancelCaller)
            {
                cts.Cancel();
                throw new TaskCanceledException("Caller cancelled.", null, cts.Token);
            }
            // HttpClient reports its timeout with this exception shape even
            // though the caller's cancellation token has not been cancelled.
            throw new TaskCanceledException("HTTP timeout.", new TimeoutException());
        });
        using var http = new HttpClient(handler);
        var router = new ProviderRouter(store, () => ("p", "m"), () => ("p", "e"), _ => null, http);
        var engine = new ChatEngine(store, new Retriever(store, new MockEmbeddingClient(), "embed"), router,
            "stale", retryAttempts: 1, retryBackoffMillis: 1);
        var retries = 0;
        Task<ChatMessage> Send() => engine.SendAsync(session.Id!.Value, nb.Id.Value, "Q",
            onRetry: () => retries++, ct: cts.Token);
        if (cancelCaller)
        {
            await Assert.ThrowsAnyAsync<OperationCanceledException>(Send);
            Assert.Single(handler.Requests);
            Assert.Equal(0, retries);
            Assert.Single(store.Messages(session.Id!.Value));
        }
        else
        {
            Assert.Equal("p:m", (await Send()).Model);
            Assert.False(cts.IsCancellationRequested);
            Assert.Equal(2, handler.Requests.Count);
            Assert.Equal(1, retries);
            Assert.Equal(2, store.Messages(session.Id!.Value).Count);
        }
    }

    private sealed class CaptureHandler(int[] statuses, Action? beforeResponse = null) : HttpMessageHandler
    {
        internal readonly List<(string Url, string? Key, string Body)> Requests = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(ct);
            int index;
            lock (Requests) { index = Requests.Count; Requests.Add((request.RequestUri!.AbsoluteUri, request.Headers.Authorization?.Parameter, body)); }
            beforeResponse?.Invoke();
            var status = statuses[Math.Min(index, statuses.Length - 1)];
            return new((System.Net.HttpStatusCode)status) { Content = new StringContent(status == 200 ? (request.RequestUri!.AbsolutePath.EndsWith("api/chat") ? "{\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}\n" : "data: [DONE]\n") : "{}") };
        }
    }
}

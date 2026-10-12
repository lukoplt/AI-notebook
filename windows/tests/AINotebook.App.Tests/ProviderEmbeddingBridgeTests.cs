using System.ComponentModel;
using System.Net;
using System.Text;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.App.Tests;

/// <summary>
/// The App wrapper is what DI injects into Retriever as IEmbeddingProducing, so it
/// must forward generation-bound session preparation to the Core router; otherwise
/// retrieval would silently bypass modern session capture.
/// </summary>
public sealed class ProviderEmbeddingBridgeTests
{
    [Fact]
    public void AppRouterExposesEmbeddingSessions()
    {
        Assert.True(typeof(IEmbeddingSessionPreparing)
            .IsAssignableFrom(typeof(AINotebook.App.Services.ProviderRouter)));
    }

    [Fact]
    public async Task PreparedSessionKeepsCapturedRootKeyAndModel()
    {
        const string id = "provider-a", root = "https://unit.example/proxy/v1", model = "m:tag";
        var requests = new List<(Uri? Uri, string? Authorization, string Body)>();
        using var http = new HttpClient(new CapturingHandler("""{"data":[{"embedding":[1,0]}]}""", requests));
        using var store = new NotebookStore(StorePath.InMemory);
        var config = new ProviderConfig(id, ProviderType.OpenAICompatible, "P", root, true, true, DateTime.UtcNow);
        store.SaveProvider(config);
        var secrets = new FakeSecrets();
        secrets.Save(id, "key-A");
        var settings = new FakeSettings { SelectedEmbeddingProviderId = id, SelectedEmbeddingModel = model };
        var router = new AINotebook.App.Services.ProviderRouter(settings, store, secrets, new OllamaClient(), http);
        var identity = new GenerationIdentity(id, EmbeddingEndpointRevision.Make(config.Type, root), model, null, 2, "l2", "1", "1", "2");

        var session = await router.PrepareEmbeddingAsync(identity);
        Assert.Empty(requests);
        store.SaveProvider(config with { BaseUrl = "https://other.example/v1" });
        secrets.Save(id, "key-B");
        settings.SelectedEmbeddingModel = "new:model";
        await session.EmbedAsync(["Q"]);

        var request = Assert.Single(requests);
        Assert.Equal(root + "/embeddings", request.Uri!.ToString());
        Assert.Equal("Bearer key-A", request.Authorization);
        Assert.Contains("\"model\":\"m:tag\"", request.Body);
        Assert.Equal(id + ":" + model, session.StorageKey);
    }

    private sealed class FakeSettings : ISettingsService
    {
        public event PropertyChangedEventHandler? PropertyChanged { add { } remove { } }
        public AppLanguage Language { get; set; } = AppLanguage.English;
        public bool HasCompletedOnboarding { get; set; } = true;
        public string SelectedChatModel { get; set; } = "llama3.2:3b";
        public string SelectedEmbeddingModel { get; set; } = "nomic-embed-text";
        public string SelectedChatProviderId { get; set; } = ProviderConfig.OllamaId;
        public string SelectedEmbeddingProviderId { get; set; } = ProviderConfig.OllamaId;
        public bool AutoCheckUpdates { get; set; } = true;
        public DateTimeOffset? LastUpdateCheckUtc { get; set; }
        public bool WebSearchEnabled { get; set; }
        public string RightPanel { get; set; } = "";
        public double RightPanelWidth { get; set; } = 360;
    }

    private sealed class FakeSecrets : ISecretStore
    {
        private readonly Dictionary<string, string> _map = new();
        public void Save(string providerId, string secret) => _map[providerId] = secret;
        public string? Load(string providerId) => _map.TryGetValue(providerId, out var s) ? s : null;
        public void Delete(string providerId) => _map.Remove(providerId);
    }

    private sealed class CapturingHandler(string body, List<(Uri? Uri, string? Authorization, string Body)> requests)
        : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var content = request.Content is not null ? await request.Content.ReadAsStringAsync(ct) : "";
            lock (requests) requests.Add((request.RequestUri, request.Headers.Authorization?.ToString(), content));
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json")
            };
        }
    }
}

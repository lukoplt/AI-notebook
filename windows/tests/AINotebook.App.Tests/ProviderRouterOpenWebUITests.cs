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

public class ProviderRouterOpenWebUITests
{
    [Fact]
    public async Task TestConnection_openwebui_hits_api_models_and_succeeds()
    {
        Uri? uri = null;
        var http = new HttpClient(new CapturingHandler(HttpStatusCode.OK,
            """{"data":[{"id":"llama3.2","name":"Llama 3.2"}]}""",
            u => uri = u));
        using var store = new NotebookStore(StorePath.InMemory);
        var router = MakeRouter(store, http);

        var error = await router.TestConnectionAsync(ProviderType.OpenWebUI, "http://host:3000", "sk-k");

        Assert.Null(error);
        Assert.Equal("http://host:3000/api/models", uri!.ToString());
    }

    [Fact]
    public async Task TestConnection_openwebui_reports_error_on_401()
    {
        var http = new HttpClient(new CapturingHandler(HttpStatusCode.Unauthorized, "", _ => { }));
        using var store = new NotebookStore(StorePath.InMemory);
        var router = MakeRouter(store, http);

        var error = await router.TestConnectionAsync(ProviderType.OpenWebUI, "http://host:3000", "bad");

        Assert.NotNull(error);
    }

    [Fact]
    public async Task Chat_routes_to_openwebui_adapter_for_selected_provider()
    {
        Uri? uri = null;
        var sse = "data: {\"choices\":[{\"delta\":{\"content\":\"tok\"},\"index\":0}]}\n" +
                  "data: [DONE]\n";
        var http = new HttpClient(new CapturingHandler(HttpStatusCode.OK, sse, u => uri = u));

        using var store = new NotebookStore(StorePath.InMemory);
        var cfg = new ProviderConfig(
            "11111111-1111-1111-1111-111111111111", ProviderType.OpenWebUI,
            "LAN", "http://host:3000", true, true, DateTime.UtcNow);
        store.SaveProvider(cfg);

        var settings = new FakeSettings
        {
            SelectedChatProviderId = cfg.Id,
            SelectedChatModel = "llama3.2"
        };
        var router = MakeRouter(store, http, settings);

        var tokens = new List<string>();
        await foreach (var t in router.StreamAsync("ignored", [new ChatTurn(ChatRole.User, "hi")]))
            tokens.Add(t);

        Assert.Equal(["tok"], tokens);
        Assert.Equal("http://host:3000/api/chat/completions", uri!.ToString());
    }

    // ── FR-A8 consent gate (defense-in-depth) ───────────────────────────────

    /// A cloud/network provider the user never acknowledged must not receive
    /// any data via chat — the router throws before the adapter makes a
    /// request. Mirrors Tests/AINotebookCoreTests/ProviderRouterTests.swift's
    /// testStreamThrowsConsentRequiredForUnacknowledgedCloudProvider.
    [Fact]
    public async Task Chat_throws_ProviderConsentException_for_unacknowledged_cloud_provider()
    {
        var handlerInvoked = false;
        var http = new HttpClient(new CapturingHandler(HttpStatusCode.OK, "data: [DONE]\n",
            _ => handlerInvoked = true));

        using var store = new NotebookStore(StorePath.InMemory);
        var cfg = new ProviderConfig(
            "66666666-6666-6666-6666-666666666666", ProviderType.OpenWebUI,
            "LAN", "http://host:3000", true, false, DateTime.UtcNow); // PrivacyAcknowledged: false
        store.SaveProvider(cfg);

        var settings = new FakeSettings
        {
            SelectedChatProviderId = cfg.Id,
            SelectedChatModel = "llama3.2"
        };
        var router = MakeRouter(store, http, settings);

        await Assert.ThrowsAsync<ProviderConsentException>(async () =>
        {
            await foreach (var _ in router.StreamAsync("ignored", [new ChatTurn(ChatRole.User, "hi")])) { }
        });

        Assert.False(handlerInvoked, "no HTTP request must be made without consent");
    }

    /// Once the user acknowledges consent, the same provider streams normally
    /// — proves the gate is not sticky/cached beyond the consent flag itself.
    [Fact]
    public async Task Chat_streams_normally_once_provider_is_acknowledged()
    {
        var sse = "data: {\"choices\":[{\"delta\":{\"content\":\"tok\"},\"index\":0}]}\n" +
                  "data: [DONE]\n";
        var http = new HttpClient(new CapturingHandler(HttpStatusCode.OK, sse, _ => { }));

        using var store = new NotebookStore(StorePath.InMemory);
        var cfg = new ProviderConfig(
            "77777777-7777-7777-7777-777777777777", ProviderType.OpenWebUI,
            "LAN", "http://host:3000", true, true, DateTime.UtcNow); // PrivacyAcknowledged: true
        store.SaveProvider(cfg);

        var settings = new FakeSettings
        {
            SelectedChatProviderId = cfg.Id,
            SelectedChatModel = "llama3.2"
        };
        var router = MakeRouter(store, http, settings);

        var tokens = new List<string>();
        await foreach (var t in router.StreamAsync("ignored", [new ChatTurn(ChatRole.User, "hi")]))
            tokens.Add(t);

        Assert.Equal(["tok"], tokens);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static ProviderRouter MakeRouter(
        NotebookStore store, HttpClient http, ISettingsService? settings = null)
        => new(settings ?? new FakeSettings(), store, new FakeSecrets(),
               new OllamaClient(), http);

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
    }

    private sealed class FakeSecrets : ISecretStore
    {
        private readonly Dictionary<string, string> _map = new();
        public void Save(string providerId, string secret) => _map[providerId] = secret;
        public string? Load(string providerId) => _map.TryGetValue(providerId, out var s) ? s : null;
        public void Delete(string providerId) => _map.Remove(providerId);
    }

    private sealed class CapturingHandler(
        HttpStatusCode status, string body, Action<Uri?> capture) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            capture(request.RequestUri);
            var resp = new HttpResponseMessage(status)
            {
                Content = new StringContent(body, Encoding.UTF8, "text/event-stream")
            };
            return Task.FromResult(resp);
        }
    }
}

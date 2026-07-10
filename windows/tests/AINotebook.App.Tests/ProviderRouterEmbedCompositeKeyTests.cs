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
/// FR: ProviderRouter.EmbedAsync must honor the composite "{providerId}:{rawModel}"
/// key it is given rather than re-sampling the live selection — otherwise the
/// Embedder's per-batch key snapshot (stored on chunk_embeddings.model) can
/// diverge from the provider the router actually calls when settings change
/// mid-batch. Mirrors the fakes pattern in ProviderRouterOpenWebUITests.cs.
/// </summary>
public class ProviderRouterEmbedCompositeKeyTests
{
    [Fact]
    public async Task Composite_key_routes_to_specified_provider_with_raw_model_not_live_selection()
    {
        string? capturedBody = null;
        Uri? capturedUri = null;
        var http = new HttpClient(new CapturingHandler(HttpStatusCode.OK,
            """{"data":[{"embedding":[0.1,0.2]}]}""",
            (u, b) => { capturedUri = u; capturedBody = b; }));

        using var store = new NotebookStore(StorePath.InMemory);

        var live = new ProviderConfig(
            "11111111-1111-1111-1111-111111111111", ProviderType.OpenAI,
            "Live", "https://live.example.com", true, true, DateTime.UtcNow);
        var target = new ProviderConfig(
            "22222222-2222-2222-2222-222222222222", ProviderType.OpenAICompatible,
            "Target", "https://target.example.com", true, true, DateTime.UtcNow);
        store.SaveProvider(live);
        store.SaveProvider(target);

        // Live selection points at a DIFFERENT provider/model than the
        // composite key passed to EmbedAsync — if the router re-sampled
        // settings instead of honoring the key, the request would go to
        // "live.example.com" with "live-model", not "target.example.com"
        // with "target-model".
        var settings = new FakeSettings
        {
            SelectedEmbeddingProviderId = live.Id,
            SelectedEmbeddingModel = "live-model"
        };
        var router = MakeRouter(store, http, settings);

        await router.EmbedAsync($"{target.Id}:target-model", ["hello"]);

        Assert.Equal("https://target.example.com/v1/embeddings", capturedUri!.ToString());
        Assert.NotNull(capturedBody);
        Assert.Contains("\"model\":\"target-model\"", capturedBody!);
        Assert.DoesNotContain("live-model", capturedBody!);
    }

    [Fact]
    public async Task Composite_key_preserves_colons_in_raw_model_ollama_style_tags()
    {
        string? capturedBody = null;
        var http = new HttpClient(new CapturingHandler(HttpStatusCode.OK,
            """{"data":[{"embedding":[0.1]}]}""",
            (_, b) => capturedBody = b));

        using var store = new NotebookStore(StorePath.InMemory);
        var target = new ProviderConfig(
            "33333333-3333-3333-3333-333333333333", ProviderType.OpenAICompatible,
            "Target", "https://target.example.com", true, true, DateTime.UtcNow);
        store.SaveProvider(target);

        var router = MakeRouter(store, http, new FakeSettings());

        // Raw model itself contains a colon (Ollama-style tag) — only the
        // FIRST colon in the composite key may act as the providerId/model
        // separator.
        await router.EmbedAsync($"{target.Id}:llama3.2:3b", ["hello"]);

        Assert.NotNull(capturedBody);
        Assert.Contains("\"model\":\"llama3.2:3b\"", capturedBody!);
    }

    [Fact]
    public async Task No_colon_falls_back_to_live_selection()
    {
        string? capturedBody = null;
        Uri? capturedUri = null;
        var http = new HttpClient(new CapturingHandler(HttpStatusCode.OK,
            """{"data":[{"embedding":[0.1]}]}""",
            (u, b) => { capturedUri = u; capturedBody = b; }));

        using var store = new NotebookStore(StorePath.InMemory);
        var live = new ProviderConfig(
            "44444444-4444-4444-4444-444444444444", ProviderType.OpenAICompatible,
            "Live", "https://live.example.com", true, true, DateTime.UtcNow);
        store.SaveProvider(live);

        var settings = new FakeSettings
        {
            SelectedEmbeddingProviderId = live.Id,
            SelectedEmbeddingModel = "live-model"
        };
        var router = MakeRouter(store, http, settings);

        // Legacy/direct callers pass a plain, colon-free model string —
        // must fall back to the live (provider, model) selection.
        await router.EmbedAsync("legacy-direct-model", ["hello"]);

        Assert.Equal("https://live.example.com/v1/embeddings", capturedUri!.ToString());
        Assert.NotNull(capturedBody);
        Assert.Contains("\"model\":\"live-model\"", capturedBody!);
    }

    // ── FR-A8 consent gate (defense-in-depth) ───────────────────────────────

    /// The composite key still resolves to a real saved provider row — an
    /// unacknowledged cloud provider must not receive text to embed even when
    /// reached via the composite-key path (not just the live-selection path).
    /// Mirrors Tests/AINotebookCoreTests/ProviderRouterTests.swift's
    /// testEmbedThrowsConsentRequiredForUnacknowledgedCloudProvider.
    [Fact]
    public async Task Composite_key_throws_ProviderConsentException_for_unacknowledged_provider()
    {
        var handlerInvoked = false;
        var http = new HttpClient(new CapturingHandler(HttpStatusCode.OK,
            """{"data":[{"embedding":[0.1]}]}""",
            (_, _) => handlerInvoked = true));

        using var store = new NotebookStore(StorePath.InMemory);
        var target = new ProviderConfig(
            "88888888-8888-8888-8888-888888888888", ProviderType.OpenAICompatible,
            "Target", "https://target.example.com", true, false, DateTime.UtcNow); // PrivacyAcknowledged: false
        store.SaveProvider(target);

        var router = MakeRouter(store, http, new FakeSettings());

        await Assert.ThrowsAsync<ProviderConsentException>(() =>
            router.EmbedAsync($"{target.Id}:target-model", ["hello"]));

        Assert.False(handlerInvoked, "no HTTP request must be made without consent");
    }

    /// Once acknowledged, the same composite key routes and embeds normally.
    [Fact]
    public async Task Composite_key_embeds_normally_once_provider_is_acknowledged()
    {
        string? capturedBody = null;
        var http = new HttpClient(new CapturingHandler(HttpStatusCode.OK,
            """{"data":[{"embedding":[0.1,0.2]}]}""",
            (_, b) => capturedBody = b));

        using var store = new NotebookStore(StorePath.InMemory);
        var target = new ProviderConfig(
            "99999999-9999-9999-9999-999999999999", ProviderType.OpenAICompatible,
            "Target", "https://target.example.com", true, true, DateTime.UtcNow); // PrivacyAcknowledged: true
        store.SaveProvider(target);

        var router = MakeRouter(store, http, new FakeSettings());

        await router.EmbedAsync($"{target.Id}:target-model", ["hello"]);

        Assert.NotNull(capturedBody);
        Assert.Contains("\"model\":\"target-model\"", capturedBody!);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static ProviderRouter MakeRouter(
        NotebookStore store, HttpClient http, ISettingsService settings)
        => new(settings, store, new FakeSecrets(), new OllamaClient(), http);

    private sealed class FakeSettings : ISettingsService
    {
        public event PropertyChangedEventHandler? PropertyChanged { add { } remove { } }
        public AppLanguage Language { get; set; } = AppLanguage.English;
        public bool HasCompletedOnboarding { get; set; } = true;
        public string SelectedChatModel { get; set; } = "llama3.2:3b";
        public string SelectedEmbeddingModel { get; set; } = "nomic-embed-text";
        public string SelectedChatProviderId { get; set; } = ProviderConfig.OllamaId;
        public string SelectedEmbeddingProviderId { get; set; } = ProviderConfig.OllamaId;
    }

    private sealed class FakeSecrets : ISecretStore
    {
        private readonly Dictionary<string, string> _map = new();
        public void Save(string providerId, string secret) => _map[providerId] = secret;
        public string? Load(string providerId) => _map.TryGetValue(providerId, out var s) ? s : null;
        public void Delete(string providerId) => _map.Remove(providerId);
    }

    private sealed class CapturingHandler(
        HttpStatusCode status, string body, Action<Uri?, string> capture) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var content = request.Content is not null ? await request.Content.ReadAsStringAsync(ct) : "";
            capture(request.RequestUri, content);
            return new HttpResponseMessage(status)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json")
            };
        }
    }
}

using System.ComponentModel;
using System.Net;
using System.Text.Json;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.App.Tests;

public class AddProviderViewModelOpenWebUITests
{
    [Theory]
    [InlineData(ProviderType.Anthropic)]
    [InlineData(ProviderType.OpenWebUI)]
    public async Task SelectedEmbedderCannotBeEditedToAChatOnlyType(ProviderType chatOnlyType)
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var existing = new ProviderConfig("p", ProviderType.OpenAICompatible, "P", "https://unit.example/v1", true, true, DateTime.UtcNow);
        store.SaveProvider(existing);
        var settings = new FakeSettings { SelectedEmbeddingProviderId = "p" };
        var secrets = new FakeSecrets();
        using var http = new HttpClient(new ProbeHandler(_ => throw new InvalidOperationException("Saving must not send HTTP.")));
        var router = new ProviderRouter(settings, store, secrets, new AINotebook.Core.Ollama.OllamaClient(), http);
        var vm = new AddProviderViewModel(router, store, secrets, existing, settings: settings);

        Assert.Equal(new[] { ProviderType.Ollama, ProviderType.OpenAI, ProviderType.OpenAICompatible }, vm.SelectableTypes);
        vm.SelectedType = chatOnlyType;
        vm.ApiKey = "draft-key";
        Assert.False(vm.CanSave);
        Assert.Null(await vm.SaveConfirmedAsync(acknowledgePrivacy: true));
        Assert.Equal(existing.Type, store.Provider("p")!.Type);
        Assert.Equal("p", settings.SelectedEmbeddingProviderId);
        Assert.Null(secrets.Load("p"));

        // Once Settings has confirmed a different embedder, all types are
        // available again for this provider without silently moving selection.
        settings.SelectedEmbeddingProviderId = ProviderConfig.OllamaId;
        Assert.Equal(AddProviderViewModel.AllTypes, vm.SelectableTypes);
        Assert.True(vm.CanSave);
    }

    [Fact]
    public void DefaultOllamaFormHasLocalRootAndOnlyNeedsAName()
    {
        var vm = MakeVm();
        Assert.Equal(ProviderType.Ollama, vm.SelectedType);
        Assert.Equal(ProviderType.Ollama.DefaultBaseUrl(), vm.BaseUrl);
        Assert.False(vm.CanSave);
        vm.Name = "Local Ollama";
        Assert.True(vm.CanSave);
        Assert.Equal("", vm.ApiKey);
    }

    [Fact]
    public void CompatiblePresetsKeepExactRootsAndAllowKeylessLocalServers()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory,
            "SharedFixtures", "contracts", "provider-presets-v1.json")));
        foreach (var c in fixture.RootElement.GetProperty("cases").EnumerateArray())
        {
            var vm = MakeVm();
            vm.SelectedType = ProviderType.OpenAICompatible;
            vm.Name = "P";
            vm.SelectedPresetId = c.GetProperty("name").GetString()!;
            Assert.Equal(c.GetProperty("baseURL").GetString(), vm.BaseUrl);
            Assert.Equal(c.GetProperty("helpKey").GetString(), vm.PresetHelp);
            vm.ApiKey = "";
            if (vm.SelectedPresetId is "lmstudio" or "vllm") Assert.True(vm.CanSave);
            Assert.Null(vm.ProbeResult);
        }
    }

    [Fact]
    public void CustomPreservesAnEditedProxyRoot()
    {
        var vm = MakeVm();
        vm.SelectedType = ProviderType.OpenAICompatible;
        vm.SelectedPresetId = "lmstudio";
        vm.BaseUrl = "https://proxy.example/custom/root";
        vm.SelectedPresetId = "custom";
        Assert.Equal("https://proxy.example/custom/root", vm.BaseUrl);
        Assert.Equal("providerPresetCustomHelp", vm.PresetHelp);
    }

    [Theory]
    [InlineData(ProviderType.OpenAI)]
    [InlineData(ProviderType.Anthropic)]
    public void RequiredProviderKeysAndInvalidRootsPreventSave(ProviderType type)
    {
        var vm = MakeVm();
        vm.SelectedType = type;
        vm.Name = "P";
        Assert.False(vm.CanSave);
        vm.ApiKey = "key";
        Assert.True(vm.CanSave);
        vm.BaseUrl += "?secret=no";
        Assert.False(vm.CanSave);
    }

    [Theory]
    [InlineData(404, ProviderProbeStatus.ListingUnsupported, false)]
    [InlineData(401, ProviderProbeStatus.Failed, false)]
    [InlineData(200, ProviderProbeStatus.Verified, true)]
    public async Task ProbeUsesTypedListingStatus(int status, ProviderProbeStatus expected, bool success)
    {
        using var store = new NotebookStore(StorePath.InMemory);
        using var http = new HttpClient(new ProbeHandler(_ => Task.FromResult(new HttpResponseMessage((HttpStatusCode)status)
            { Content = new StringContent("{\"data\":[]}") })));
        var vm = MakeProbeVm(store, http);
        await vm.TestAsync();
        Assert.Equal(expected, vm.ProbeResult!.Status);
        Assert.Equal(success, vm.TestSucceeded);
        Assert.False(vm.ProbeResult.GenerationVerified);
    }

    [Theory]
    [InlineData("root")]
    [InlineData("key")]
    [InlineData("type")]
    [InlineData("preset")]
    public async Task EditingProbeInputsDiscardsPendingResult(string field)
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var pending = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var http = new HttpClient(new ProbeHandler(_ => pending.Task));
        var vm = MakeProbeVm(store, http);
        var probing = vm.TestAsync();
        switch (field)
        {
            case "root": vm.BaseUrl = "https://other.example"; break;
            case "key": vm.ApiKey = "replacement"; break;
            case "type": vm.SelectedType = ProviderType.OpenWebUI; break;
            case "preset": vm.SelectedPresetId = "vllm"; break;
        }
        pending.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"data\":[]}") });
        await probing;
        Assert.Null(vm.ProbeResult);
        Assert.False(vm.TestSucceeded);
        Assert.False(vm.IsTesting);
    }

    [Fact]
    public async Task EditingRetainsSavedKeyConsentAndExactRoot()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var existing = new ProviderConfig("p", ProviderType.OpenAI, "P", "https://unit.example/v1", true, true, DateTime.UtcNow);
        store.SaveProvider(existing);
        var secrets = new FakeSecrets();
        secrets.Save("p", "retained-key");
        using var http = new HttpClient(new ProbeHandler(_ => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            { Content = new StringContent("{\"data\":[]}") })));
        var router = new ProviderRouter(new FakeSettings(), store, secrets, new AINotebook.Core.Ollama.OllamaClient(), http);
        var vm = new AddProviderViewModel(router, store, secrets, existing);
        vm.BaseUrl = "https://unit.example/proxy/";
        Assert.True(vm.CanSave);
        var saved = await vm.SaveConfirmedAsync(false);
        Assert.Equal("retained-key", secrets.Load("p"));
        Assert.Equal("https://unit.example/proxy", saved!.BaseUrl);
        Assert.True(store.Provider("p")!.PrivacyAcknowledged);
    }

    [Theory]
    [InlineData(ProviderType.OpenWebUI)]
    [InlineData(ProviderType.OpenAICompatible)]
    public async Task EditingUnacknowledgedProviderRecordsAcceptedPrivacyGate(ProviderType type)
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var existing = new ProviderConfig("p", type, "P", "https://unit.example/v1", true, false, DateTime.UtcNow);
        store.SaveProvider(existing);
        var secrets = new FakeSecrets();
        using var http = new HttpClient(new ProbeHandler(_ => throw new InvalidOperationException("Saving must not send HTTP.")));
        var router = new ProviderRouter(new FakeSettings(), store, secrets, new AINotebook.Core.Ollama.OllamaClient(), http);
        var vm = new AddProviderViewModel(router, store, secrets, existing);

        var saved = await vm.SaveConfirmedAsync(acknowledgePrivacy: true);

        Assert.NotNull(saved);
        Assert.True(saved.PrivacyAcknowledged);
        Assert.True(store.Provider("p")!.PrivacyAcknowledged);
        Assert.Null(secrets.Load("p"));
    }

    [Fact]
    public void AllTypes_offers_openwebui()
    {
        Assert.Contains(ProviderType.OpenWebUI, AddProviderViewModel.AllTypes);
    }

    [Fact]
    public void CanSave_allows_new_openwebui_without_api_key()
    {
        var vm = MakeVm();
        vm.SelectedType = ProviderType.OpenWebUI;
        vm.Name = "LAN server";
        vm.BaseUrl = "http://192.168.1.50:3000";
        vm.ApiKey = "";
        Assert.True(vm.CanSave);
    }

    [Fact]
    public void CanSave_still_requires_key_for_new_openai()
    {
        var vm = MakeVm();
        vm.SelectedType = ProviderType.OpenAI;
        vm.Name = "OpenAI";
        vm.BaseUrl = "https://api.openai.com";
        vm.ApiKey = "";
        Assert.False(vm.CanSave);
    }

    // ── FR-A8: keyless consent-recording hole ───────────────────────────────
    //
    // SaveConfirmedAsync used to acknowledge privacy only when ApiKey was
    // non-empty, so a keyless OpenWebUI save (auth disabled — CanSave allows
    // it, see above) passed the gate but recorded nothing. It now takes an
    // explicit `acknowledgePrivacy` flag, independent of whether a key was
    // entered.

    [Fact]
    public async Task SaveConfirmedAsync_records_consent_for_keyless_openwebui_when_acknowledged()
    {
        var (vm, store) = MakeVmWithStore();
        vm.SelectedType = ProviderType.OpenWebUI;
        vm.Name = "LAN server";
        vm.BaseUrl = "http://192.168.1.50:3000";
        vm.ApiKey = ""; // keyless — auth disabled on this OpenWebUI instance

        var saved = await vm.SaveConfirmedAsync(acknowledgePrivacy: true);

        Assert.NotNull(saved);
        var persisted = store.Provider(saved!.Id);
        Assert.NotNull(persisted);
        Assert.True(persisted!.PrivacyAcknowledged,
            "a keyless save must still record consent when the gate was accepted");
    }

    [Fact]
    public async Task SaveConfirmedAsync_does_not_record_consent_when_gate_not_accepted()
    {
        var (vm, store) = MakeVmWithStore();
        vm.SelectedType = ProviderType.OpenWebUI;
        vm.Name = "LAN server";
        vm.BaseUrl = "http://192.168.1.50:3000";
        vm.ApiKey = "";

        var saved = await vm.SaveConfirmedAsync(acknowledgePrivacy: false);

        Assert.NotNull(saved);
        var persisted = store.Provider(saved!.Id);
        Assert.NotNull(persisted);
        Assert.False(persisted!.PrivacyAcknowledged);
    }

    // ── FR-A8: type-change consent hole (dialog's OriginalType support) ─────
    //
    // AddProviderDialog.OnClosing re-gates consent when editing a provider
    // whose type changed (see Views/AddProviderDialog.xaml.cs). That decision
    // needs the type as it existed BEFORE this edit session — OriginalType —
    // since SelectedType is mutated live as the user changes the picker.

    [Fact]
    public void OriginalType_is_null_in_add_mode()
    {
        var vm = MakeVm();
        Assert.Null(vm.OriginalType);
    }

    [Fact]
    public void OriginalType_reflects_pre_edit_type_and_is_unaffected_by_later_SelectedType_changes()
    {
        var (vm, _) = MakeVmWithStore(existingType: ProviderType.OpenAI);

        Assert.Equal(ProviderType.OpenAI, vm.OriginalType);

        vm.SelectedType = ProviderType.Anthropic; // simulate the user switching the type picker
        Assert.Equal(ProviderType.Anthropic, vm.SelectedType);
        Assert.Equal(ProviderType.OpenAI, vm.OriginalType); // unchanged — this is the pre-edit snapshot
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static (AddProviderViewModel vm, NotebookStore store) MakeVmWithStore(
        ProviderType? existingType = null)
    {
        var store = new NotebookStore(StorePath.InMemory);
        var router = new ProviderRouter(new FakeSettings(), store, new FakeSecrets(),
            new AINotebook.Core.Ollama.OllamaClient(), new HttpClient());

        ProviderConfig? existing = null;
        if (existingType is { } t)
        {
            existing = new ProviderConfig(
                Guid.NewGuid().ToString(), t, "Existing", "https://example.com",
                true, true, DateTime.UtcNow); // saved + already acknowledged, pre-edit
            store.SaveProvider(existing);
        }

        return (new AddProviderViewModel(router, store, new FakeSecrets(), existing), store);
    }

    private static AddProviderViewModel MakeVm()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var router = new ProviderRouter(new FakeSettings(), store, new FakeSecrets(),
            new AINotebook.Core.Ollama.OllamaClient(), new HttpClient());
        return new AddProviderViewModel(router, store, new FakeSecrets());
    }

    private static AddProviderViewModel MakeProbeVm(NotebookStore store, HttpClient http)
    {
        var secrets = new FakeSecrets();
        var router = new ProviderRouter(new FakeSettings(), store, secrets, new AINotebook.Core.Ollama.OllamaClient(), http);
        return new AddProviderViewModel(router, store, secrets)
        {
            SelectedType = ProviderType.OpenAICompatible, Name = "P", BaseUrl = "https://unit.example/v1"
        };
    }

    private sealed class ProbeHandler(Func<CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            => respond(cancellationToken);
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
}

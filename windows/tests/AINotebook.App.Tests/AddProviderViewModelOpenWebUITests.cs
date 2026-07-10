using System.ComponentModel;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.App.Tests;

public class AddProviderViewModelOpenWebUITests
{
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
}

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

    // ── Helpers ──────────────────────────────────────────────────────────────

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
    }

    private sealed class FakeSecrets : ISecretStore
    {
        private readonly Dictionary<string, string> _map = new();
        public void Save(string providerId, string secret) => _map[providerId] = secret;
        public string? Load(string providerId) => _map.TryGetValue(providerId, out var s) ? s : null;
        public void Delete(string providerId) => _map.Remove(providerId);
    }
}

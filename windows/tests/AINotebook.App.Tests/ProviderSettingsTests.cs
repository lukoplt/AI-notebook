using System.ComponentModel;
using System.Net;
using System.Text.Json;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.App.Tests;

public class ProviderSettingsTests
{
    [Theory]
    [InlineData("transport", "ProviderConnectionFailed")]
    [InlineData("decoding", "ProviderResponseInvalid")]
    [InlineData("requestFailed", "ProviderRequestFailed")]
    [InlineData("missingProvider", "ProviderSelectionUnavailable")]
    [InlineData("disabledProvider", "ProviderSelectionUnavailable")]
    [InlineData("unsupportedEndpoint", "ProviderEndpointUnsupported")]
    [InlineData("invalidBaseURL", "ProviderInvalidRoot")]
    [InlineData("untrusted payload /secret/path", "ProviderRequestFailed")]
    [InlineData("HTTP 500. response body", "ProviderRequestFailed")]
    [InlineData("HTTP 500.", "HTTP 500.")]
    public void ProviderErrorsUseLocalizedSafeCategories(string code, string expected)
    {
        Assert.Equal(expected, ProviderErrorText.Format(code, key => key.ToString()));
    }

    [Theory]
    [InlineData("transport", "transport")]
    [InlineData("decoding", "decoding")]
    [InlineData("other", "requestFailed")]
    public async Task DiscoveryFailuresKeepSafeErrorCodes(string failure, string expected)
    {
        using var setup = new Setup();
        setup.Handler.BeforeResponse = () => throw failure switch
        {
            "transport" => new HttpRequestException("secret URL"),
            "decoding" => new JsonException("secret response"),
            _ => new InvalidOperationException("secret path")
        };
        await setup.Vm.RefreshChatModelsAsync();
        Assert.Equal(expected, setup.Vm.ChatModelsError);
        Assert.Equal(ProviderProbeStatus.Failed, setup.Vm.ChatListingStatus);
    }

    public static IEnumerable<object[]> PresetCases()
    {
        using var json = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "SharedFixtures", "contracts", "provider-presets-v1.json")));
        return json.RootElement.GetProperty("cases").EnumerateArray()
            .Select(c => new object[] { c.GetProperty("name").GetString()!, c.GetProperty("baseURL").GetString()!, c.GetProperty("helpKey").GetString()! }).ToArray();
    }

    [Theory]
    [MemberData(nameof(PresetCases))]
    public void PresetsRetainExactFixtureValues(string id, string root, string help)
    {
        var preset = Assert.Single(ProviderPresets.All.Where(p => p.Id == id));
        Assert.Equal(root, preset.BaseUrl); Assert.Equal(help, preset.HelpKey);
    }

    [Fact]
    public async Task DiscoveryKeepsRawIdsAndFailedRefreshPreservesSelectionAndDraft()
    {
        using var setup = new Setup();
        await setup.Vm.RefreshChatModelsAsync();
        var model = Assert.Single(setup.Vm.ChatModels);
        Assert.Equal("Friendly", model.Label);
        setup.Vm.SelectedChatModel = model.Id;
        setup.Vm.ChatModelDraft = "another/raw:tag";
        setup.Handler.Status = 401;
        await setup.Vm.RefreshChatModelsAsync();
        Assert.Equal("vendor/m:tag", setup.Settings.SelectedChatModel);
        Assert.Equal("another/raw:tag", setup.Vm.ChatModelDraft);
        Assert.NotNull(setup.Vm.ChatModelsError);
        setup.Vm.ChatModelDraft = "  "; Assert.False(setup.Vm.ApplyChatModelDraft());
        Assert.Equal("vendor/m:tag", setup.Settings.SelectedChatModel);
        setup.Vm.ChatModelDraft = "  New/Raw:Tag  "; Assert.True(setup.Vm.ApplyChatModelDraft());
        Assert.Equal("New/Raw:Tag", setup.Settings.SelectedChatModel);
    }

    [Fact]
    public async Task LimitsSaveResetAndInvalidDraftsRespectPair()
    {
        using var setup = new Setup();
        await setup.Vm.LoadLimitsAsync();
        setup.Vm.RuntimeContextDraft = "4096"; setup.Vm.MaxOutputTokensDraft = "333";
        await setup.Vm.SaveLimitsAsync();
        var limits = setup.Store.ProviderModelLimits("p", "m")!;
        Assert.Equal("user", limits.Source); Assert.Equal(4096, limits.RuntimeContext); Assert.Equal(333, limits.MaxOutputTokens);
        setup.Vm.RuntimeContextDraft = "333";
        await setup.Vm.SaveLimitsAsync(); Assert.NotNull(setup.Vm.LimitsError);
        Assert.Equal("333", setup.Vm.RuntimeContextDraft);
        Assert.Equal(limits, setup.Store.ProviderModelLimits("p", "m"));
        await setup.Vm.ResetLimitsAsync();
        Assert.Equal("auto", setup.Vm.Limits!.Source); Assert.True(setup.Vm.Limits.IsAssumed);
        Assert.Equal("8192", setup.Vm.RuntimeContextDraft); Assert.Equal("1024", setup.Vm.MaxOutputTokensDraft);
        setup.Vm.SelectedChatModel = "other:tag";
        await setup.Vm.LoadLimitsAsync();
        Assert.Equal("other:tag", setup.Vm.Limits!.Model);
        Assert.Equal("m", setup.Store.ProviderModelLimits("p", "m")!.Model);
    }

    [Fact]
    public async Task UnsupportedListingIsNeutralAndManualEmbeddingDraftAppliesOnlyExplicitly()
    {
        using var setup = new Setup(); setup.Handler.Status = 404;
        await setup.Vm.RefreshEmbeddingModelsAsync();
        Assert.Equal(ProviderProbeStatus.ListingUnsupported, setup.Vm.EmbeddingListingStatus);
        Assert.Equal("embed", setup.Settings.SelectedEmbeddingModel);
        setup.Vm.EmbeddingModelDraft = " new/embed:tag ";
        Assert.Equal("embed", setup.Settings.SelectedEmbeddingModel);
        Assert.True(setup.Vm.ApplyEmbeddingModelDraft()); Assert.Equal("new/embed:tag", setup.Settings.SelectedEmbeddingModel);
        setup.Vm.EmbeddingModelDraft = " "; Assert.False(setup.Vm.ApplyEmbeddingModelDraft());
    }

    [Fact]
    public async Task EmbeddingPickerExcludesChatOnlyProviders()
    {
        using var setup = new Setup();
        setup.Store.SaveProvider(new("a", ProviderType.Anthropic, "A", "https://host", true, true, DateTime.UtcNow));
        setup.Store.SaveProvider(new("w", ProviderType.OpenWebUI, "W", "https://host", true, true, DateTime.UtcNow));
        await setup.Vm.RefreshProvidersAsync();
        Assert.Contains(setup.Vm.Providers, p => p.Id == "a");
        Assert.DoesNotContain(setup.Vm.EmbeddingProviders, p => !p.Type.SupportsEmbeddings());
        Assert.Contains(setup.Vm.EmbeddingProviders, p => p.Id == "p");
    }

    [Fact]
    public async Task StaleModelRefreshCannotReplaceNewProviderModels()
    {
        using var setup = new Setup();
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        setup.Handler.BeforeResponse = async () => { started.TrySetResult(); await resume.Task; };
        var old = setup.Vm.RefreshChatModelsAsync(); await started.Task;
        setup.Store.SaveProvider(new("q", ProviderType.OpenAICompatible, "Q", "https://other/v1", true, true, DateTime.UtcNow));
        setup.Vm.SelectedChatProviderId = "q";
        setup.Handler.BeforeResponse = null; setup.Handler.Body = "{\"data\":[{\"id\":\"new\"}]}";
        await setup.Vm.RefreshChatModelsAsync();
        resume.SetResult(); await old;
        Assert.Equal("new", Assert.Single(setup.Vm.ChatModels).Id);
    }

    [Fact]
    public async Task StaleLimitsFailureAfterRootEditIsDiscarded()
    {
        using var setup = new Setup();
        var config = new ProviderConfig("p", ProviderType.Ollama, "P", "http://old.example", true, true, DateTime.UtcNow);
        setup.Store.SaveProvider(config);
        setup.Handler.Status = 500;
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        setup.Handler.BeforeResponse = async () => { started.TrySetResult(); await resume.Task; };
        var old = setup.Vm.LoadLimitsAsync(); await started.Task;
        setup.Store.SaveProvider(config with { BaseUrl = "http://new.example" });
        resume.SetResult(); await old;
        Assert.Null(setup.Vm.LimitsError);
        Assert.Null(setup.Vm.Limits);
        Assert.False(setup.Vm.IsLoadingLimits);
    }

    private sealed class Setup : IDisposable
    {
        internal readonly NotebookStore Store = new(StorePath.InMemory);
        internal readonly FakeSettings Settings = new();
        internal readonly Handler Handler = new();
        internal readonly HttpClient Http;
        internal readonly SettingsViewModel Vm;
        internal Setup()
        {
            Store.SaveProvider(new("p", ProviderType.OpenAICompatible, "P", "https://host/v1", true, true, DateTime.UtcNow));
            Http = new HttpClient(Handler);
            var router = new ProviderRouter(Settings, Store, new Secrets(), new OllamaClient(Http), Http);
            Vm = new(Settings, Store, router, new EmbeddingWorker(new Embedder(Store, router, "p:embed")), new UpdateChecker(Http), new UpdateState());
        }
        public void Dispose() { Http.Dispose(); Store.Dispose(); }
    }
    private sealed class Handler : HttpMessageHandler
    {
        internal int Status = 200;
        internal string Body = "{\"data\":[{\"id\":\"vendor/m:tag\",\"name\":\"Friendly\"}]}";
        internal Func<Task>? BeforeResponse;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var body = Body; var status = Status;
            if (BeforeResponse is { } before) await before();
            return new((HttpStatusCode)status) { Content = new StringContent(body) };
        }
    }
    private sealed class Secrets : ISecretStore
    {
        public string? Load(string id) => null;
        public void Save(string id, string secret) { }
        public void Delete(string id) { }
    }
    private sealed class FakeSettings : ISettingsService
    {
        public event PropertyChangedEventHandler? PropertyChanged { add { } remove { } }
        public AppLanguage Language { get; set; } = AppLanguage.English;
        public bool HasCompletedOnboarding { get; set; } = true;
        public string SelectedChatProviderId { get; set; } = "p";
        public string SelectedChatModel { get; set; } = "m";
        public string SelectedEmbeddingProviderId { get; set; } = "p";
        public string SelectedEmbeddingModel { get; set; } = "embed";
        public bool AutoCheckUpdates { get; set; }
        public DateTimeOffset? LastUpdateCheckUtc { get; set; }
        public bool WebSearchEnabled { get; set; }
        public string RightPanel { get; set; } = "";
        public double RightPanelWidth { get; set; } = 360;
    }
}

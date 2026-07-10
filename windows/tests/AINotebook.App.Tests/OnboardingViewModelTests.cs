using System.ComponentModel;
using System.Runtime.CompilerServices;
using AINotebook.App.Onboarding;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using Xunit;

namespace AINotebook.App.Tests;

internal sealed class OnbFakeSettings : ISettingsService
{
    public event PropertyChangedEventHandler? PropertyChanged;
    public AppLanguage Language { get; set; } = AppLanguage.English;
    public bool HasCompletedOnboarding { get; set; }
    public string SelectedChatModel { get; set; } = "llama3.2:3b";
    public string SelectedEmbeddingModel { get; set; } = "nomic-embed-text";
    public string SelectedChatProviderId { get; set; } = ProviderConfig.OllamaId;
    public string SelectedEmbeddingProviderId { get; set; } = ProviderConfig.OllamaId;
    public bool AutoCheckUpdates { get; set; } = true;
    public DateTimeOffset? LastUpdateCheckUtc { get; set; }
}

internal sealed class FakeOllama : IOllamaOnboarding
{
    private int _detectCalls;
    public int DetectTrueAfter { get; set; } = 1; // becomes reachable on the Nth probe
    public Func<string, IEnumerable<OllamaPullEvent>>? PullScript { get; set; }
    public Exception? PullThrows { get; set; }

    public Task<bool> DetectAsync(CancellationToken ct = default)
    {
        _detectCalls++;
        return Task.FromResult(_detectCalls >= DetectTrueAfter);
    }

    public async IAsyncEnumerable<OllamaPullEvent> PullModelAsync(
        string name, [EnumeratorCancellation] CancellationToken ct = default)
    {
        if (PullThrows is not null) throw PullThrows;
        foreach (var ev in PullScript?.Invoke(name) ?? Array.Empty<OllamaPullEvent>())
        {
            yield return ev;
            await Task.Yield();
        }
    }
}

public class OnboardingViewModelTests
{
    private static OnboardingViewModel Make(FakeOllama ollama, OnbFakeSettings? settings = null)
        => new(ollama, settings ?? new OnbFakeSettings(), dispatcher: null);

    [Fact]
    public void Advance_walks_the_state_machine_and_clamps_at_done()
    {
        var vm = Make(new FakeOllama());
        Assert.Equal(OnboardingStep.Welcome, vm.Step);
        vm.Advance(); Assert.Equal(OnboardingStep.DetectOllama, vm.Step);
        vm.Advance(); Assert.Equal(OnboardingStep.PickModels, vm.Step);
        vm.Advance(); Assert.Equal(OnboardingStep.PullModels, vm.Step);
        vm.Advance(); Assert.Equal(OnboardingStep.Done, vm.Step);
        vm.Advance(); Assert.Equal(OnboardingStep.Done, vm.Step); // clamps
    }

    [Fact]
    public async Task Detection_flips_reachable_when_ollama_comes_up()
    {
        var ollama = new FakeOllama { DetectTrueAfter = 1 };
        var vm = Make(ollama);
        Assert.False(vm.IsOllamaReachable);
        vm.StartDetectionPolling();
        // Poll runs on a Task; wait briefly for the first probe.
        for (int i = 0; i < 50 && !vm.IsOllamaReachable; i++) await Task.Delay(20);
        vm.StopDetectionPolling();
        Assert.True(vm.IsOllamaReachable);
    }

    [Fact]
    public async Task Pull_updates_fractions_and_forces_one_on_terminal_success()
    {
        var ollama = new FakeOllama
        {
            PullScript = name => new[]
            {
                new OllamaPullEvent("pulling", Total: 100, Completed: 50),   // 0.5
                new OllamaPullEvent("success")                              // terminal
            }
        };
        var vm = Make(ollama);
        await vm.RunModelPullsAsync();
        Assert.Equal(1.0, vm.ChatPullFraction);
        Assert.Equal(1.0, vm.EmbeddingPullFraction);
        Assert.Equal("success", vm.ChatPullStatus);
        Assert.Equal("success", vm.EmbeddingPullStatus);
        Assert.Equal(OnboardingStep.Done, vm.Step); // both succeeded → advance
        Assert.Null(vm.PullError);
    }

    [Fact]
    public async Task Pull_error_sets_PullError_and_does_not_advance()
    {
        var ollama = new FakeOllama { PullThrows = new InvalidOperationException("boom") };
        var vm = Make(ollama);
        vm.Step = OnboardingStep.PullModels;
        await vm.RunModelPullsAsync();
        Assert.Equal("boom", vm.PullError);
        Assert.Equal(OnboardingStep.PullModels, vm.Step); // no advance on error
    }

    [Fact]
    public void MarkCompleted_persists_flag()
    {
        var settings = new OnbFakeSettings();
        var vm = Make(new FakeOllama(), settings);
        vm.MarkCompleted();
        Assert.True(settings.HasCompletedOnboarding);
    }
}

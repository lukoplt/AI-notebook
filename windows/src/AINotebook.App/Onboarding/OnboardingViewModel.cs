using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;

namespace AINotebook.App.Onboarding;

public sealed partial class OnboardingViewModel : ObservableObject
{
    private readonly IOllamaOnboarding _client;
    private readonly ISettingsService _settings;
    private readonly DispatcherQueue? _dispatcher;
    private CancellationTokenSource? _pollCts;

    [ObservableProperty]
    public partial OnboardingStep Step { get; set; } = OnboardingStep.Welcome;

    [ObservableProperty]
    public partial bool IsOllamaReachable { get; set; }

    [ObservableProperty]
    public partial double ChatPullFraction { get; set; }

    [ObservableProperty]
    public partial string ChatPullStatus { get; set; } = "";

    [ObservableProperty]
    public partial double EmbeddingPullFraction { get; set; }

    [ObservableProperty]
    public partial string EmbeddingPullStatus { get; set; } = "";

    [ObservableProperty]
    public partial string? PullError { get; set; }

    // Production DI ctor: wraps the shared OllamaClient.
    public OnboardingViewModel(OllamaClient client, ISettingsService settings)
        : this(new OllamaOnboardingAdapter(client), settings, DispatcherQueue.GetForCurrentThread())
    {
    }

    // Test ctor: inject a fake transport + optional dispatcher (null = run inline).
    internal OnboardingViewModel(IOllamaOnboarding client, ISettingsService settings, DispatcherQueue? dispatcher)
    {
        _client = client;
        _settings = settings;
        _dispatcher = dispatcher;
    }

    private void OnUi(Action action)
    {
        if (_dispatcher is null) action();
        else _dispatcher.TryEnqueue(() => action());
    }

    public void Advance()
    {
        if (Step < OnboardingStep.Done)
            Step = (OnboardingStep)((int)Step + 1);
    }

    // MARK: Step 2 — detect Ollama (poll every 2s until reachable).
    public void StartDetectionPolling()
    {
        _pollCts?.Cancel();
        _pollCts = new CancellationTokenSource();
        var ct = _pollCts.Token;
        _ = Task.Run(async () =>
        {
            while (!ct.IsCancellationRequested)
            {
                var up = await _client.DetectAsync(ct).ConfigureAwait(false);
                OnUi(() => IsOllamaReachable = up);
                if (up) break;
                try { await Task.Delay(TimeSpan.FromSeconds(2), ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { break; }
            }
        }, ct);
    }

    public void StopDetectionPolling()
    {
        _pollCts?.Cancel();
        _pollCts = null;
    }

    [RelayCommand]
    public async Task OpenOllamaDownloadAsync()
    {
        await Windows.System.Launcher.LaunchUriAsync(new Uri("https://ollama.com/download"));
    }

    // MARK: Step 4 — pull models sequentially (chat then embedding).
    public async Task RunModelPullsAsync(CancellationToken ct = default)
    {
        PullError = null;
        var chatModel = _settings.SelectedChatModel;
        var embedModel = _settings.SelectedEmbeddingModel;

        try
        {
            ChatPullStatus = "Starting…";
            await foreach (var ev in _client.PullModelAsync(chatModel, ct).ConfigureAwait(false))
            {
                ChatPullStatus = ev.Status;
                ChatPullFraction = ev.FractionComplete ?? ChatPullFraction;
                if (ev.IsTerminalSuccess) ChatPullFraction = 1.0;
            }

            EmbeddingPullStatus = "Starting…";
            await foreach (var ev in _client.PullModelAsync(embedModel, ct).ConfigureAwait(false))
            {
                EmbeddingPullStatus = ev.Status;
                EmbeddingPullFraction = ev.FractionComplete ?? EmbeddingPullFraction;
                if (ev.IsTerminalSuccess) EmbeddingPullFraction = 1.0;
            }

            Advance(); // → Done
        }
        catch (Exception ex)
        {
            PullError = ex.Message;
        }
    }

    public void MarkCompleted()
    {
        _settings.HasCompletedOnboarding = true;
    }
}

using AINotebook.Core.Ollama;

namespace AINotebook.App.Onboarding;

/// <summary>
/// Onboarding-only seam over OllamaClient (DetectAsync + PullModelAsync) so the
/// view model is unit-testable with a fake. OllamaClient is wrapped by
/// OllamaOnboardingAdapter; Core is unchanged.
/// </summary>
public interface IOllamaOnboarding
{
    Task<bool> DetectAsync(CancellationToken ct = default);
    IAsyncEnumerable<OllamaPullEvent> PullModelAsync(string name, CancellationToken ct = default);
}

public sealed class OllamaOnboardingAdapter : IOllamaOnboarding
{
    private readonly OllamaClient _client;
    public OllamaOnboardingAdapter(OllamaClient client) => _client = client;

    public Task<bool> DetectAsync(CancellationToken ct = default) => _client.DetectAsync(ct: ct);

    public IAsyncEnumerable<OllamaPullEvent> PullModelAsync(string name, CancellationToken ct = default)
        => _client.PullModelAsync(name, ct);
}

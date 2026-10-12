using AINotebook.Core.Ollama;

namespace AINotebook.Core.Providers;

public interface IChatSessionPreparing
{
    Task<ProviderChatSession> PrepareChatAsync(string? model = null, CancellationToken ct = default);
}

/// <summary>One turn's immutable public metadata and privately retained adapter.</summary>
public sealed class ProviderChatSession
{
    private readonly IChatStreaming _adapter;
    public string ProviderId { get; }
    public string Model { get; }
    public string StorageKey => ProviderId + ":" + Model;
    public ProviderModelLimits Limits { get; }

    internal ProviderChatSession(string providerId, string model, ProviderModelLimits limits, IChatStreaming adapter)
    {
        limits.Validate();
        ProviderId = providerId;
        Model = model;
        Limits = limits;
        _adapter = adapter;
    }

    public IAsyncEnumerable<string> StreamAsync(IReadOnlyList<ChatTurn> messages, CancellationToken ct = default) =>
        _adapter.StreamAsync(Model, messages, Limits.Options, ct);

    internal ProviderChatSession WithOptions(ChatRequestOptions options)
    {
        options.Validate();
        var limits = Limits with { RuntimeContext = options.RuntimeContext, MaxOutputTokens = options.MaxOutputTokens };
        limits.Validate();
        return new(ProviderId, Model, limits, _adapter);
    }
}

using AINotebook.Core.Models;
using AINotebook.Core.Providers;

namespace AINotebook.Core.Ollama;

public sealed record ChatTurn(ChatRole Role, string Content);

public interface IChatStreaming
{
    IAsyncEnumerable<string> StreamAsync(
        string model,
        IReadOnlyList<ChatTurn> messages,
        CancellationToken ct = default);

    IAsyncEnumerable<string> StreamAsync(
        string model,
        IReadOnlyList<ChatTurn> messages,
        ChatRequestOptions options,
        CancellationToken ct = default) => StreamAsync(model, messages, ct);
}

public interface IEmbeddingProducing
{
    Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default);
}

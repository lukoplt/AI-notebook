using AINotebook.Core.Models;

namespace AINotebook.Core.Ollama;

public sealed record ChatTurn(ChatRole Role, string Content);

public interface IChatStreaming
{
    IAsyncEnumerable<string> StreamAsync(
        string model,
        IReadOnlyList<ChatTurn> messages,
        CancellationToken ct = default);
}

public interface IEmbeddingProducing
{
    Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default);
}

using AINotebook.Core.Ollama;

namespace AINotebook.Core.Tests.Helpers;

public sealed class MockEmbeddingClient : IEmbeddingProducing
{
    private readonly Func<string, float[]> _vectorFor;
    public List<string[]> Calls { get; } = new();

    // Fixed vector per input string (default: deterministic 4-dim).
    public MockEmbeddingClient(Func<string, float[]>? vectorFor = null) =>
        _vectorFor = vectorFor ?? (s => new[] { 0.1f, 0.2f, 0.3f, 0.4f });

    public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
    {
        Calls.Add(inputs.ToArray());
        var result = inputs.Select(_vectorFor).ToArray();
        return Task.FromResult(result);
    }
}

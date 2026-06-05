using System.Runtime.CompilerServices;
using AINotebook.Core.Models;

namespace AINotebook.Core.Ollama;

public sealed class OllamaEmbeddingAdapter : IEmbeddingProducing
{
    private readonly OllamaClient _client;
    public OllamaEmbeddingAdapter(OllamaClient client) => _client = client;

    public async Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
    {
        var doubles = await _client.EmbedAsync(model, inputs, ct);
        var result = new float[doubles.Length][];
        for (var i = 0; i < doubles.Length; i++)
        {
            var src = doubles[i];
            var dst = new float[src.Length];
            for (var j = 0; j < src.Length; j++) dst[j] = (float)src[j];
            result[i] = dst;
        }
        return result;
    }
}

public sealed class OllamaChatAdapter : IChatStreaming
{
    private readonly OllamaClient _client;
    public OllamaChatAdapter(OllamaClient client) => _client = client;

    public async IAsyncEnumerable<string> StreamAsync(
        string model,
        IReadOnlyList<ChatTurn> messages,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        var wire = new OllamaChatMessage[messages.Count];
        for (var i = 0; i < messages.Count; i++)
            wire[i] = new OllamaChatMessage(RoleMap(messages[i].Role), messages[i].Content);

        await foreach (var chunk in _client.ChatAsync(model, wire, options: null, ct))
        {
            var delta = chunk.Message.Content;
            if (!string.IsNullOrEmpty(delta))
                yield return delta;
        }
    }

    private static OllamaChatRole RoleMap(ChatRole role) => role switch
    {
        ChatRole.System => OllamaChatRole.System,
        ChatRole.User => OllamaChatRole.User,
        ChatRole.Assistant => OllamaChatRole.Assistant,
        _ => OllamaChatRole.User,
    };
}

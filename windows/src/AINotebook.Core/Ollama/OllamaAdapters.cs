using System.Runtime.CompilerServices;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;

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

    public IAsyncEnumerable<string> StreamAsync(
        string model,
        IReadOnlyList<ChatTurn> messages,
        CancellationToken ct = default) => StreamAsync(model, messages, ChatRequestOptions.Defaults, ct);

    public async IAsyncEnumerable<string> StreamAsync(
        string model,
        IReadOnlyList<ChatTurn> messages,
        ChatRequestOptions options,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        options.Validate();
        var canonical = OpenAIStyleWire.CanonicalMessages(messages);
        var wire = new OllamaChatMessage[canonical.Count];
        for (var i = 0; i < canonical.Count; i++)
            wire[i] = new OllamaChatMessage(RoleMap(canonical[i].Role), canonical[i].Content);

        var wireOptions = new OllamaChatOptions(NumCtx: options.RuntimeContext, NumPredict: options.MaxOutputTokens);
        await foreach (var chunk in _client.ChatAsync(model, wire, wireOptions, ct))
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

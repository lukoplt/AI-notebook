using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Ollama;

public class OllamaAdapterTests
{
    private static OllamaClient Make(StubHttpMessageHandler stub) =>
        new(new HttpClient(stub) { BaseAddress = new Uri("http://127.0.0.1:11434") });

    [Fact]
    public async Task EmbeddingAdapterMapsDoublesToFloats()
    {
        var stub = new StubHttpMessageHandler().Json("""{"embeddings":[[0.5,0.25]]}""");
        IEmbeddingProducing adapter = new OllamaEmbeddingAdapter(Make(stub));
        var vectors = await adapter.EmbedAsync("m", new[] { "a" });
        Assert.Equal(new[] { 0.5f, 0.25f }, vectors[0]);
    }

    [Fact]
    public async Task ChatAdapterYieldsOnlyNonEmptyDeltasAndMapsRoles()
    {
        var stub = new StubHttpMessageHandler().Ndjson(new[]
        {
            """{"model":"m","created_at":"x","message":{"role":"assistant","content":"alpha "},"done":false}""",
            """{"model":"m","created_at":"x","message":{"role":"assistant","content":""},"done":false}""",
            """{"model":"m","created_at":"x","message":{"role":"assistant","content":"beta"},"done":false}""",
            """{"model":"m","created_at":"x","message":{"role":"assistant","content":""},"done":true}""",
        });
        IChatStreaming adapter = new OllamaChatAdapter(Make(stub));
        var deltas = new List<string>();
        await foreach (var d in adapter.StreamAsync("m",
            new[] { new ChatTurn(ChatRole.System, "sys"), new ChatTurn(ChatRole.User, "hi") }))
        {
            deltas.Add(d);
        }
        Assert.Equal(new[] { "alpha ", "beta" }, deltas); // empty deltas dropped
    }
}

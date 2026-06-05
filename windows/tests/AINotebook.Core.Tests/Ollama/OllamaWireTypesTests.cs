using System.Text.Json;
using AINotebook.Core.Ollama;
using Xunit;

namespace AINotebook.Core.Tests.Ollama;

public class OllamaWireTypesTests
{
    private static readonly JsonSerializerOptions Opts = OllamaJson.Options;

    // OllamaWireTypesTests.testChatRequestEncodes
    [Fact]
    public void ChatRequestEncodesStreamTrueAndMessages()
    {
        var req = new OllamaChatRequest(
            "llama3.2:3b",
            new[]
            {
                new OllamaChatMessage(OllamaChatRole.System, "be brief"),
                new OllamaChatMessage(OllamaChatRole.User, "hi"),
            },
            Stream: true,
            Options: null);

        var json = JsonSerializer.Serialize(req, Opts);
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        Assert.Equal("llama3.2:3b", root.GetProperty("model").GetString());
        Assert.True(root.GetProperty("stream").GetBoolean());
        Assert.Equal(2, root.GetProperty("messages").GetArrayLength());
        Assert.Equal("system", root.GetProperty("messages")[0].GetProperty("role").GetString());
        // options is null -> omitted entirely
        Assert.False(root.TryGetProperty("options", out _));
    }

    // OllamaWireTypesTests.testChatChunkDecode (validates created_at maps)
    [Fact]
    public void ChatChunkDecodesCreatedAtAndMessage()
    {
        const string json = """
        {"model":"llama3.2:3b","created_at":"2024-09-25T12:00:00Z","message":{"role":"assistant","content":"Hi"},"done":false}
        """;
        var chunk = JsonSerializer.Deserialize<OllamaChatChunk>(json, Opts)!;
        Assert.Equal("Hi", chunk.Message.Content);
        Assert.Equal(OllamaChatRole.Assistant, chunk.Message.Role);
        Assert.False(chunk.Done);
        Assert.Equal("2024-09-25T12:00:00Z", chunk.CreatedAt);
    }

    // OllamaWireTypesTests.testEmbedRequestEncodesArrayInput
    [Fact]
    public void EmbedRequestEncodesArrayInput()
    {
        var req = new OllamaEmbedRequest("nomic-embed-text", new[] { "a", "b" });
        var json = JsonSerializer.Serialize(req, Opts);
        using var doc = JsonDocument.Parse(json);
        Assert.Equal("nomic-embed-text", doc.RootElement.GetProperty("model").GetString());
        var input = doc.RootElement.GetProperty("input");
        Assert.Equal(JsonValueKind.Array, input.ValueKind);
        Assert.Equal("a", input[0].GetString());
        Assert.Equal("b", input[1].GetString());
    }

    // OllamaWireTypesTests.testEmbedResponseDecodes
    [Fact]
    public void EmbedResponseDecodesNestedDoubleArray()
    {
        const string json = """{"embeddings":[[0.1,0.2,0.3],[0.4,0.5,0.6]]}""";
        var resp = JsonSerializer.Deserialize<OllamaEmbedResponse>(json, Opts)!;
        Assert.Equal(2, resp.Embeddings.Length);
        Assert.Equal(new[] { 0.1, 0.2, 0.3 }, resp.Embeddings[0]);
    }
}

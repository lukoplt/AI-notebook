using System.Text.Json;
using AINotebook.Core.Ollama;
using Xunit;

namespace AINotebook.Core.Tests.Ollama;

public class OllamaModelTests
{
    private static readonly JsonSerializerOptions Opts = OllamaJson.Options;

    // OllamaModelTests.testDecodesTagListPayload
    [Fact]
    public void DecodesTagListPayload()
    {
        const string json = """
        {"models":[{"name":"llama3.2:3b","modified_at":"2024-09-25T12:00:00Z","size":2019377664,"digest":"abc123","details":{"format":"gguf","family":"llama","parameter_size":"3B","quantization_level":"Q4_K_M"}}]}
        """;
        var list = JsonSerializer.Deserialize<OllamaModelList>(json, Opts)!;
        Assert.Single(list.Models);
        var m = list.Models[0];
        Assert.Equal("llama3.2:3b", m.Name);
        Assert.Equal(2019377664L, m.Size);
        Assert.Equal("abc123", m.Digest);
        Assert.Equal("3B", m.Details.ParameterSize);
        Assert.Equal("2024-09-25T12:00:00Z", m.ModifiedAt);
    }

    // OllamaModelTests.testEmptyListDecodes
    [Fact]
    public void EmptyListDecodes()
    {
        var list = JsonSerializer.Deserialize<OllamaModelList>("""{"models":[]}""", Opts)!;
        Assert.Empty(list.Models);
    }
}

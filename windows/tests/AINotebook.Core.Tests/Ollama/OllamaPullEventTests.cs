using System.Text.Json;
using AINotebook.Core.Ollama;
using Xunit;

namespace AINotebook.Core.Tests.Ollama;

public class OllamaPullEventTests
{
    private static readonly JsonSerializerOptions Opts = OllamaJson.Options;

    // OllamaPullEventTests.testDecodeStartStatus
    [Fact]
    public void DecodeStartStatusLeavesProgressNull()
    {
        var ev = JsonSerializer.Deserialize<OllamaPullEvent>("""{"status":"pulling manifest"}""", Opts)!;
        Assert.Equal("pulling manifest", ev.Status);
        Assert.Null(ev.Total);
        Assert.Null(ev.Completed);
        Assert.Null(ev.Digest);
    }

    // OllamaPullEventTests.testDecodeProgressEvent
    [Fact]
    public void DecodeProgressEventComputesFraction()
    {
        const string json = """
        {"status":"downloading","digest":"sha256:abc","total":2019377664,"completed":1000000}
        """;
        var ev = JsonSerializer.Deserialize<OllamaPullEvent>(json, Opts)!;
        Assert.Equal("downloading", ev.Status);
        Assert.Equal("sha256:abc", ev.Digest);
        Assert.Equal(2019377664L, ev.Total);
        Assert.Equal(1000000L, ev.Completed);
        Assert.NotNull(ev.FractionComplete);
        Assert.Equal(1000000.0 / 2019377664.0, ev.FractionComplete!.Value, 9);
    }

    // OllamaPullEventTests.testFractionCompleteIsNilWhenMissing
    [Fact]
    public void FractionCompleteNullWhenFieldsMissing()
    {
        var ev = JsonSerializer.Deserialize<OllamaPullEvent>("""{"status":"verifying"}""", Opts)!;
        Assert.Null(ev.FractionComplete);
    }

    // OllamaPullEventTests.testIsTerminalSuccess
    [Fact]
    public void IsTerminalSuccessOnlyForSuccessStatus()
    {
        Assert.True(new OllamaPullEvent("success").IsTerminalSuccess);
        Assert.False(new OllamaPullEvent("downloading").IsTerminalSuccess);
    }
}

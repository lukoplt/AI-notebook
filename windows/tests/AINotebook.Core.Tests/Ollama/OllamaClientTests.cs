using System.Net.Http;
using AINotebook.Core.Ollama;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Ollama;

public class OllamaClientTests
{
    private static OllamaClient Make(StubHttpMessageHandler stub) =>
        new(new HttpClient(stub) { BaseAddress = new Uri("http://127.0.0.1:11434") });

    // OllamaClientDetectAndListTests.testDetectTrueOn200
    [Fact]
    public async Task DetectTrueOn200()
    {
        var client = Make(new StubHttpMessageHandler().Json("""{"models":[]}""", 200));
        Assert.True(await client.DetectAsync());
    }

    // OllamaClientDetectAndListTests.testDetectFalseOnConnectionRefused
    [Fact]
    public async Task DetectFalseOnConnectionRefused()
    {
        var client = Make(new StubHttpMessageHandler().ConnectionRefused());
        Assert.False(await client.DetectAsync());
    }

    // OllamaClientDetectAndListTests.testListModelsReturnsParsedList
    [Fact]
    public async Task ListModelsReturnsParsedList()
    {
        var stub = new StubHttpMessageHandler().Json(
            """{"models":[{"name":"llama3.2:3b","modified_at":"x","size":1,"digest":"d","details":{"format":"gguf","family":"llama","parameter_size":"3B","quantization_level":"Q4"}}]}""");
        var models = await Make(stub).ListModelsAsync();
        Assert.Single(models);
        Assert.Equal("llama3.2:3b", models[0].Name);
        Assert.Equal("3B", models[0].Details.ParameterSize);
    }

    // OllamaClientDetectAndListTests.testListModelsThrowsOnHttpError
    [Fact]
    public async Task ListModelsThrowsOnHttp500()
    {
        var stub = new StubHttpMessageHandler().Json("oops", 500);
        var ex = await Assert.ThrowsAsync<OllamaException.HttpStatus>(() => Make(stub).ListModelsAsync());
        Assert.Equal(500, ex.Code);
    }

    // OllamaClientEmbedTests.testEmbedReturnsVectors
    [Fact]
    public async Task EmbedReturnsVectors()
    {
        var stub = new StubHttpMessageHandler().Json("""{"embeddings":[[0.1,0.2],[0.3,0.4]]}""");
        var vectors = await Make(stub).EmbedAsync("nomic-embed-text", new[] { "a", "b" });
        Assert.Equal(new[] { 0.1, 0.2 }, vectors[0]);
        Assert.Equal(new[] { 0.3, 0.4 }, vectors[1]);
    }

    // OllamaClientEmbedTests.testEmbedThrowsOnHttp404
    [Fact]
    public async Task EmbedThrowsOnHttp404()
    {
        var stub = new StubHttpMessageHandler().Json("nope", 404);
        var ex = await Assert.ThrowsAsync<OllamaException.HttpStatus>(
            () => Make(stub).EmbedAsync("m", new[] { "a" }));
        Assert.Equal(404, ex.Code);
    }

    // OllamaClientChatTests.testChatStreamsChunksUntilDone
    [Fact]
    public async Task ChatStreamsChunksUntilDone()
    {
        var stub = new StubHttpMessageHandler().Ndjson(new[]
        {
            """{"model":"llama3.2:3b","created_at":"x","message":{"role":"assistant","content":"He"},"done":false}""",
            """{"model":"llama3.2:3b","created_at":"x","message":{"role":"assistant","content":"llo"},"done":false}""",
            """{"model":"llama3.2:3b","created_at":"x","message":{"role":"assistant","content":""},"done":true}""",
        });
        var joined = "";
        await foreach (var chunk in Make(stub).ChatAsync("llama3.2:3b",
            new[] { new OllamaChatMessage(OllamaChatRole.User, "hi") }))
        {
            joined += chunk.Message.Content;
        }
        Assert.Equal("Hello", joined);
    }

    // OllamaClientPullTests.testPullEmitsEventsThenCompletes
    [Fact]
    public async Task PullEmitsEventsThenCompletes()
    {
        var stub = new StubHttpMessageHandler().Ndjson(new[]
        {
            """{"status":"pulling manifest"}""",
            """{"status":"downloading","total":1000,"completed":500}""",
            """{"status":"downloading","total":1000,"completed":1000}""",
            """{"status":"success"}""",
        });
        var events = new List<OllamaPullEvent>();
        await foreach (var ev in Make(stub).PullModelAsync("llama3.2:3b"))
            events.Add(ev);
        Assert.Equal(4, events.Count);
        Assert.Equal("pulling manifest", events[0].Status);
        Assert.Equal("success", events[3].Status);
        Assert.True(events[3].IsTerminalSuccess);
    }

    // OllamaClientPullTests.testPullThrowsOnHttp500
    [Fact]
    public async Task PullThrowsOnHttp500()
    {
        var stub = new StubHttpMessageHandler().Json("nope", 500);
        var ex = await Assert.ThrowsAsync<OllamaException.HttpStatus>(async () =>
        {
            await foreach (var _ in Make(stub).PullModelAsync("x")) { }
        });
        Assert.Equal(500, ex.Code);
    }

    // OllamaClientDeleteTests.testDeleteSendsCorrectRequest
    [Fact]
    public async Task DeleteSendsCorrectJsonBody()
    {
        var stub = new StubHttpMessageHandler().Json("", 200);
        await Make(stub).DeleteModelAsync("llama3.2:3b");
        Assert.Equal(HttpMethod.Delete, stub.LastRequest!.Method);
        Assert.EndsWith("/api/delete", stub.LastRequest.RequestUri!.AbsolutePath);
        Assert.Equal("""{"name":"llama3.2:3b"}""", stub.LastRequestBody);
    }

    // OllamaClientDeleteTests.testDeleteThrowsOnHttp404
    [Fact]
    public async Task DeleteThrowsOnHttp404()
    {
        var stub = new StubHttpMessageHandler().Json("not found", 404);
        var ex = await Assert.ThrowsAsync<OllamaException.HttpStatus>(
            () => Make(stub).DeleteModelAsync("ghost"));
        Assert.Equal(404, ex.Code);
    }
}

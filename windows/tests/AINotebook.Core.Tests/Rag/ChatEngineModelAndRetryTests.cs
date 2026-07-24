using System.Runtime.CompilerServices;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

/// <summary>
/// Covers three ChatEngine defects found in review: the persisted model tag
/// ignored the per-call override, a 429's Retry-After was ignored, and the
/// caller was never told to discard a failed attempt's partial tokens.
/// </summary>
public class ChatEngineModelAndRetryTests : IDisposable
{
    private readonly NotebookStore _store;
    private readonly long _nbId;
    private readonly long _sessionId;

    public ChatEngineModelAndRetryTests()
    {
        _store = new NotebookStore(StorePath.InMemory);
        var nb = _store.CreateNotebook("N", "");
        _nbId = nb.Id!.Value;
        var src = _store.CreateSource(_nbId, SourceType.Text, "S", null, null);
        _store.ReplaceChunks(src.Id!.Value, new[] { new ChunkDraft("the sky is blue", 1, null) });
        _store.StoreEmbedding(_store.Chunks(src.Id!.Value)[0].Id!.Value, "emb", new EmbeddingVector(new[] { 1f, 0f }));
        _sessionId = _store.CreateChatSession(_nbId, "T").Id!.Value;
    }

    public void Dispose() => _store.Dispose();

    private ChatEngine Engine(IChatStreaming chat, int retries = 2, int backoffMs = 1)
    {
        var retriever = new Retriever(_store, new MockEmbeddingClient(_ => new[] { 1f, 0f }), "emb");
        return new ChatEngine(_store, retriever, chat, "default-model",
            retryAttempts: retries, retryBackoffMillis: backoffMs);
    }

    [Fact]
    public async Task PersistsTheOverrideModelNotTheEngineDefault()
    {
        var engine = Engine(new MockChatClient("hi"));

        var stored = await engine.SendAsync(_sessionId, _nbId, "q",
            model: "provider-guid:claude-x", onToken: _ => { });

        // Used to record "default-model" — the value captured when the engine
        // was built — even though the turn streamed via the override.
        Assert.Equal("provider-guid:claude-x", stored.Model);
        Assert.Equal("provider-guid:claude-x", _store.Messages(_sessionId).Last().Model);
    }

    [Fact]
    public async Task PersistsTheEngineDefaultWhenNoOverrideIsGiven()
    {
        var engine = Engine(new MockChatClient("hi"));

        var stored = await engine.SendAsync(_sessionId, _nbId, "q", onToken: _ => { });

        Assert.Equal("default-model", stored.Model);
    }

    [Fact]
    public async Task StreamsWithTheOverrideModel()
    {
        var chat = new ModelCapturingChat("hi");
        var engine = Engine(chat);

        await engine.SendAsync(_sessionId, _nbId, "q",
            model: "provider-guid:claude-x", onToken: _ => { });

        Assert.Equal("provider-guid:claude-x", chat.LastModel);
    }

    [Fact]
    public async Task OnRetryFiresOncePerFailedAttempt()
    {
        // Fails twice with a retryable error, then succeeds.
        var chat = new ErrorInjectingChat(failures: 2, () => new ProviderException("boom"), "ok");
        var engine = Engine(chat);

        var retries = 0;
        await engine.SendAsync(_sessionId, _nbId, "q",
            onToken: _ => { }, onRetry: () => retries++);

        Assert.Equal(3, chat.Attempts);
        Assert.Equal(2, retries);
    }

    [Fact]
    public async Task OnRetryIsNotFiredWhenTheFirstAttemptSucceeds()
    {
        var engine = Engine(new MockChatClient("hi"));

        var retries = 0;
        await engine.SendAsync(_sessionId, _nbId, "q",
            onToken: _ => { }, onRetry: () => retries++);

        Assert.Equal(0, retries);
    }

    [Fact]
    public async Task RetryAfterOnA429IsHonoredOverTheDefaultBackoff()
    {
        var wait = TimeSpan.FromMilliseconds(300);
        var chat = new ErrorInjectingChat(failures: 1, () => new ProviderRateLimitException("429", wait), "ok");
        // Backoff of 1ms: without honoring Retry-After this comes back almost
        // immediately, so elapsed time is what distinguishes the two.
        var engine = Engine(chat, retries: 2, backoffMs: 1);

        var started = Environment.TickCount64;
        await engine.SendAsync(_sessionId, _nbId, "q", onToken: _ => { });
        var elapsed = Environment.TickCount64 - started;

        Assert.Equal(2, chat.Attempts);
        Assert.True(elapsed >= 250, $"waited only {elapsed}ms — Retry-After was ignored");
    }

    [Fact]
    public async Task A429WithoutRetryAfterFallsBackToExponentialBackoff()
    {
        var chat = new ErrorInjectingChat(failures: 1, () => new ProviderRateLimitException("429"), "ok");
        var engine = Engine(chat, retries: 2, backoffMs: 1);

        await engine.SendAsync(_sessionId, _nbId, "q", onToken: _ => { });

        Assert.Equal(2, chat.Attempts);
    }
}

/// <summary>Throws the given error for the first N attempts, then streams.</summary>
public sealed class ErrorInjectingChat : IChatStreaming
{
    private readonly int _failures;
    private readonly Func<Exception> _error;
    private readonly string[] _tokens;
    public int Attempts { get; private set; }

    public ErrorInjectingChat(int failures, Func<Exception> error, params string[] tokens)
    {
        _failures = failures;
        _error = error;
        _tokens = tokens;
    }

#pragma warning disable CS1998 // the failure path throws before any await
    public async IAsyncEnumerable<string> StreamAsync(
        string model, IReadOnlyList<ChatTurn> messages,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        Attempts++;
        if (Attempts <= _failures) throw _error();
        foreach (var t in _tokens) yield return t;
    }
#pragma warning restore CS1998
}

/// <summary>Records the model string the engine streamed with.</summary>
public sealed class ModelCapturingChat : IChatStreaming
{
    private readonly string[] _tokens;
    public string? LastModel { get; private set; }

    public ModelCapturingChat(params string[] tokens) => _tokens = tokens;

#pragma warning disable CS1998
    public async IAsyncEnumerable<string> StreamAsync(
        string model, IReadOnlyList<ChatTurn> messages,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        LastModel = model;
        foreach (var t in _tokens) yield return t;
    }
#pragma warning restore CS1998
}

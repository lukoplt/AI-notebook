using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class ChatEngineTests
{
    private static (NotebookStore store, long nbId, long sessionId, long chunkId) Setup()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "S", null, null);
        store.ReplaceChunks(src.Id!.Value, new[] { new ChunkDraft("the sky is blue", 1, null) });
        var chunkId = store.Chunks(src.Id!.Value)[0].Id!.Value;
        store.StoreEmbedding(chunkId, "emb", new EmbeddingVector(new[] { 1f, 0f }));
        var session = store.CreateChatSession(nb.Id!.Value, "T");
        return (store, nb.Id!.Value, session.Id!.Value, chunkId);
    }

    // ChatEngineTests.testEndToEndStreamsTokensThenPersistsMessages
    [Fact]
    public async Task EndToEndStreamsTokensThenPersistsMessages()
    {
        var (store, nbId, sessionId, chunkId) = Setup();
        var emb = new MockEmbeddingClient(_ => new[] { 1f, 0f });
        var retriever = new Retriever(store, emb, "emb");
        var chat = new MockChatClient("The sky ", "is blue ", "[1].");
        var engine = new ChatEngine(store, retriever, chat, "chatmodel");

        var streamed = new List<string>();
        var final = await engine.SendAsync(sessionId, nbId, "what color is the sky?",
            onToken: t => streamed.Add(t));

        Assert.Equal(new[] { "The sky ", "is blue ", "[1]." }, streamed);
        Assert.Equal("The sky is blue [1].", final.Content);
        Assert.Equal(chunkId, final.Citations[0].ChunkId);

        var persisted = store.Messages(sessionId);
        Assert.Equal(2, persisted.Count);
        Assert.Equal(ChatRole.User, persisted[0].Role);
        Assert.Equal(ChatRole.Assistant, persisted[1].Role);

        // first turn system, last turn user with the userText
        var turns = chat.CapturedMessages[0];
        Assert.Single(chat.CapturedMessages);
        Assert.Equal(ChatRole.System, turns[0].Role);
        Assert.Equal(ChatRole.User, turns[^1].Role);
        Assert.Equal("what color is the sky?", turns[^1].Content);
    }

    // ChatEngineRetryTests.testRetriesOnceOnTimeoutThenSucceeds
    [Fact]
    public async Task RetriesOnceOnTimeoutThenSucceeds()
    {
        var (store, nbId, sessionId, _) = Setup();
        var emb = new MockEmbeddingClient(_ => new[] { 1f, 0f });
        var retriever = new Retriever(store, emb, "emb");
        var chat = new FlakyChat(failTimes: 1, finalToken: "ok");
        var engine = new ChatEngine(store, retriever, chat, "m",
            retryAttempts: 1, retryBackoffMillis: 1);

        var msg = await engine.SendAsync(sessionId, nbId, "q", onToken: _ => { });
        Assert.Equal("ok", msg.Content);
        Assert.Equal(2, chat.Attempts);
    }

    // ChatEngineRetryTests.testGivesUpAfterMaxAttempts
    [Fact]
    public async Task GivesUpAfterMaxAttempts()
    {
        var (store, nbId, sessionId, _) = Setup();
        var emb = new MockEmbeddingClient(_ => new[] { 1f, 0f });
        var retriever = new Retriever(store, emb, "emb");
        var chat = new FlakyChat(failTimes: 99);
        var engine = new ChatEngine(store, retriever, chat, "m",
            retryAttempts: 2, retryBackoffMillis: 1);

        await Assert.ThrowsAnyAsync<Exception>(() => engine.SendAsync(sessionId, nbId, "q", onToken: _ => { }));
        Assert.Equal(3, chat.Attempts); // retryAttempts + 1 total tries
    }

    // ChatEngineCurrentNoteContextTests.testCurrentNoteContextAppearsInSystemPrompt
    [Fact]
    public async Task CurrentNoteContextAppearsInSystemPrompt()
    {
        var (store, nbId, sessionId, _) = Setup();
        var emb = new MockEmbeddingClient(_ => new[] { 1f, 0f });
        var retriever = new Retriever(store, emb, "emb");
        var chat = new MockChatClient("ok");
        var engine = new ChatEngine(store, retriever, chat, "m");

        await engine.SendAsync(sessionId, nbId, "q", currentNoteContent: "flour 500g", onToken: _ => { });
        var systemTurn = chat.CapturedMessages[0][0];
        Assert.Contains("CURRENTLY OPEN NOTE", systemTurn.Content);
        Assert.Contains("flour 500g", systemTurn.Content);
    }

    // ChatEngineCurrentNoteContextTests.testNilCurrentNoteContextLeavesPromptUnchanged
    [Fact]
    public async Task NullCurrentNoteContextLeavesPromptUnchanged()
    {
        var (store, nbId, sessionId, _) = Setup();
        var emb = new MockEmbeddingClient(_ => new[] { 1f, 0f });
        var retriever = new Retriever(store, emb, "emb");
        var chat = new MockChatClient("ok");
        var engine = new ChatEngine(store, retriever, chat, "m");

        await engine.SendAsync(sessionId, nbId, "q", onToken: _ => { });
        Assert.DoesNotContain("CURRENTLY OPEN NOTE", chat.CapturedMessages[0][0].Content);
    }
}

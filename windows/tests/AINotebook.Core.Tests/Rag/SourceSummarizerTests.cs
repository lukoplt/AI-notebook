using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class SourceSummarizerTests
{
    // SourceSummarizerTests.testSummarizesPersistsAndReturns
    [Fact]
    public async Task SummarizesPersistsAndReturns()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("NB", "");
        var s = store.CreateSource(nb.Id!.Value, SourceType.Text, "X", null, null);
        store.ReplaceChunks(s.Id!.Value, new[]
        {
            new ChunkDraft("alpha apple", 2, null),
            new ChunkDraft("beta banana", 2, null),
        });
        var chat = new MockChatClient("This is ", "the summary.");
        var summarizer = new SourceSummarizer(store, chat, "m");

        var summary = await summarizer.SummarizeAsync(s.Id!.Value);

        Assert.Equal("This is the summary.", summary);
        Assert.Equal("This is the summary.", store.SourceSummary(s.Id!.Value));
        Assert.Single(chat.CapturedMessages);
        Assert.Equal(ChatRole.User, chat.CapturedMessages[0][0].Role);
    }

    // SourceSummarizerTests.testNoChunksReturnsEmptyWithoutCallingModel
    [Fact]
    public async Task NoChunksReturnsEmptyWithoutCallingModel()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("NB", "");
        var s = store.CreateSource(nb.Id!.Value, SourceType.Text, "X", null, null);
        var chat = new MockChatClient("unused");
        var summarizer = new SourceSummarizer(store, chat, "m");

        var summary = await summarizer.SummarizeAsync(s.Id!.Value);

        Assert.Equal("", summary);
        Assert.Empty(chat.CapturedMessages);
        Assert.Null(store.SourceSummary(s.Id!.Value));
    }
}

using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class NotebookStoreChatTests
{
    private static (NotebookStore store, long nb) Fresh()
    {
        var store = new NotebookStore(StorePath.InMemory);
        return (store, store.CreateNotebook("N").Id!.Value);
    }

    [Fact]
    public void EmptyTitleBecomesNewChat()
    {
        var (store, nb) = Fresh();
        using (store)
            Assert.Equal("New chat", store.CreateChatSession(nb, "   ").Title);
    }

    [Fact]
    public void SessionsOrderedByCreatedAtDesc()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            store.CreateChatSession(nb, "first");
            var second = store.CreateChatSession(nb, "second");
            Assert.Equal(second.Id, store.ChatSessions(nb)[0].Id);
        }
    }

    [Fact]
    public void MessagesAscendingAndCitationsRoundTrip()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var session = store.CreateChatSession(nb, "s");
            var sid = session.Id!.Value;
            store.AppendMessage(new ChatMessage(null, sid, ChatRole.User, "hi",
                Array.Empty<Citation>(), DateTime.UtcNow));
            store.AppendMessage(new ChatMessage(null, sid, ChatRole.Assistant, "answer [1]",
                new[] { new Citation(1, 42, 7, "snip") }, DateTime.UtcNow.AddMilliseconds(1)));
            var msgs = store.Messages(sid);
            Assert.Equal(2, msgs.Count);
            Assert.Equal(ChatRole.User, msgs[0].Role);
            Assert.Equal(ChatRole.Assistant, msgs[1].Role);
            var cit = Assert.Single(msgs[1].Citations);
            Assert.Equal(1, cit.Marker);
            Assert.Equal(42, cit.ChunkId);
            Assert.Equal(7, cit.SourceId);
            Assert.Equal("snip", cit.Snippet);
            Assert.Empty(msgs[0].Citations);
        }
    }

    [Fact]
    public void EmptyCitationsStoredAsNull()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var sid = store.CreateChatSession(nb, "s").Id!.Value;
            store.AppendMessage(new ChatMessage(null, sid, ChatRole.User, "x",
                Array.Empty<Citation>(), DateTime.UtcNow));
            var raw = Dapper.SqlMapper.ExecuteScalar<object?>(store.Connection,
                "SELECT citations_json FROM messages WHERE session_id=$sid",
                new { sid });
            Assert.True(raw is null || raw is DBNull);
        }
    }

    [Fact]
    public void DeleteChatSessionCascadesMessages()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var sid = store.CreateChatSession(nb, "s").Id!.Value;
            store.AppendMessage(new ChatMessage(null, sid, ChatRole.User, "x",
                Array.Empty<Citation>(), DateTime.UtcNow));
            store.DeleteChatSession(sid);
            Assert.Empty(store.Messages(sid));
        }
    }
}

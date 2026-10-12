using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

/// <summary>Parity with Tests/AINotebookCoreTests/ChatSessionStateTests.swift (retry after a failed send).</summary>
public class ChatSessionStateTests
{
    private static ChatMessage Message(long id, ChatRole role, string text) =>
        new(id, 1, role, text, Array.Empty<Citation>(), DateTime.UnixEpoch);

    [Fact]
    public void RetryAfterFailedSendRegeneratesASavedQuestion()
    {
        var saved = new[] { Message(1, ChatRole.User, "a"), Message(2, ChatRole.Assistant, "b"), Message(3, ChatRole.User, "q") };
        Assert.Equal(new ChatRetry.Regenerate(), ChatSessionState.RetryAfterFailedSend("q", saved));
        var unsaved = new[] { Message(1, ChatRole.User, "a"), Message(2, ChatRole.Assistant, "b") };
        Assert.Equal(new ChatRetry.Resend("q"), ChatSessionState.RetryAfterFailedSend("q", unsaved));
        Assert.Equal(new ChatRetry.Resend("q"), ChatSessionState.RetryAfterFailedSend("q", Array.Empty<ChatMessage>()));
        var other = new[] { Message(3, ChatRole.User, "different") };
        Assert.Equal(new ChatRetry.Resend("q"), ChatSessionState.RetryAfterFailedSend("q", other));
    }
    // UI redesign C1: rename + Stop (parity with ChatSessionStateTests.swift).

    [Fact]
    public void RenamedTitleTrimsAndIgnoresBlankOrUnchanged()
    {
        Assert.Equal("New", ChatSessionState.RenamedTitle("  New \n", "Old"));
        Assert.Null(ChatSessionState.RenamedTitle(" \n\t", "Old"));
        Assert.Null(ChatSessionState.RenamedTitle(" Old ", "Old"));
        Assert.Null(ChatSessionState.RenamedTitle(null, "Old"));
    }

    [Fact]
    public void StoppedAnswerKeepsStreamedTextOfANewTurnOnly()
    {
        Assert.Equal("  Partial **answer** [1]", ChatSessionState.StoppedAnswer("  Partial **answer** [1]\n\n", isReplacement: false));
        Assert.Null(ChatSessionState.StoppedAnswer(" \n ", isReplacement: false));
        Assert.Null(ChatSessionState.StoppedAnswer("", isReplacement: false));
        Assert.Null(ChatSessionState.StoppedAnswer("Partial", isReplacement: true));
    }

    [Fact]
    public void OnlyAnEmptyStoppedNewTurnReturnsItsQuestion()
    {
        Assert.True(ChatSessionState.ReturnsQuestion("", isReplacement: false));
        Assert.True(ChatSessionState.ReturnsQuestion(" \n ", isReplacement: false));
        Assert.True(ChatSessionState.ReturnsQuestion(null, isReplacement: false));
        Assert.False(ChatSessionState.ReturnsQuestion("Partial", isReplacement: false));
        Assert.False(ChatSessionState.ReturnsQuestion("", isReplacement: true));
    }

    [Fact]
    public void OrphanedQuestionIsTheNewestUserRowOfThisTurn()
    {
        var before = new[] { Message(1, ChatRole.User, "a"), Message(2, ChatRole.Assistant, "b") };
        Assert.Equal(3, ChatSessionState.OrphanedQuestionId("q", [.. before, Message(3, ChatRole.User, "q")], 2));
        Assert.Equal(1, ChatSessionState.OrphanedQuestionId("q", [Message(1, ChatRole.User, "q")], null));
        // Core never saved it (stopped before streaming): the history is unchanged.
        Assert.Null(ChatSessionState.OrphanedQuestionId("q", before, 2));
        // An older unanswered row with the same text is not this turn's.
        Assert.Null(ChatSessionState.OrphanedQuestionId("q", [Message(1, ChatRole.User, "q")], 1));
        Assert.Null(ChatSessionState.OrphanedQuestionId("q", [.. before, Message(3, ChatRole.User, "other")], 2));
        Assert.Null(ChatSessionState.OrphanedQuestionId("q",
            [.. before, Message(3, ChatRole.User, "q"), Message(4, ChatRole.Assistant, "x")], 2));
        Assert.Null(ChatSessionState.OrphanedQuestionId("q", Array.Empty<ChatMessage>(), null));
    }

    [Fact]
    public void StoppedCitationsResolveKnownMarkersOnceInOrder()
    {
        var map = new[] { new Citation(1, 10, 1, "a"), new Citation(2, 20, 2, "b") };
        var cited = ChatSessionState.StoppedCitations("B [2], A [1], again [2], unknown [7], cut [", map);
        Assert.Equal(new[] { 2, 1 }, cited.Select(c => c.Marker));
        Assert.Empty(ChatSessionState.StoppedCitations("none", map));
    }
}

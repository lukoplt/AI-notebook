using System.Threading;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;

namespace AINotebook.App.ViewModels;

/// <summary>
/// The running send / regenerate / edit of the chat surface and its Stop button (no WinUI types,
/// so App.Tests cover it). A generation number lets late tokens of a stopped turn be dropped.
/// </summary>
public sealed class ChatTurnControl
{
    private CancellationTokenSource? _cts;

    /// <summary>Advances with every turn; callbacks of older turns compare against it.</summary>
    public int Generation { get; private set; }

    /// <summary>The current turn's cancellation came from Stop, not from an error.</summary>
    public bool StopRequested { get; private set; }

    public bool IsRunning => _cts is not null;

    /// <summary>
    /// Starts a turn and returns its token and generation. A superseded source is not disposed here:
    /// its turn may still observe the token; <see cref="End"/> disposes the current one.
    /// </summary>
    public (CancellationToken Token, int Generation) Begin()
    {
        _cts = new CancellationTokenSource();
        StopRequested = false;
        return (_cts.Token, ++Generation);
    }

    public bool IsCurrent(int generation) => generation == Generation;

    /// <summary>Stop: cancels the running turn; false when nothing runs.</summary>
    public bool Stop()
    {
        if (_cts is not { } cts) return false;
        StopRequested = true;
        cts.Cancel();
        return true;
    }

    /// <summary>The turn of <paramref name="generation"/> ended (success, error or stop).</summary>
    public void End(int generation)
    {
        if (!IsCurrent(generation)) return;
        _cts?.Dispose();
        _cts = null;
        StopRequested = false;
    }
}

/// <summary>What a stopped turn leaves in the history (Core <see cref="ChatSessionState"/> rules, macOS parity).</summary>
public static class StoppedTurn
{
    /// <summary>
    /// Persists the streamed part of a stopped new turn under its question (Core saved the question
    /// when streaming began), with the citations it already used, through the same commit a complete
    /// answer uses. Returns null — writing nothing — for a replacement, when nothing streamed, or
    /// when the turn was stopped before it was sent.
    /// </summary>
    public static ChatMessage? Persist(NotebookStore store, long sessionId, PreparedPackHandle? handle,
        string? partial, bool isReplacement)
    {
        if (handle is null || ChatSessionState.StoppedAnswer(partial, isReplacement) is not { } answer) return null;
        var citations = ChatSessionState.StoppedCitations(answer, handle.Request.CitationMap);
        return store.CommitContextAssistant(sessionId, answer, citations, handle.Transport.StorageModel,
            replacesAssistantId: null, replacesUserId: null, replacementUserText: null);
    }

    /// <summary>
    /// A new turn stopped after it was sent but before any answer text arrived: removes the question row
    /// Core saved when streaming began (if it did — rows newer than <paramref name="newestIdBeforeSend"/>
    /// belong to this turn), so resending stores it once. Returns true when the question should go back
    /// into the composer; false — writing nothing — for a replacement, a turn that kept a partial answer,
    /// or a turn stopped before it was sent (its question is still in the input).
    /// </summary>
    public static bool WithdrawQuestion(NotebookStore store, long sessionId, PreparedPackHandle? handle,
        string? partial, bool isReplacement, string question, long? newestIdBeforeSend)
    {
        if (handle is null || !ChatSessionState.ReturnsQuestion(partial, isReplacement)) return false;
        if (ChatSessionState.OrphanedQuestionId(question, store.Messages(sessionId), newestIdBeforeSend) is { } id)
            store.DeleteUnansweredQuestion(sessionId, id);
        return true;
    }
}

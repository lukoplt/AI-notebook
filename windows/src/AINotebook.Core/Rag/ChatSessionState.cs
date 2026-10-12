using AINotebook.Core.Models;

namespace AINotebook.Core.Rag;

/// <summary>What "Try again" does after a failed send (port of Swift <c>ChatSessionState.Retry</c>).</summary>
public abstract record ChatRetry
{
    private ChatRetry() { }

    /// <summary>The question was stored: answer the last user message again (no duplicate row).</summary>
    public sealed record Regenerate : ChatRetry;

    /// <summary>The question never reached the history: send it again.</summary>
    public sealed record Resend(string Question) : ChatRetry;
}

/// <summary>Pure chat-surface rules shared with macOS (Sources/AINotebookCore/ChatSessionState.swift).</summary>
public static class ChatSessionState
{
    /// <summary>
    /// Background ingestion may change the scope's evidence between capture and send
    /// (<see cref="StalePreparedRequestException"/>, nothing written yet): the same turn is
    /// prepared again from the new snapshot, at most this many times (chat-during-scan-v1 §3).
    /// </summary>
    public const int StaleRepreparations = 3;

    public static bool ReprepareAfterStale(int attempt) => attempt < StaleRepreparations;

    /// <summary>
    /// After a failed send: when the history already ends with this user question, retry by
    /// regenerating it instead of storing the question a second time.
    /// </summary>
    public static ChatRetry RetryAfterFailedSend(string question, IReadOnlyList<ChatMessage> messages) =>
        messages.Count > 0 && messages[^1] is { Role: ChatRole.User } last && last.Content == question
            ? new ChatRetry.Regenerate()
            : new ChatRetry.Resend(question);

    /// <summary>The title a rename commits: trimmed, or null when blank or unchanged (the store keeps the current one).</summary>
    public static string? RenamedTitle(string? input, string current)
    {
        var trimmed = (input ?? "").Trim();
        return trimmed.Length == 0 || trimmed == current ? null : trimmed;
    }

    /// <summary>
    /// What a turn the user stopped keeps: the streamed text without trailing whitespace, or null when
    /// nothing (or only whitespace) arrived. Only a new turn keeps it; a stopped regenerate/edit leaves
    /// the previous exchange unchanged, because Core replaces it only after a complete stream.
    /// </summary>
    public static string? StoppedAnswer(string? partial, bool isReplacement)
    {
        if (isReplacement) return null;
        var text = (partial ?? "").TrimEnd();
        return text.Length == 0 ? null : text;
    }

    /// <summary>
    /// A new turn stopped before any answer text arrived keeps nothing: its question goes back into the
    /// composer and the row Core saved for it is removed (see <see cref="OrphanedQuestionId"/>), so
    /// sending again does not store the question twice. A stopped regenerate/edit keeps its previous exchange.
    /// </summary>
    public static bool ReturnsQuestion(string? partial, bool isReplacement) =>
        !isReplacement && StoppedAnswer(partial, isReplacement: false) is null;

    /// <summary>
    /// The user row a stopped, unanswered new turn left behind: the newest row, a user row with the sent
    /// question, newer than every row the turn started from (<paramref name="newestIdBeforeSend"/>, null
    /// for an empty history). Null when Core never saved the question (stopped before streaming began).
    /// </summary>
    public static long? OrphanedQuestionId(string question, IReadOnlyList<ChatMessage> messages, long? newestIdBeforeSend)
    {
        var last = messages.MaxBy(m => m.Id ?? 0);
        return last is { Id: { } id, Role: ChatRole.User } && last.Content == question && id > (newestIdBeforeSend ?? 0)
            ? id : null;
    }

    /// <summary>
    /// Citations of a stopped answer, resolved like a completed turn: each marker once in order of first
    /// use; markers the pack does not know are dropped.
    /// </summary>
    public static IReadOnlyList<Citation> StoppedCitations(string answer, IReadOnlyList<Citation> citationMap)
    {
        var byMarker = new Dictionary<int, Citation>();
        foreach (var citation in citationMap) byMarker.TryAdd(citation.Marker, citation);
        var seen = new HashSet<int>();
        return CitationParser.Markers(answer)
            .Where(m => seen.Add(m) && byMarker.ContainsKey(m))
            .Select(m => byMarker[m]).ToArray();
    }
}

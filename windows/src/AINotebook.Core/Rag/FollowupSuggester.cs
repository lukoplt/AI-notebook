using AINotebook.Core.Models;
using AINotebook.Core.Ollama;

namespace AINotebook.Core.Rag;

/// <summary>
/// Asks the chat model for up to 3 short follow-up questions a user might ask
/// next, given their question and the assistant's answer. Dependency-light:
/// reuses the same <see cref="IChatStreaming"/> abstraction the chat engine uses.
/// </summary>
public sealed class FollowupSuggester
{
    private readonly IChatStreaming _chat;
    public string ChatModel { get; }

    public FollowupSuggester(IChatStreaming chat, string chatModel)
    {
        _chat = chat;
        ChatModel = chatModel;
    }

    /// <summary>
    /// Up to 3 trimmed, non-empty follow-up question strings, parsed from the
    /// model output (one per line, leading list markers stripped).
    /// </summary>
    public async Task<IReadOnlyList<string>> GenerateAsync(
        string userText, string answer, CancellationToken ct = default)
    {
        var prompt =
            "Based on this question and answer, suggest 3 short, specific follow-up\n" +
            "questions the user might ask next. One question per line, no numbering.\n\n" +
            "Question:\n" + userText + "\n\n" +
            "Answer:\n" + answer;

        var turns = new List<ChatTurn> { new(ChatRole.User, prompt) }; // NO system turn
        var assembled = "";
        await foreach (var token in _chat.StreamAsync(ChatModel, turns, ct))
            assembled += token;

        return Parse(assembled);
    }

    /// <summary>
    /// Split into lines, strip leading list markers ("1.", "-", "•"), drop
    /// blanks, cap at 3.
    /// </summary>
    internal static IReadOnlyList<string> Parse(string raw)
    {
        var output = new List<string>();
        foreach (var line in raw.Split('\n'))
        {
            var stripped = StripMarker(line).Trim();
            if (stripped.Length == 0) continue;
            output.Add(stripped);
            if (output.Count == 3) break;
        }
        return output;
    }

    /// <summary>
    /// Remove a leading ordered/unordered list marker like "1.", "2)", "-",
    /// "*", or "•" from the start of a line.
    /// </summary>
    private static string StripMarker(string line)
    {
        var s = line.Trim();
        if (s.Length == 0) return s;
        var first = s[0];
        if (first == '-' || first == '*' || first == '•')
            return s[1..];
        // Numbered markers: leading digits followed by "." or ")".
        var idx = 0;
        while (idx < s.Length && char.IsDigit(s[idx])) idx++;
        if (idx > 0 && idx < s.Length && (s[idx] == '.' || s[idx] == ')'))
            return s[(idx + 1)..];
        return s;
    }
}

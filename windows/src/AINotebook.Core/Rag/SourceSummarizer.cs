using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

/// <summary>
/// Produces and persists a short plain-text summary for a single source.
/// Lazy-friendly: the caller decides when to summarize. Reuses the same
/// <see cref="IChatStreaming"/> abstraction as the chat and transformation engines.
/// </summary>
public sealed class SourceSummarizer
{
    private readonly NotebookStore _store;
    private readonly IChatStreaming _chat;
    public string ChatModel { get; }

    public SourceSummarizer(NotebookStore store, IChatStreaming chat, string chatModel)
    {
        _store = store;
        _chat = chat;
        ChatModel = chatModel;
    }

    /// <summary>
    /// Summarize the source's chunks into 2-3 plain-text sentences, persist the
    /// result, and return it. Returns an empty string without calling the model
    /// when the source has no chunks.
    /// </summary>
    public async Task<string> SummarizeAsync(long sourceId, CancellationToken ct = default)
    {
        var chunks = _store.Chunks(sourceId);
        if (chunks.Count == 0) return "";

        var sourceText = string.Join("\n\n", chunks.Select(c => c.Text));
        var prompt =
            "Summarize the following source in 2-3 plain-text sentences. Stay grounded\n" +
            "in the text and do not add anything not present in it. Output the summary\n" +
            "only — no preamble, no Markdown.\n\n" +
            "SOURCE TEXT:\n" + sourceText;

        var turns = new List<ChatTurn> { new(ChatRole.User, prompt) }; // NO system turn
        var assembled = "";
        await foreach (var token in _chat.StreamAsync(ChatModel, turns, ct))
            assembled += token;

        var summary = assembled.Trim();
        _store.SetSourceSummary(sourceId, summary);
        return summary;
    }
}

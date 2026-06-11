using System.Text;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;

namespace AINotebook.Core.Rag;

public static class SystemPrompt
{
    // Verbatim from SystemPrompt.swift (line-broken identically).
    private const string Header =
        "You are a helpful assistant answering questions about the user's notebook.\n" +
        "Use ONLY the provided CONTEXT to answer. If the answer isn't in the\n" +
        "context, say so plainly. When you use a fact from a context block,\n" +
        "cite it inline as [N] where N is the block number. Multiple citations\n" +
        "may appear in a single sentence: [1][3].";

    public static string Compose(
        IReadOnlyList<RetrievalHit> hits,
        string? currentNoteContent = null,
        string? notebookInstructions = null,
        IReadOnlyList<WebSearchResult>? webResults = null)
    {
        var sections = new List<string>();
        if (!string.IsNullOrWhiteSpace(notebookInstructions))
            sections.Add("NOTEBOOK INSTRUCTIONS:\n" + notebookInstructions.Trim());
        sections.Add(Header);

        if (hits.Count == 0)
        {
            sections.Add("CONTEXT:\n(none)");
        }
        else
        {
            var blocks = string.Join("\n",
                hits.Select((hit, i) => $"[{i + 1}] {hit.Snippet}"));
            sections.Add("CONTEXT:\n" + blocks);
        }

        if (webResults is { Count: > 0 })
        {
            var webBlocks = string.Join("\n",
                webResults.Select((r, i) => $"[W{i + 1}] {r.Title}: {r.Snippet}"));
            sections.Add("WEB SEARCH RESULTS (use these for up-to-date information, cite as [WN]):\n" + webBlocks);
        }

        if (currentNoteContent is { } note &&
            !string.IsNullOrEmpty(note.Trim()))
        {
            // The "—" below is an em-dash, U+2014.
            sections.Add(
                "CURRENTLY OPEN NOTE (additional context — user may be asking about this):\n" + note);
        }

        return string.Join("\n\n", sections);
    }
}

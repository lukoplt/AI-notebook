using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

/// <summary>
/// D1: Generates chunk-level context ("what does this passage discuss in the
/// larger document?") using the LLM, then persists it to source_chunks.context.
/// Enabled/disabled via a settings flag; when disabled, ingest skips this step.
/// </summary>
public sealed class ContextualEnricher
{
    private readonly NotebookStore _store;
    private readonly IChatStreaming _chat;
    private readonly Func<string> _modelGetter;

    public ContextualEnricher(NotebookStore store, IChatStreaming chat, Func<string> modelGetter)
    {
        _store = store;
        _chat = chat;
        _modelGetter = modelGetter;
    }

    /// <summary>
    /// Generates and stores context for every chunk of a source.
    /// Call after ReplaceChunks, before embedding.
    /// </summary>
    public async Task EnrichSourceAsync(long sourceId, CancellationToken ct = default)
    {
        var chunks = _store.Chunks(sourceId);
        if (chunks.Count == 0) return;

        var docPreview = string.Join("\n", chunks.Take(5).Select(c => c.Text));
        var model = _modelGetter();

        foreach (var chunk in chunks)
        {
            ct.ThrowIfCancellationRequested();
            var context = await GenerateContextAsync(model, docPreview, chunk.Text, ct);
            _store.SetChunkContext(sourceId, chunk.Id, context);
        }
    }

    private async Task<string> GenerateContextAsync(
        string model, string docPreview, string chunkText, CancellationToken ct)
    {
        var prompt =
            $"Here is a document excerpt:\n<document>\n{docPreview}\n</document>\n\n" +
            $"Here is a specific chunk from this document:\n<chunk>\n{chunkText}\n</chunk>\n\n" +
            "In 1-2 sentences, describe what this chunk is about in the context of the document. " +
            "Be concise and factual. Reply with only the description.";

        var turns = new List<ChatTurn>
        {
            new(ChatRole.User, prompt)
        };

        var result = new System.Text.StringBuilder();
        await foreach (var token in _chat.StreamAsync(model, turns, ct))
            result.Append(token);
        return result.ToString().Trim();
    }
}

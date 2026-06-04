using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

public sealed class TransformationEngine
{
    private readonly NotebookStore _store;
    private readonly IChatStreaming _chat;
    public string ChatModel { get; }

    public TransformationEngine(NotebookStore store, IChatStreaming chat, string chatModel)
    {
        _store = store;
        _chat = chat;
        ChatModel = chatModel;
    }

    public async Task<Note> RunAsync(
        long transformationId, long sourceId, Action<string>? onToken = null, CancellationToken ct = default)
    {
        var transformation = _store.Transformations().FirstOrDefault(t => t.Id == transformationId)
            ?? throw new TransformationException.TransformationNotFound(transformationId);
        var source = _store.Source(sourceId)
            ?? throw new TransformationException.SourceNotFound(sourceId);
        var chunks = _store.Chunks(sourceId);
        if (chunks.Count == 0) throw new TransformationException.NoChunks(sourceId);

        var sourceText = string.Join("\n\n", chunks.Select(c => c.Text));
        var rendered = transformation.PromptTemplate.Replace("{{source_text}}", sourceText);

        var assembled = await StreamAssembleAsync(rendered, onToken, ct);

        // em-dash U+2014 in the title separator.
        var noteTitle = $"{transformation.Name} — {source.Title}";
        var created = _store.CreateNote(source.NotebookId, noteTitle, assembled,
            NoteOrigin.Transformation, transformation.Id);
        _store.RecordTransformationRun(transformation.Id!.Value, source.Id!.Value, created.Id);
        return created;
    }

    public async Task<Note> RunNotebookScopeAsync(
        long transformationId, long notebookId, Action<string>? onToken = null, CancellationToken ct = default)
    {
        var transformation = _store.Transformations().FirstOrDefault(t => t.Id == transformationId)
            ?? throw new TransformationException.TransformationNotFound(transformationId);
        var sources = _store.Sources(notebookId);
        var allChunks = new List<SourceChunk>();
        foreach (var s in sources) allChunks.AddRange(_store.Chunks(s.Id!.Value));
        if (allChunks.Count == 0) throw new TransformationException.NoChunks(notebookId);

        var sourceText = string.Join("\n\n", allChunks.Select(c => c.Text));
        var rendered = transformation.PromptTemplate.Replace("{{source_text}}", sourceText);

        var assembled = await StreamAssembleAsync(rendered, onToken, ct);

        var noteTitle = $"{transformation.Name} — {sources.Count} sources";
        var created = _store.CreateNote(notebookId, noteTitle, assembled,
            NoteOrigin.Transformation, transformation.Id);
        _store.RecordTransformationRun(transformation.Id!.Value, null, created.Id);
        return created;
    }

    public async Task<IReadOnlyList<Note>> RunOnAllSourcesAsync(
        long transformationId, long notebookId, Action<int, int>? onProgress = null, CancellationToken ct = default)
    {
        var sources = _store.Sources(notebookId);
        var total = sources.Count;
        var results = new List<Note>();
        for (var idx = 0; idx < sources.Count; idx++)
        {
            var note = await RunAsync(transformationId, sources[idx].Id!.Value, null, ct);
            results.Add(note);
            onProgress?.Invoke(idx + 1, total);
        }
        return results;
    }

    private async Task<string> StreamAssembleAsync(string rendered, Action<string>? onToken, CancellationToken ct)
    {
        var turns = new List<ChatTurn> { new(ChatRole.User, rendered) }; // NO system turn
        var assembled = "";
        await foreach (var token in _chat.StreamAsync(ChatModel, turns, ct))
        {
            assembled += token;
            onToken?.Invoke(token);
        }
        return assembled;
    }
}

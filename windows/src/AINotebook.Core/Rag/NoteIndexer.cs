using AINotebook.Core.Models;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

public sealed class NoteIndexer
{
    private readonly NotebookStore _store;
    private readonly Func<Task>? _onChunksWritten;

    public NoteIndexer(NotebookStore store, Func<Task>? onChunksWritten = null)
    {
        _store = store;
        _onChunksWritten = onChunksWritten;
    }

    public async Task IndexAsync(long noteId, CancellationToken ct = default)
    {
        var note = _store.Note(noteId)
            ?? throw new StoreException.SourceNotFound(noteId);

        long sourceId;
        if (note.AutoSourceId is { } existing && _store.Source(existing) is { } shadow)
        {
            if (shadow.Title != note.Title)
                _store.UpdateSourceTitle(existing, note.Title);
            sourceId = existing;
        }
        else
        {
            var created = _store.CreateSource(note.NotebookId, SourceType.Note, note.Title, null, null);
            sourceId = created.Id!.Value;
            _store.LinkNoteToShadowSource(noteId, sourceId);
        }

        var drafts = string.IsNullOrEmpty(note.BodyMd.Trim())
            ? new List<ChunkDraft>()
            : Chunker.Chunk(note.BodyMd);

        _store.ReplaceChunks(sourceId, drafts);
        _store.UpdateSourceStatus(sourceId, SourceStatus.Ready, null);

        if (_onChunksWritten is not null) await _onChunksWritten();
    }
}

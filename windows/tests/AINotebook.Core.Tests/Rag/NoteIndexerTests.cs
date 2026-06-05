using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class NoteIndexerTests
{
    // NoteIndexerTests.testIndexCreatesShadowSourceAndChunks
    [Fact]
    public async Task IndexCreatesShadowSourceAndChunks()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var note = store.CreateNote(nb.Id!.Value, "Recipe", "Mix flour and water.", NoteOrigin.Manual, null);

        var indexer = new NoteIndexer(store);
        await indexer.IndexAsync(note.Id!.Value);

        var refreshed = store.Note(note.Id!.Value)!;
        Assert.NotNull(refreshed.AutoSourceId);
        var shadow = store.Source(refreshed.AutoSourceId!.Value)!;
        Assert.Equal(SourceType.Note, shadow.Type);
        Assert.Equal("Recipe", shadow.Title);
        Assert.Equal(SourceStatus.Ready, shadow.Status);

        var chunks = store.Chunks(shadow.Id!.Value);
        Assert.NotEmpty(chunks);
        Assert.Contains(chunks, c => c.Text.Contains("flour"));
    }

    // NoteIndexerTests.testReindexReplacesChunks
    [Fact]
    public async Task ReindexReplacesChunks()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var note = store.CreateNote(nb.Id!.Value, "T", "original body", NoteOrigin.Manual, null);
        var indexer = new NoteIndexer(store);
        await indexer.IndexAsync(note.Id!.Value);

        store.UpdateNote(note.Id!.Value, "T", "replaced body");
        await indexer.IndexAsync(note.Id!.Value);

        var shadow = store.Source(store.Note(note.Id!.Value)!.AutoSourceId!.Value)!;
        var chunks = store.Chunks(shadow.Id!.Value);
        Assert.Contains(chunks, c => c.Text.Contains("replaced"));
        Assert.DoesNotContain(chunks, c => c.Text.Contains("original"));
    }

    // NoteIndexerTests.testEmptyBodyClearsChunksButKeepsShadow
    [Fact]
    public async Task EmptyBodyClearsChunksButKeepsShadow()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var note = store.CreateNote(nb.Id!.Value, "T", "has content", NoteOrigin.Manual, null);
        var indexer = new NoteIndexer(store);
        await indexer.IndexAsync(note.Id!.Value);

        store.UpdateNote(note.Id!.Value, "T", "   ");
        await indexer.IndexAsync(note.Id!.Value);

        var shadowId = store.Note(note.Id!.Value)!.AutoSourceId!.Value;
        Assert.NotNull(store.Source(shadowId));
        Assert.Empty(store.Chunks(shadowId));
    }

    // NoteIndexerTests.testKickHookFiresAfterIndex
    [Fact]
    public async Task KickHookFiresAfterIndex()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var note = store.CreateNote(nb.Id!.Value, "T", "body", NoteOrigin.Manual, null);

        var fired = 0;
        var indexer = new NoteIndexer(store, () => { fired++; return Task.CompletedTask; });
        await indexer.IndexAsync(note.Id!.Value);

        Assert.Equal(1, fired);
    }
}

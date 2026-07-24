using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

/// <summary>
/// The store keeps ONE SqliteConnection for its lifetime, and
/// Microsoft.Data.Sqlite's connection is not thread-safe — yet it is used
/// concurrently in production (EmbeddingWorker drains on a thread-pool thread,
/// FolderWatchService ingests on another, the ViewModels wrap most calls in
/// Task.Run, Retriever queries from async continuations). Before the store
/// serialized access these overlapped and faulted at random.
///
/// macOS never had the bug: GRDB's DatabaseQueue serializes for it.
/// </summary>
public class NotebookStoreConcurrencyTests
{
    [Fact]
    public async Task ParallelReadsAndWritesDoNotFault()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var nbId = nb.Id!.Value;
        var src = store.CreateSource(nbId, SourceType.Text, "S", null, null);
        store.ReplaceChunks(src.Id!.Value, new[] { new ChunkDraft("body", 1, null) });
        var chunkId = store.Chunks(src.Id!.Value)[0].Id!.Value;

        // Mixed readers and writers, all off the calling thread — the shape
        // that used to throw "InvalidOperationException: connection is busy".
        var work = new List<Task>();
        for (var i = 0; i < 16; i++)
        {
            var n = i;
            work.Add(Task.Run(() => store.Notebooks()));
            work.Add(Task.Run(() => store.CreateNote(nbId, $"note {n}", "body")));
            work.Add(Task.Run(() => store.Notes(nbId)));
            work.Add(Task.Run(() => store.StoreEmbedding(chunkId, $"m{n}", new EmbeddingVector(new[] { 1f, 0f }))));
            work.Add(Task.Run(() => store.Embeddings(nbId, $"m{n}")));
            work.Add(Task.Run(() => store.UnembeddedCount("nope")));
        }

        await Task.WhenAll(work);

        // Every write landed exactly once.
        Assert.Equal(16, store.Notes(nbId).Count);
    }

    [Fact]
    public async Task CompoundMethodStaysAtomicUnderContention()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var nbId = nb.Id!.Value;
        var note = store.CreateNote(nbId, "t", "b");
        var noteId = note.Id!.Value;

        // SnapshotNoteVersion reads the note, inserts a version, then trims to
        // the cap — a read-modify-write that must not interleave with itself.
        var work = Enumerable.Range(0, 32)
            .Select(_ => Task.Run(() => store.SnapshotNoteVersion(noteId, NoteVersionReason.Autosave)))
            .ToArray();
        await Task.WhenAll(work);

        var versions = store.NoteVersions(noteId);
        Assert.True(versions.Count <= NotebookStore.NoteVersionCap,
            $"cap breached: {versions.Count} > {NotebookStore.NoteVersionCap}");
    }
}

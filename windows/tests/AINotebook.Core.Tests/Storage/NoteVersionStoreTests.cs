using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class NoteVersionStoreTests
{
    private static (NotebookStore store, long noteId) Fresh()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N").Id!.Value;
        var note = store.CreateNote(nb, "t", "v1");
        return (store, note.Id!.Value);
    }

    [Fact]
    public void UpdateNoteSnapshotsPreviousBodyAsAutosave()
    {
        var (store, noteId) = Fresh();
        using (store)
        {
            store.UpdateNote(noteId, "t", "v2");
            var versions = store.NoteVersions(noteId);
            Assert.Single(versions);
            Assert.Equal(NoteVersionReason.Autosave, versions[0].Reason);
            Assert.Equal("v1", versions[0].BodyMd);
        }
    }

    [Fact]
    public void ManualSnapshotUsesManualReason()
    {
        var (store, noteId) = Fresh();
        using (store)
        {
            store.SnapshotNoteVersion(noteId, NoteVersionReason.Manual);
            Assert.Equal(NoteVersionReason.Manual, store.NoteVersions(noteId).Single().Reason);
        }
    }

    [Fact]
    public void RestoreSnapshotsCurrentAsRestoreThenOverwritesBody()
    {
        var (store, noteId) = Fresh();
        using (store)
        {
            // first update creates an autosave version holding "v1"
            store.UpdateNote(noteId, "t", "v2");
            var v1Version = store.NoteVersions(noteId).Single(v => v.BodyMd == "v1");
            store.RestoreNoteVersion(v1Version.Id!.Value);
            Assert.Equal("v1", store.Note(noteId)!.BodyMd);
            var versions = store.NoteVersions(noteId);
            Assert.True(versions.Count >= 2);
            Assert.Contains(versions, v => v.Reason == NoteVersionReason.Restore && v.BodyMd == "v2");
        }
    }

    [Fact]
    public void VersionsCappedAtFiftyOldestPruned()
    {
        var (store, noteId) = Fresh();
        using (store)
        {
            for (int i = 0; i < 60; i++)
                store.UpdateNote(noteId, "t", $"body {i}");
            Assert.True(store.NoteVersions(noteId).Count <= 50);
        }
    }
}

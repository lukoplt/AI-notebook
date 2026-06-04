using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class NotebookStoreNotesTests
{
    private static (NotebookStore store, long nb) Fresh()
    {
        var store = new NotebookStore(StorePath.InMemory);
        return (store, store.CreateNotebook("N").Id!.Value);
    }

    [Fact]
    public void CreateNoteDefaultsToManualAndGetsLowercased36CharUuid()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var note = store.CreateNote(nb, "  Title  ", "body");
            Assert.Equal(NoteOrigin.Manual, note.Origin);
            Assert.Equal("Title", note.Title);
            Assert.Equal(36, note.NoteUuid.Length);
            Assert.Contains("-", note.NoteUuid);
            Assert.Equal(note.NoteUuid.ToLowerInvariant(), note.NoteUuid);
            Assert.Null(note.AutoSourceId);
        }
    }

    [Fact]
    public void NotesOrderedByUpdatedAtDesc()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            store.CreateNote(nb, "a", "x");
            var b = store.CreateNote(nb, "b", "x");
            Assert.Equal(b.Id, store.Notes(nb)[0].Id);
        }
    }

    [Fact]
    public void UpdateNoteTrimsTitleSetsBodyAndBumpsUpdatedAt()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var note = store.CreateNote(nb, "t", "v1");
            var before = note.UpdatedAt;
            store.UpdateNote(note.Id!.Value, "  t2 ", "v2");
            var reloaded = store.Note(note.Id!.Value)!;
            Assert.Equal("t2", reloaded.Title);
            Assert.Equal("v2", reloaded.BodyMd);
            Assert.True(reloaded.UpdatedAt >= before);
        }
    }

    [Fact]
    public void TransformationOriginWithOriginRefPersists()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var note = store.CreateNote(nb, "t", "b", NoteOrigin.Transformation, originRef: 999);
            var reloaded = store.Note(note.Id!.Value)!;
            Assert.Equal(NoteOrigin.Transformation, reloaded.Origin);
            Assert.Equal(999, reloaded.OriginRef);
        }
    }

    [Fact]
    public void DeleteNoteReturnsUuidAndRemoves()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var note = store.CreateNote(nb, "t", "b");
            var uuid = store.DeleteNote(note.Id!.Value);
            Assert.Equal(note.NoteUuid, uuid);
            Assert.Empty(store.Notes(nb));
        }
    }
}

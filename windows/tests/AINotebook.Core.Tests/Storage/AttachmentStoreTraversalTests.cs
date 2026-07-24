using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

/// <summary>
/// The attachment filename has always been reduced to one path component, but
/// the note-folder segment beside it was joined onto the root raw. On the
/// serving side that value is `uri.Host` from the editor's attachment:// URL,
/// and .NET parses `attachment://../db.sqlite` into Host == "..", so a crafted
/// image URL in a note resolved one level above the attachments root — the
/// directory holding db.sqlite and settings.json.
/// </summary>
public class AttachmentStoreTraversalTests
{
    private static (AttachmentStore attachments, string root, NotebookStore store, long noteId) Setup()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        // attachments.note_id is a real FK, so the row needs a real note.
        var note = store.CreateNote(nb.Id!.Value, "t", "b");
        var root = Path.Combine(Path.GetTempPath(), "aino-attach-" + Guid.NewGuid().ToString("N"));
        return (new AttachmentStore(store, root), root, store, note.Id!.Value);
    }

    [Theory]
    [InlineData("..")]
    [InlineData(".")]
    [InlineData("")]
    [InlineData("../..")]      // GetFileName reduces this to ".." too
    [InlineData("foo/..")]
    public void ReadRejectsTraversalNoteFolder(string noteUuid)
    {
        var (attachments, root, store, noteId) = Setup();
        using (store)
        {
            // A file one level above the attachments root — what the old code
            // would happily hand back to the WebView.
            var outside = Path.Combine(Directory.GetParent(root)!.FullName, "escaped.bin");

            Assert.Throws<ArgumentException>(() => attachments.Read(noteUuid, "escaped.bin"));
            Assert.Throws<ArgumentException>(() => attachments.DeleteFolder(noteUuid));
            Assert.Throws<ArgumentException>(
                () => attachments.Save(noteId, noteUuid, "escaped.bin", "image/png", new byte[] { 1 }));

            Assert.False(File.Exists(outside), "traversal write escaped the attachments root");
        }
    }

    [Fact]
    public void RoundTripsInsideTheNoteFolder()
    {
        var (attachments, root, store, noteId) = Setup();
        using (store)
        {
            var uuid = Guid.NewGuid().ToString().ToLowerInvariant();
            var att = attachments.Save(noteId, uuid, "shot.png", "image/png", new byte[] { 1, 2, 3 });

            Assert.Equal(new byte[] { 1, 2, 3 }, attachments.Read(uuid, att.Filename));
            Assert.True(File.Exists(Path.Combine(root, uuid, att.Filename)));

            Directory.Delete(root, recursive: true);
        }
    }
}

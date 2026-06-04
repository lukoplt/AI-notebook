using System.Text;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class AttachmentStoreTests : IDisposable
{
    private readonly NotebookStore _store;
    private readonly string _root;
    private readonly long _noteId;
    private readonly string _noteUuid;

    public AttachmentStoreTests()
    {
        _store = new NotebookStore(StorePath.InMemory);
        var nb = _store.CreateNotebook("N").Id!.Value;
        var note = _store.CreateNote(nb, "t", "b");
        _noteId = note.Id!.Value;
        _noteUuid = note.NoteUuid;
        _root = Path.Combine(Path.GetTempPath(), "ainb-att-" + Guid.NewGuid().ToString("N"));
    }

    public void Dispose()
    {
        _store.Dispose();
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    [Fact]
    public void SaveWritesFileAndDbRowAndListReturnsOne()
    {
        var att = new AttachmentStore(_store, _root);
        var bytes = Encoding.UTF8.GetBytes("hello");
        var saved = att.Save(_noteId, _noteUuid, "x.png", "image/png", bytes);
        Assert.NotNull(saved.Id);
        Assert.Equal("x.png", saved.Filename);
        Assert.Equal(bytes.Length, saved.ByteSize);
        Assert.True(File.Exists(Path.Combine(_root, _noteUuid, "x.png")));
        Assert.Single(att.List(_noteId));
    }

    [Fact]
    public void CollisionRenamesWithParenTwo()
    {
        var att = new AttachmentStore(_store, _root);
        att.Save(_noteId, _noteUuid, "x.png", "image/png", new byte[] { 1 });
        var second = att.Save(_noteId, _noteUuid, "x.png", "image/png", new byte[] { 2 });
        Assert.Contains("(2)", second.Filename);
        Assert.Equal("x (2).png", second.Filename);
        Assert.True(File.Exists(Path.Combine(_root, _noteUuid, "x (2).png")));
    }

    [Fact]
    public void ReadReturnsExactBytes()
    {
        var att = new AttachmentStore(_store, _root);
        var bytes = new byte[] { 9, 8, 7, 6 };
        att.Save(_noteId, _noteUuid, "blob.bin", "application/octet-stream", bytes);
        Assert.Equal(bytes, att.Read(_noteUuid, "blob.bin"));
    }

    [Fact]
    public void DeleteFolderRemovesTheNoteUuidFolder()
    {
        var att = new AttachmentStore(_store, _root);
        att.Save(_noteId, _noteUuid, "x.png", "image/png", new byte[] { 1 });
        att.DeleteFolder(_noteUuid);
        Assert.False(Directory.Exists(Path.Combine(_root, _noteUuid)));
    }
}

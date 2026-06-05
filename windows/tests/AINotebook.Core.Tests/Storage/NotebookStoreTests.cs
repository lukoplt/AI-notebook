using AINotebook.Core;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class NotebookStoreTests
{
    [Fact]
    public void CreateTrimsNameAndAppends()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("  Research  ");
        Assert.Equal("Research", nb.Name);
        Assert.NotNull(nb.Id);
    }

    [Fact]
    public void CreateRejectsEmptyName()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var ex = Assert.Throws<StoreException.InvalidNotebookName>(
            () => store.CreateNotebook("   "));
        Assert.Equal("   ", ex.Name);
    }

    [Fact]
    public void ListIsOrderedByUpdatedAtDescAndRenameResortsToTop()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var a = store.CreateNotebook("A");
        var b = store.CreateNotebook("B");
        // b is newest -> first
        Assert.Equal(new[] { "B", "A" }, store.Notebooks().Select(n => n.Name).ToArray());
        store.RenameNotebook(a.Id!.Value, "A2");
        Assert.Equal(new[] { "A2", "B" }, store.Notebooks().Select(n => n.Name).ToArray());
    }

    [Fact]
    public void RenameBumpsUpdatedAtAndRejectsEmptyAndUnknown()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var a = store.CreateNotebook("A");
        var before = a.UpdatedAt;
        var renamed = store.RenameNotebook(a.Id!.Value, "  A2 ");
        Assert.Equal("A2", renamed.Name);
        Assert.True(renamed.UpdatedAt >= before);
        Assert.Throws<StoreException.InvalidNotebookName>(
            () => store.RenameNotebook(a.Id!.Value, " "));
        Assert.Throws<StoreException.NotebookNotFound>(
            () => store.RenameNotebook(99999, "x"));
    }

    [Fact]
    public void DeleteRemovesAndUnknownThrows()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var a = store.CreateNotebook("A");
        store.DeleteNotebook(a.Id!.Value);
        Assert.Empty(store.Notebooks());
        Assert.Throws<StoreException.NotebookNotFound>(() => store.DeleteNotebook(a.Id!.Value));
    }

    [Fact]
    public void PersistsAcrossReopenedStoreInstances()
    {
        var dir = Path.Combine(Path.GetTempPath(), "ainb-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var path = new StorePath(Path.Combine(dir, "db.sqlite"));
        try
        {
            using (var store = new NotebookStore(path))
                store.CreateNotebook("Persisted");
            using (var reopened = new NotebookStore(path))
                Assert.Equal("Persisted", reopened.Notebooks().Single().Name);
        }
        finally { Directory.Delete(dir, recursive: true); }
    }
}

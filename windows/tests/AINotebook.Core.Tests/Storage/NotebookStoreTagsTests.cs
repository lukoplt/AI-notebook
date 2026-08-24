using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

/// <summary>
/// FR-B8 tags (schema v12). Covers the acceptance criteria the Epic B
/// implementation shipped without tests: tag reuse, note/source assignment,
/// replacement semantics, and cascade on delete.
/// </summary>
public class NotebookStoreTagsTests
{
    private static (NotebookStore store, long notebookId) NewStore()
    {
        var store = new NotebookStore(StorePath.InMemory);
        return (store, store.CreateNotebook("NB").Id!.Value);
    }

    [Fact]
    public void CreateTrimsAndReusesAnExistingTagInsteadOfDuplicating()
    {
        using var store = new NotebookStore(StorePath.InMemory);

        var first = store.CreateTag("  research  ");
        var again = store.CreateTag("research");

        Assert.Equal("research", first.Name);
        Assert.Equal(first.Id, again.Id);
        Assert.Single(store.Tags());
    }

    [Fact]
    public void TagsAreSharedAcrossNotebooksNotScopedToOne()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        store.CreateNotebook("A");
        store.CreateNotebook("B");

        store.CreateTag("shared");

        // Tags() takes no notebook id — the tag vocabulary is global, which is
        // what lets a filter span notebooks.
        Assert.Single(store.Tags());
    }

    [Fact]
    public void SetNoteTagsReplacesTheWholeAssignmentRatherThanAppending()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        var note = store.CreateNote(nb, "Note", "body");
        var a = store.CreateTag("alpha");
        var b = store.CreateTag("beta");
        var c = store.CreateTag("gamma");

        store.SetNoteTags(note.Id!.Value, new[] { a.Id, b.Id });
        Assert.Equal(new[] { "alpha", "beta" },
            store.TagsForNote(note.Id!.Value).Select(t => t.Name).OrderBy(n => n).ToArray());

        // Replacement, not union: gamma in, alpha and beta out.
        store.SetNoteTags(note.Id!.Value, new[] { c.Id });
        Assert.Equal(new[] { "gamma" },
            store.TagsForNote(note.Id!.Value).Select(t => t.Name).ToArray());
    }

    [Fact]
    public void SetNoteTagsWithAnEmptyListClearsEveryTag()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        var note = store.CreateNote(nb, "Note", "body");
        var tag = store.CreateTag("alpha");
        store.SetNoteTags(note.Id!.Value, new[] { tag.Id });

        store.SetNoteTags(note.Id!.Value, Array.Empty<long>());

        Assert.Empty(store.TagsForNote(note.Id!.Value));
        // The tag itself survives — only the assignment was removed.
        Assert.Single(store.Tags());
    }

    [Fact]
    public void NotesAndSourcesKeepSeparateAssignmentsOfTheSameTag()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        var note = store.CreateNote(nb, "Note", "body");
        var source = store.CreateSource(nb, SourceType.Text, "Doc", null, null);
        var tag = store.CreateTag("shared");

        store.SetNoteTags(note.Id!.Value, new[] { tag.Id });

        Assert.Equal(new[] { tag.Id }, store.NoteTagIds(note.Id!.Value).ToArray());
        Assert.Empty(store.SourceTagIds(source.Id!.Value));

        store.SetSourceTags(source.Id!.Value, new[] { tag.Id });
        Assert.Equal(new[] { tag.Id }, store.SourceTagIds(source.Id!.Value).ToArray());
    }

    [Fact]
    public void DeletingATagRemovesItFromEverythingItWasAssignedTo()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        var note = store.CreateNote(nb, "Note", "body");
        var source = store.CreateSource(nb, SourceType.Text, "Doc", null, null);
        var doomed = store.CreateTag("doomed");
        var kept = store.CreateTag("kept");
        store.SetNoteTags(note.Id!.Value, new[] { doomed.Id, kept.Id });
        store.SetSourceTags(source.Id!.Value, new[] { doomed.Id });

        store.DeleteTag(doomed.Id);

        Assert.Equal(new[] { "kept" }, store.TagsForNote(note.Id!.Value).Select(t => t.Name).ToArray());
        Assert.Empty(store.TagsForSource(source.Id!.Value));
        Assert.Equal(new[] { "kept" }, store.Tags().Select(t => t.Name).ToArray());
    }

    [Fact]
    public void DeletingANoteDoesNotStrandItsTagAssignments()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        var note = store.CreateNote(nb, "Note", "body");
        var tag = store.CreateTag("alpha");
        store.SetNoteTags(note.Id!.Value, new[] { tag.Id });

        store.DeleteNote(note.Id!.Value);

        // The row is gone, so re-creating a note must not inherit stale links.
        var replacement = store.CreateNote(nb, "Note", "body");
        Assert.Empty(store.TagsForNote(replacement.Id!.Value));
    }
}

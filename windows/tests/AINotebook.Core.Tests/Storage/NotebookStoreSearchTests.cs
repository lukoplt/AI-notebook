using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

/// <summary>
/// FR-B9 note search and FR-B4 global search (schema v12 `notes_fts`). The
/// Ctrl+K palette is only as good as these queries, and neither had tests.
/// </summary>
public class NotebookStoreSearchTests
{
    private static (NotebookStore store, long notebookId) NewStore()
    {
        var store = new NotebookStore(StorePath.InMemory);
        return (store, store.CreateNotebook("NB").Id!.Value);
    }

    [Fact]
    public void SearchNotesMatchesBodyTextAndReturnsAHighlightedSnippet()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        store.CreateNote(nb, "Roasting", "The development time ratio governs perceived sweetness.");
        store.CreateNote(nb, "Unrelated", "Nothing to see here.");

        var hits = store.SearchNotes(nb, "sweetness");

        var hit = Assert.Single(hits);
        Assert.Equal("Roasting", hit.Title);
        Assert.Equal(nb, hit.NotebookId);
        Assert.Contains("<b>", hit.Snippet);
    }

    [Fact]
    public void SearchNotesMatchesTitlesToo()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        store.CreateNote(nb, "Varroa treatment", "body without the word");

        Assert.Single(store.SearchNotes(nb, "varroa"));
    }

    [Fact]
    public void SearchNotesStaysInsideItsNotebook()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var a = store.CreateNotebook("A").Id!.Value;
        var b = store.CreateNotebook("B").Id!.Value;
        store.CreateNote(a, "Mine", "shared keyword");
        store.CreateNote(b, "Theirs", "shared keyword");

        var hits = store.SearchNotes(a, "keyword");

        Assert.Equal(new[] { "Mine" }, hits.Select(h => h.Title).ToArray());
    }

    [Fact]
    public void SearchNotesReturnsNothingForBlankOrWhitespaceQueries()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        store.CreateNote(nb, "Note", "content");

        Assert.Empty(store.SearchNotes(nb, ""));
        Assert.Empty(store.SearchNotes(nb, "   "));
    }

    [Fact]
    public void SearchNotesSeesEditsAndForgetsDeletedNotes()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        var note = store.CreateNote(nb, "Note", "original wording");

        store.UpdateNote(note.Id!.Value, "Note", "replaced wording");
        Assert.Empty(store.SearchNotes(nb, "original"));
        Assert.Single(store.SearchNotes(nb, "replaced"));

        store.DeleteNote(note.Id!.Value);
        Assert.Empty(store.SearchNotes(nb, "replaced"));
    }

    [Fact]
    public void GlobalSearchCrossesNotebooksAndReportsWhereEachHitLives()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var a = store.CreateNotebook("A").Id!.Value;
        var b = store.CreateNotebook("B").Id!.Value;
        store.CreateNote(a, "In A", "distinctiveterm here");
        store.CreateNote(b, "In B", "distinctiveterm there");

        var result = store.GlobalSearch("distinctiveterm");

        Assert.Equal(2, result.Notes.Count);
        // The jump target is (notebook, item) — a hit without its notebook id
        // could not be navigated to.
        Assert.Equal(new[] { a, b }, result.Notes.Select(n => n.NotebookId).OrderBy(x => x).ToArray());
    }

    [Fact]
    public void GlobalSearchFindsSourceTitlesAlongsideNotes()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        store.CreateNote(nb, "Note about beekeeping", "body");
        store.CreateSource(nb, SourceType.Text, "Beekeeping manual", null, null);

        var result = store.GlobalSearch("beekeeping");

        Assert.Single(result.Notes);
        var source = Assert.Single(result.Sources);
        Assert.Equal("Beekeeping manual", source.Title);
        Assert.Equal(nb, source.NotebookId);
    }

    [Fact]
    public void GlobalSearchReturnsEmptyResultsForABlankQueryRatherThanEverything()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        store.CreateNote(nb, "Note", "content");
        store.CreateSource(nb, SourceType.Text, "Doc", null, null);

        var result = store.GlobalSearch("  ");

        Assert.Empty(result.Notes);
        Assert.Empty(result.Sources);
    }

    [Theory]
    [InlineData("\"unbalanced")]
    [InlineData("NEAR(")]
    [InlineData("a AND")]
    [InlineData("*")]
    public void SearchSurvivesQueriesThatWouldOtherwiseBreakTheFtsParser(string query)
    {
        var (store, nb) = NewStore();
        using var _ = store;
        store.CreateNote(nb, "Note", "content");

        // A user typing into the Ctrl+K box produces these constantly; the
        // escaping has to make them inert instead of throwing.
        var notes = store.SearchNotes(nb, query);
        var global = store.GlobalSearch(query);

        Assert.NotNull(notes);
        Assert.NotNull(global);
    }
}

using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.App.Tests;

/// <summary>WP8 Task 11: citations render from their saved snapshot, never from the live original.</summary>
public sealed class CitationSnapshotTests
{
    [Fact]
    public void MissingLiveSourceStillShowsSavedTextTitleAndPage()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var citation = new Citation(1, 101, 999, "short")
        {
            DisplayName = "Original report", RelPath = "reports/a.pdf", RevisionId = 7,
            Text = "Full immutable snapshot.", Spans = [new CitationSpan(0, 24, 12, 12)], ChunkIds = [101]
        };
        var vm = CitationViewModel.Resolve(store, citation);
        Assert.Equal("Original report", vm.SourceTitle);
        Assert.Equal("Full immutable snapshot.", vm.Snippet);
        Assert.Equal(12, vm.PageHint);
        Assert.Null(vm.PdfFilePath);
    }

    [Fact]
    public void LegacyCitationStillDisplaysItsSnippet()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        Assert.Equal("legacy snapshot", CitationViewModel.Resolve(store, new Citation(1, 101, 999, "legacy snapshot")).Snippet);
    }

    [Fact]
    public void SavedPathPrecedesTheLiveTitleWhenNoDisplayNameWasSaved()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var notebook = store.CreateNotebook("NB");
        var source = store.CreateSource(notebook.Id!.Value, SourceType.Text, "Live title", null, null);
        var vm = CitationViewModel.Resolve(store, new Citation(1, 1, source.Id!.Value, "x") { RelPath = "docs/a.txt", Text = "saved" });
        Assert.Equal("docs/a.txt", vm.SourceTitle);
        Assert.Equal("saved", vm.Snippet);
        Assert.Equal("Live title", CitationViewModel.Resolve(store, new Citation(1, 1, source.Id.Value, "x")).SourceTitle);
    }
}

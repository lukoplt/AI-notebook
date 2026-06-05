using AINotebook.Core.Rag;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class CitationParserTests
{
    [Fact] // testFindsSingleCitation
    public void FindsSingleCitation() =>
        Assert.Equal(new[] { 1 }, CitationParser.Markers("The sky is blue [1]."));

    [Fact] // testFindsMultipleCitationsInOrder (order + dupes preserved)
    public void FindsMultipleCitationsInOrderWithDupes() =>
        Assert.Equal(new[] { 2, 5, 2 }, CitationParser.Markers("First [2]. Second [5]. Third [2]."));

    [Fact] // testIgnoresMalformedMarkers
    public void IgnoresMalformedMarkers() =>
        Assert.Equal(new[] { 1 }, CitationParser.Markers("[abc] [1.2] [-3] [1]"));

    [Fact] // testHandlesAdjacentMarkers
    public void HandlesAdjacentMarkers() =>
        Assert.Equal(new[] { 1, 3 }, CitationParser.Markers("Both true [1][3]."));

    [Fact] // testEmptyOrNoMatchReturnsEmpty
    public void EmptyOrNoMatchReturnsEmpty()
    {
        Assert.Empty(CitationParser.Markers(""));
        Assert.Empty(CitationParser.Markers("no markers here"));
    }
}

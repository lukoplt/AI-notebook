using System.Text.Json;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public sealed class CitationOriginalPolicyTests
{
    [Fact]
    public void AllSharedOriginalDecisions()
    {
        var rows = ContextPackFixtures.Cases("original");
        Assert.Equal(10, rows.Length);
        foreach (var row in rows)
        {
            var input = row.GetProperty("input").Deserialize<CitationOriginalInput>(ContextPackFixtures.Options)!;
            var actual = JsonSerializer.SerializeToElement(CitationOriginalPolicy.Evaluate(input));
            Assert.True(actual.ValueKind == JsonValueKind.String, row.GetProperty("name").GetString());
            Assert.True(actual.GetString() == row.GetProperty("expected").GetString(), row.GetProperty("name").GetString());
        }
    }

    [Theory]
    [InlineData("")]
    [InlineData("/docs/a.txt")]
    [InlineData("C:/docs/a.txt")]
    [InlineData("\\\\server\\share\\a.txt")]
    [InlineData("docs\\a.txt")]
    [InlineData("docs//a.txt")]
    [InlineData("docs/./a.txt")]
    [InlineData("docs/../a.txt")]
    [InlineData("docs/a.txt/")]
    [InlineData("docs/a\0.txt")]
    [InlineData("docs/a\n.txt")]
    public void UnsafeRelativePathsCannotAuthorizeOpening(string relativePath)
    {
        // Lexically unsafe input remains unsafe even when native lookup failed.
        var input = Contained() with { RelativePath = relativePath, Exists = false };
        Assert.Equal(CitationOriginalDecision.Unsafe, CitationOriginalPolicy.Evaluate(input));
    }

    [Fact]
    public void RequiresAFileStrictlyBelowANonemptyRoot()
    {
        var input = Contained();
        Assert.Equal(CitationOriginalDecision.Unsafe,
            CitationOriginalPolicy.Evaluate(input with { RootComponents = [] }));
        Assert.Equal(CitationOriginalDecision.Unsafe,
            CitationOriginalPolicy.Evaluate(input with { ResolvedComponents = input.RootComponents }));
        Assert.Equal(CitationOriginalDecision.Unavailable,
            CitationOriginalPolicy.Evaluate(input with { IsRegularFile = false }));
    }

    [Fact]
    public void CaseInsensitiveInputStillRequiresCanonicalIdentity()
    {
        var input = Contained() with { CaseSensitive = false };
        Assert.Equal(CitationOriginalDecision.Available, CitationOriginalPolicy.Evaluate(input));
        Assert.Equal(CitationOriginalDecision.Unsafe, CitationOriginalPolicy.Evaluate(input with
        {
            ResolvedComponents = ["volume", "Folder", "docs", "a.txt"]
        }));
        Assert.Equal(CitationOriginalDecision.Unsafe, CitationOriginalPolicy.Evaluate(input with
        {
            RootComponents = ["volume", "é"],
            ResolvedComponents = ["volume", "e\u0301", "docs", "a.txt"]
        }));
    }

    [Fact]
    public void RevisionComparisonAllowsLegacyCitationsAndDetectsLostCurrentRevision()
    {
        var input = Contained();
        Assert.Equal(CitationOriginalDecision.Available,
            CitationOriginalPolicy.Evaluate(input with { CitedRevisionId = null }));
        Assert.Equal(CitationOriginalDecision.Changed,
            CitationOriginalPolicy.Evaluate(input with { CurrentRevisionId = null }));
        Assert.Equal(CitationOriginalDecision.Unavailable,
            CitationOriginalPolicy.Evaluate(input with { CurrentRevisionId = 12, SourceExists = false }));
    }

    [Fact]
    public void ComponentArraysAreCopiedOnConstructionInitializationAndRead()
    {
        string[] root = ["volume", "folder"];
        string[] resolved = ["volume", "folder", "docs", "a.txt"];
        var input = new CitationOriginalInput("docs/a.txt", root, resolved, true, true, true, true, 11, 11);
        root[1] = "outside";
        resolved[1] = "outside";
        Assert.Equal(new[] { "volume", "folder" }, input.RootComponents);
        Assert.Equal(new[] { "volume", "folder", "docs", "a.txt" }, input.ResolvedComponents);

        var returnedRoot = input.RootComponents;
        var returnedResolved = input.ResolvedComponents;
        returnedRoot[1] = "outside";
        returnedResolved[1] = "outside";
        Assert.Equal(CitationOriginalDecision.Available, CitationOriginalPolicy.Evaluate(input));
        Assert.Equal("folder", input.RootComponents[1]);
        Assert.Equal("folder", input.ResolvedComponents[1]);

        string[] replacementRoot = ["volume", "new"];
        string[] replacementResolved = ["volume", "new", "a.txt"];
        var changed = input with { RootComponents = replacementRoot, ResolvedComponents = replacementResolved };
        replacementRoot[1] = "outside";
        replacementResolved[1] = "outside";
        Assert.Equal("new", changed.RootComponents[1]);
        Assert.Equal("new", changed.ResolvedComponents[1]);
        Assert.Equal("folder", input.RootComponents[1]);
        Assert.Equal(CitationOriginalDecision.Available, CitationOriginalPolicy.Evaluate(changed));
    }

    private static CitationOriginalInput Contained() => new("docs/a.txt",
        ["volume", "folder"], ["volume", "folder", "docs", "a.txt"],
        true, true, true, true, 11, 11);
}

using AINotebook.Core.Ingestion;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

public class ChunkerTests
{
    [Fact]
    public void ShortTextProducesSingleChunk()
    {
        var drafts = Chunker.Chunk("Hello world.");
        Assert.Single(drafts);
        Assert.Equal("Hello world.", drafts[0].Text);
        Assert.True(drafts[0].TokenCount > 0);
    }

    [Fact]
    public void EmptyOrWhitespaceProducesNoChunks()
    {
        Assert.Empty(Chunker.Chunk(""));
        Assert.Empty(Chunker.Chunk("   \n\t "));
    }

    [Fact]
    public void LongTextSplitsIntoMultipleChunks()
    {
        var para = string.Concat(Enumerable.Repeat("word ", 2000)); // ~10 000 chars
        var drafts = Chunker.Chunk(para);
        Assert.True(drafts.Count > 1);
        // Every chunk under the hard cap (2 048 chars + small slack for not breaking mid-word).
        foreach (var d in drafts)
        {
            Assert.True(TextElements.Count(d.Text) <= 2_100, $"chunk too big: {TextElements.Count(d.Text)}");
        }
    }

    [Fact]
    public void ChunksOverlap()
    {
        var para = string.Concat(Enumerable.Repeat("word ", 2000));
        var drafts = Chunker.Chunk(para);
        Assert.True(drafts.Count >= 2, "need at least 2 chunks");
        // Last 200 chars of chunk N appear at the start of chunk N+1 (256-char overlap window).
        var tail = new string(drafts[0].Text.AsSpan(drafts[0].Text.Length - 200).ToArray());
        Assert.Contains(tail[..100], drafts[1].Text);
    }

    [Fact]
    public void WindowAndOverlapAreOverridable()
    {
        var drafts = Chunker.Chunk(
            string.Concat(Enumerable.Repeat("a ", 500)),
            windowChars: 200,
            overlapChars: 50);
        Assert.True(drafts.Count > 3);
        foreach (var d in drafts)
        {
            Assert.True(TextElements.Count(d.Text) <= 220);
        }
    }
}

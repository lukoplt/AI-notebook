using Xunit;
using AINotebook.Core.Models;

namespace AINotebook.Core.Tests.Models;

public class SourceTypeTests
{
    // SourceType.testRawValuesAreStable
    [Theory]
    [InlineData(SourceType.Pdf, "pdf")]
    [InlineData(SourceType.Text, "text")]
    [InlineData(SourceType.Markdown, "markdown")]
    [InlineData(SourceType.Web, "web")]
    [InlineData(SourceType.Docx, "docx")]
    [InlineData(SourceType.Pptx, "pptx")]
    [InlineData(SourceType.Xlsx, "xlsx")]
    [InlineData(SourceType.Note, "note")]
    public void RawValues_AreStable(SourceType type, string expected)
    {
        Assert.Equal(expected, type.RawValue());
        Assert.Equal(type, SourceTypeExtensions.FromRawValue(expected));
    }

    // SourceType.testDetectFromFilenameMatchesExtension
    [Theory]
    [InlineData("doc.pdf", SourceType.Pdf)]
    [InlineData("Notes.MD", SourceType.Markdown)] // case-insensitive
    [InlineData("plain.txt", SourceType.Text)]
    [InlineData("deck.pptx", SourceType.Pptx)]
    [InlineData("sheet.xlsx", SourceType.Xlsx)]
    [InlineData("memo.docx", SourceType.Docx)]
    [InlineData("readme.markdown", SourceType.Markdown)]
    public void Detect_MatchesExtension(string filename, SourceType expected)
    {
        Assert.Equal(expected, SourceTypeExtensions.Detect(filename));
    }

    // SourceType.testDetectReturnsNilForUnknown / Note
    [Theory]
    [InlineData("image.png")]
    [InlineData("noextension")]
    [InlineData("scratch.note")] // .note is NOT detectable from a filename
    public void Detect_ReturnsNull_ForUnknown(string filename)
    {
        Assert.Null(SourceTypeExtensions.Detect(filename));
    }

    [Fact]
    public void AllCases_Contains_Note()
    {
        Assert.Contains(SourceType.Note, Enum.GetValues<SourceType>());
    }

    // SourceStatus string values + IsTerminal
    [Theory]
    [InlineData(SourceStatus.Pending, "pending", false)]
    [InlineData(SourceStatus.Chunking, "chunking", false)]
    [InlineData(SourceStatus.Ready, "ready", true)]
    [InlineData(SourceStatus.Error, "error", true)]
    public void SourceStatus_RawValue_And_IsTerminal(SourceStatus status, string raw, bool isTerminal)
    {
        Assert.Equal(raw, status.RawValue());
        Assert.Equal(status, SourceStatusExtensions.FromRawValue(raw));
        Assert.Equal(isTerminal, status.IsTerminal());
    }
}

using System.Text;
using AINotebook.Core.Extractors;
using AINotebook.Core.Models;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Extractors;

public class OfficeTextExtractorTests
{
    private const string Marker = "M3 OFFICE TEST DOCUMENT BODY";

    private static Uri Fixture(string name) =>
        new Uri(Path.Combine(AppContext.BaseDirectory, "Fixtures", name));

    [Fact]
    public async Task ExtractsDocxBodyText()
    {
        var extracted = await new OfficeTextExtractor().ExtractAsync(Fixture("sample.docx"), SourceType.Docx);
        Assert.Contains(Marker, extracted.Text);
        Assert.NotEqual(string.Empty, extracted.Text);
    }

    [Fact]
    public async Task ExtractsPptxSlideText()
    {
        var extracted = await new OfficeTextExtractor().ExtractAsync(Fixture("sample.pptx"), SourceType.Pptx);
        Assert.Contains(Marker, extracted.Text);
    }

    [Fact]
    public async Task ExtractsXlsxSharedStrings()
    {
        var extracted = await new OfficeTextExtractor().ExtractAsync(Fixture("sample.xlsx"), SourceType.Xlsx);
        Assert.Contains(Marker, extracted.Text);
    }

    /// <summary>The legacy extractor shares the bounded OOXML reader (same as macOS): the main part comes
    /// from the package relationships ("/word/document2.xml") and slides follow presentation order.</summary>
    [Fact]
    public async Task ResolvesMainPartAndSlideOrderLikeTheBoundedReader()
    {
        var docx = await new OfficeTextExtractor().ExtractAsync(
            new Uri(SharedFixtures.Path("ingestion/document2.docx")), SourceType.Docx);
        Assert.Equal("Alpha\tBeta\nBefore \nBox\nAfter\nCell", docx.Text);
        Assert.Equal("document2", docx.Title);
        var pptx = await new OfficeTextExtractor().ExtractAsync(
            new Uri(SharedFixtures.Path("ingestion/slides.pptx")), SourceType.Pptx);
        Assert.Equal("## Slide 1\nA\n\n## Slide 2\nB", pptx.Text);
    }

    [Fact]
    public async Task MissingMainPartIsDistinct()
    {
        var dir = Path.Combine(Path.GetTempPath(), "nomain-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "empty.docx");
        using (var archive = new System.IO.Compression.ZipArchive(File.Create(path), System.IO.Compression.ZipArchiveMode.Create))
        using (var writer = new StreamWriter(archive.CreateEntry("[Content_Types].xml").Open()))
            writer.Write("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>");
        try
        {
            await Assert.ThrowsAsync<ExtractorException.OfficeMainPartMissing>(
                () => new OfficeTextExtractor().ExtractAsync(new Uri(path), SourceType.Docx));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public async Task CorruptArchiveThrows()
    {
        var dir = Path.Combine(Path.GetTempPath(), "notzip-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "fake.docx");
        File.WriteAllBytes(path, Encoding.UTF8.GetBytes("not a zip"));
        try
        {
            await Assert.ThrowsAsync<ExtractorException.OfficeArchiveCorrupt>(
                () => new OfficeTextExtractor().ExtractAsync(new Uri(path), SourceType.Docx));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}

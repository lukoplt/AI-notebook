using System.Text;
using AINotebook.Core.Extractors;
using AINotebook.Core.Models;
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

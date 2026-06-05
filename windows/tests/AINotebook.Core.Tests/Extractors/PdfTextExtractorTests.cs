using System.Text;
using AINotebook.Core.Extractors;
using AINotebook.Core.Models;
using Xunit;

namespace AINotebook.Core.Tests.Extractors;

public class PdfTextExtractorTests
{
    private static Uri Fixture(string name) =>
        new Uri(Path.Combine(AppContext.BaseDirectory, "Fixtures", name));

    [Fact]
    public async Task ExtractsTextFromMultiPagePDF()
    {
        var extracted = await new PdfTextExtractor().ExtractAsync(Fixture("sample.pdf"), SourceType.Pdf);
        Assert.Contains("First page text", extracted.Text);
        Assert.Contains("Second page text", extracted.Text);
        Assert.Equal("sample", extracted.Title);
    }

    [Fact]
    public async Task ThrowsOnNonPDF()
    {
        var dir = Path.Combine(Path.GetTempPath(), "notpdf-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "fake.pdf");
        File.WriteAllBytes(path, Encoding.UTF8.GetBytes("not a pdf"));
        try
        {
            await Assert.ThrowsAsync<ExtractorException.PdfOpenFailed>(
                () => new PdfTextExtractor().ExtractAsync(new Uri(path), SourceType.Pdf));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}

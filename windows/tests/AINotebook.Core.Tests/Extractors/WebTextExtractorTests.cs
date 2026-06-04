using AINotebook.Core.Extractors;
using Xunit;

namespace AINotebook.Core.Tests.Extractors;

public class WebTextExtractorTests
{
    [Fact]
    public void ExtractsArticleBodyAndTitleFromHtml()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "sample.html");
        string html = File.ReadAllText(path);
        var extracted = WebTextExtractor.ParseHtml(html, new Uri("https://example.com/a"));
        Assert.Equal("Sample Article", extracted.Title);
        Assert.Contains("main article body", extracted.Text);
        Assert.Contains("Another paragraph", extracted.Text);
        Assert.DoesNotContain("never extract me", extracted.Text); // script stripped
        Assert.DoesNotContain("Site nav", extracted.Text);          // nav stripped
        Assert.DoesNotContain("Copyright", extracted.Text);         // footer stripped
    }

    [Fact]
    public void ParseHtmlThrowsOnEmptyBody()
    {
        const string html = "<html><head><title>T</title></head><body></body></html>";
        Assert.Throws<ExtractorException.EmptyContent>(
            () => WebTextExtractor.ParseHtml(html, new Uri("https://example.com")));
    }
}

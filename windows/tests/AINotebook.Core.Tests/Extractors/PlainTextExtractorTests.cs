using System.Text;
using AINotebook.Core.Extractors;
using AINotebook.Core.Models;
using Xunit;

namespace AINotebook.Core.Tests.Extractors;

public class PlainTextExtractorTests : IDisposable
{
    private readonly string _dir;

    public PlainTextExtractorTests()
    {
        _dir = Path.Combine(Path.GetTempPath(), "ai-notebook-tests-" + Guid.NewGuid());
        Directory.CreateDirectory(_dir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { /* ignore */ }
    }

    private Uri WriteTempFile(string name, byte[] bytes)
    {
        var path = Path.Combine(_dir, name);
        File.WriteAllBytes(path, bytes);
        return new Uri(path);
    }

    [Fact]
    public async Task ExtractsUtf8Plaintext()
    {
        var url = WriteTempFile("memo.txt", Encoding.UTF8.GetBytes("Hello, world."));
        var extracted = await new PlainTextExtractor().ExtractAsync(url, SourceType.Text);
        Assert.Equal("Hello, world.", extracted.Text);
        Assert.Equal("memo", extracted.Title);
    }

    [Fact]
    public async Task StripsMarkdownLeadingHashes()
    {
        const string md = "# Title\n\nSome **bold** body.";
        var url = WriteTempFile("doc.md", Encoding.UTF8.GetBytes(md));
        var extracted = await new PlainTextExtractor().ExtractAsync(url, SourceType.Markdown);
        // Title is the first Markdown heading.
        Assert.Equal("Title", extracted.Title);
        // Markdown body retained (raw text exposed, markup not stripped).
        Assert.Contains("Some **bold** body.", extracted.Text);
    }

    [Fact]
    public async Task EmptyFileThrows()
    {
        var url = WriteTempFile("empty.txt", Array.Empty<byte>());
        await Assert.ThrowsAsync<ExtractorException.EmptyContent>(
            () => new PlainTextExtractor().ExtractAsync(url, SourceType.Text));
    }
}

using System.Text;
using AINotebook.Core.Models;

namespace AINotebook.Core.Extractors;

/// <summary>1:1 port of Sources/AINotebookCore/PlainTextExtractor.swift. UTF-8 only.</summary>
public sealed class PlainTextExtractor : ITextExtractor
{
    public Task<ExtractedText> ExtractAsync(Uri url, SourceType kind)
    {
        byte[] data;
        try
        {
            data = File.ReadAllBytes(url.LocalPath);
        }
        catch
        {
            throw new ExtractorException.FileNotReadable(url);
        }

        string text;
        try
        {
            // UTF-8 ONLY: throwOnInvalidBytes mirrors String(data:, encoding:.utf8) returning nil.
            var encoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
            text = encoding.GetString(data);
        }
        catch (DecoderFallbackException)
        {
            throw new ExtractorException.UnsupportedEncoding(url);
        }

        string trimmed = text.Trim();
        if (trimmed.Length == 0)
        {
            throw new ExtractorException.EmptyContent();
        }

        string title;
        string? h1 = kind == SourceType.Markdown ? FirstMarkdownHeading(text) : null;
        if (h1 != null)
        {
            title = h1;
        }
        else
        {
            title = Path.GetFileNameWithoutExtension(url.LocalPath);
        }

        return Task.FromResult(new ExtractedText(title, trimmed));
    }

    private static string? FirstMarkdownHeading(string raw)
    {
        foreach (var line in raw.Split('\n', '\r'))
        {
            string t = line.Trim(' ', '\t');
            if (t.StartsWith("# ", StringComparison.Ordinal))
            {
                return t.Substring(2).Trim(' ', '\t');
            }
        }
        return null;
    }
}

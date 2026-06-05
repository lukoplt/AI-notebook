using System.Text.RegularExpressions;
using AINotebook.Core.Models;
using AngleSharp.Dom;
using AngleSharp.Html.Parser;

namespace AINotebook.Core.Extractors;

/// <summary>
/// 1:1 port of Sources/AINotebookCore/WebExtractor.swift (URLSession + SwiftSoup
/// -> HttpClient + AngleSharp). Network fetch + content-type guard, then a pure,
/// network-free ParseHtml (tested directly).
/// </summary>
public sealed class WebTextExtractor : ITextExtractor
{
    private static readonly string[] StripTags =
        { "script", "style", "nav", "footer", "aside", "header", "noscript", "form" };
    private static readonly Regex WhitespaceRun = new(@"\s+", RegexOptions.Compiled);

    private readonly HttpClient _http;

    public WebTextExtractor(HttpClient? http = null)
    {
        _http = http ?? new HttpClient();
    }

    public async Task<ExtractedText> ExtractAsync(Uri url, SourceType kind)
    {
        HttpResponseMessage response;
        try
        {
            response = await _http.GetAsync(url);
        }
        catch
        {
            // No HTTP response at all (connection failure) -> status 0.
            throw new ExtractorException.WebFetchFailed(url, 0);
        }

        using (response)
        {
            int code = (int)response.StatusCode;
            if (code < 200 || code >= 300)
            {
                throw new ExtractorException.WebFetchFailed(url, code);
            }

            string? mime = response.Content.Headers.ContentType?.ToString();
            if (!(mime ?? string.Empty).ToLowerInvariant().Contains("text/html"))
            {
                throw new ExtractorException.WebResponseNotHtml(url, mime);
            }

            string html = await response.Content.ReadAsStringAsync();
            return ParseHtml(html, url);
        }
    }

    /// <summary>Pure HTML -> ExtractedText. Network-free; tested directly.</summary>
    public static ExtractedText ParseHtml(string html, Uri sourceUrl)
    {
        var parser = new HtmlParser();
        IDocument doc = parser.ParseDocument(html);

        // Remove non-content elements before reading the body, in this exact order.
        foreach (var tag in StripTags)
        {
            foreach (var el in doc.QuerySelectorAll(tag).ToArray())
            {
                el.Remove();
            }
        }

        // Prefer <article> when present, otherwise <main>, otherwise <body>.
        IElement? root = doc.QuerySelector("article")
            ?? doc.QuerySelector("main")
            ?? doc.Body;
        if (root == null)
        {
            throw new ExtractorException.EmptyContent();
        }

        // AngleSharp's TextContent does NOT collapse whitespace; collapse runs to a
        // single space and trim to match SwiftSoup .text().
        string text = WhitespaceRun.Replace(root.TextContent, " ").Trim();
        if (text.Length == 0)
        {
            throw new ExtractorException.EmptyContent();
        }

        string docTitle = doc.Title ?? string.Empty;
        string title = docTitle.Length == 0
            ? (sourceUrl.Host.Length != 0 ? sourceUrl.Host : "Web source")
            : docTitle;

        return new ExtractedText(title, text);
    }
}

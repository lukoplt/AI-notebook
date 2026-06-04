using AINotebook.Core.Models;
using UglyToad.PdfPig;

namespace AINotebook.Core.Extractors;

/// <summary>
/// 1:1 port of Sources/AINotebookCore/PDFExtractor.swift (PDFKit -> PdfPig).
/// Skips empty pages; joins non-empty trimmed page texts with form feed U+000C;
/// page hints are 1-based (PdfPig page.Number == Swift original index + 1).
/// </summary>
public sealed class PdfTextExtractor : ITextExtractor
{
    private const char FormFeed = '\u000C';

    public Task<ExtractedText> ExtractAsync(Uri url, SourceType kind)
    {
        PdfDocument doc;
        try
        {
            doc = PdfDocument.Open(url.LocalPath);
        }
        catch
        {
            throw new ExtractorException.PdfOpenFailed(url);
        }

        using (doc)
        {
            var parts = new List<string>();
            var hints = new List<int>();
            foreach (var page in doc.GetPages())
            {
                string trimmed = page.Text.Trim();
                if (trimmed.Length != 0)
                {
                    parts.Add(trimmed);
                    hints.Add(page.Number); // 1-based, == Swift i + 1
                }
            }

            string joined = string.Join(FormFeed, parts).Trim();
            if (joined.Length == 0)
            {
                throw new ExtractorException.EmptyContent();
            }

            string? infoTitle = doc.Information.Title;
            string title = !string.IsNullOrEmpty(infoTitle)
                ? infoTitle!
                : Path.GetFileNameWithoutExtension(url.LocalPath);

            return Task.FromResult(new ExtractedText(title, joined, hints.ToArray()));
        }
    }
}

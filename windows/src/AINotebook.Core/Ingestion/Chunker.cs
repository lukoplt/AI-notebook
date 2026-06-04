using AINotebook.Core.Models;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// Pure, deterministic text splitter. Produces overlapping windows of
/// approximately windowChars grapheme clusters. Always breaks on whitespace
/// boundaries so words are never split. 1:1 port of Sources/AINotebookCore/Chunker.swift.
/// Counting is by extended grapheme cluster (Swift Character), NOT UTF-16 code units.
/// </summary>
public static class Chunker
{
    private const int BackScanBound = 200; // literal bound from the Swift source

    public static List<ChunkDraft> Chunk(string raw, int windowChars = 2048, int overlapChars = 256)
    {
        if (windowChars <= overlapChars)
        {
            throw new ArgumentException("overlap must be smaller than window", nameof(overlapChars));
        }

        string cleaned = raw.Trim();
        if (cleaned.Length == 0)
        {
            return new List<ChunkDraft>();
        }

        var chars = TextElements.Split(cleaned);
        if (chars.Count <= windowChars)
        {
            return new List<ChunkDraft> { new ChunkDraft(cleaned, EstimateTokens(cleaned)) };
        }

        var drafts = new List<ChunkDraft>();
        int start = 0;
        while (start < chars.Count)
        {
            int end = Math.Min(start + windowChars, chars.Count);
            // Avoid splitting mid-word: scan backwards to the previous whitespace,
            // but only up to 200 chars to bound the search.
            if (end < chars.Count)
            {
                int probe = end;
                int floor = Math.Max(end - BackScanBound, start + 1);
                while (probe > floor && !IsWhitespaceElement(chars[probe - 1]))
                {
                    probe--;
                }
                if (probe > floor)
                {
                    end = probe;
                }
            }

            string slice = string.Concat(chars.GetRange(start, end - start)).Trim();
            if (slice.Length != 0)
            {
                drafts.Add(new ChunkDraft(slice, EstimateTokens(slice)));
            }

            if (end >= chars.Count)
            {
                break;
            }
            start = Math.Max(end - overlapChars, start + 1);
        }

        return drafts;
    }

    /// <summary>1 token ~= 4 chars, with a minimum of 1. count is the grapheme-cluster count.</summary>
    public static int EstimateTokens(string text)
    {
        int count = TextElements.Count(text);
        return Math.Max(1, (count + 3) / 4);
    }

    /// <summary>
    /// Like Chunk but takes (text, pageHint) pairs and tags chunks with the page
    /// they came from. Chunks are flattened in page order; ordinals are assigned
    /// later by ReplaceChunks.
    /// </summary>
    public static List<ChunkDraft> ChunkPaged(
        IEnumerable<(string text, int pageHint)> pages,
        int windowChars = 2048,
        int overlapChars = 256)
    {
        var outp = new List<ChunkDraft>();
        foreach (var page in pages)
        {
            foreach (var d in Chunk(page.text, windowChars, overlapChars))
            {
                outp.Add(new ChunkDraft(d.Text, d.TokenCount, page.pageHint));
            }
        }
        return outp;
    }

    // Swift Character.isWhitespace: a grapheme cluster is whitespace when its
    // first scalar is a Unicode whitespace code point. Mirror with char.IsWhiteSpace
    // over the first rune of the element.
    private static bool IsWhitespaceElement(string element)
    {
        if (element.Length == 0)
        {
            return false;
        }
        var runes = element.EnumerateRunes();
        foreach (var r in runes)
        {
            return System.Text.Rune.IsWhiteSpace(r);
        }
        return false;
    }
}

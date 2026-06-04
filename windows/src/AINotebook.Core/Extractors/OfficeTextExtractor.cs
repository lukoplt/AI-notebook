using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;
using AINotebook.Core.Models;

namespace AINotebook.Core.Extractors;

/// <summary>
/// 1:1 port of Sources/AINotebookCore/OfficeExtractor.swift (ZIPFoundation + XMLParser
/// -> System.IO.Compression + System.Xml). Harvests ALL character-data nodes
/// namespace-agnostically; pptx slides sorted with PLAIN ordinal sort (slide10 before slide2).
/// </summary>
public sealed class OfficeTextExtractor : ITextExtractor
{
    private static readonly Regex WhitespaceRun = new(@"\s+", RegexOptions.Compiled);

    public Task<ExtractedText> ExtractAsync(Uri url, SourceType kind)
    {
        ZipArchive archive;
        try
        {
            archive = ZipFile.OpenRead(url.LocalPath);
        }
        catch
        {
            throw new ExtractorException.OfficeArchiveCorrupt(url);
        }

        using (archive)
        {
            IReadOnlyList<string> xmlPaths = kind switch
            {
                SourceType.Docx => new[] { "word/document.xml" },
                SourceType.Pptx => SlidePaths(archive),
                SourceType.Xlsx => new[] { "xl/sharedStrings.xml" },
                _ => throw new ExtractorException.OfficeArchiveCorrupt(url),
            };

            var collected = new List<string>();
            foreach (var path in xmlPaths)
            {
                var entry = archive.GetEntry(path);
                if (entry == null)
                {
                    continue; // missing entry skipped silently
                }

                byte[] bytes;
                try
                {
                    using var s = entry.Open();
                    using var ms = new MemoryStream();
                    s.CopyTo(ms);
                    bytes = ms.ToArray();
                }
                catch
                {
                    throw new ExtractorException.OfficeArchiveCorrupt(url);
                }

                string text = ParseXmlTextNodes(bytes);
                if (text.Length != 0)
                {
                    collected.Add(text);
                }
            }

            string joined = string.Join("\n\n", collected).Trim();
            if (joined.Length == 0)
            {
                throw new ExtractorException.EmptyContent();
            }

            string title = Path.GetFileNameWithoutExtension(url.LocalPath);
            return Task.FromResult(new ExtractedText(title, joined));
        }
    }

    /// <summary>
    /// pptx stores each slide as ppt/slides/slideN.xml. Enumerate them and sort
    /// with a PLAIN ordinal string sort to match Swift's .sorted() exactly
    /// (slide10.xml sorts before slide2.xml — do NOT natural-sort).
    /// </summary>
    private static List<string> SlidePaths(ZipArchive archive)
    {
        var paths = new List<string>();
        foreach (var entry in archive.Entries)
        {
            string p = entry.FullName;
            if (p.StartsWith("ppt/slides/slide", StringComparison.Ordinal)
                && p.EndsWith(".xml", StringComparison.Ordinal))
            {
                paths.Add(p);
            }
        }
        paths.Sort(StringComparer.Ordinal);
        return paths;
    }

    /// <summary>
    /// SAX-style harvest of every character-data node. Trim each fragment, keep
    /// non-empty, join with single space, collapse \s+ to one space, trim.
    /// </summary>
    internal static string ParseXmlTextNodes(byte[] data)
    {
        var fragments = new List<string>();
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Ignore,
            IgnoreComments = true,
            IgnoreProcessingInstructions = true,
        };
        using var ms = new MemoryStream(data);
        using var reader = XmlReader.Create(ms, settings);
        while (reader.Read())
        {
            if (reader.NodeType is XmlNodeType.Text
                or XmlNodeType.CDATA
                or XmlNodeType.SignificantWhitespace
                or XmlNodeType.Whitespace)
            {
                string t = reader.Value.Trim();
                if (t.Length != 0)
                {
                    fragments.Add(t);
                }
            }
        }

        string joined = string.Join(" ", fragments);
        return WhitespaceRun.Replace(joined, " ").Trim();
    }
}

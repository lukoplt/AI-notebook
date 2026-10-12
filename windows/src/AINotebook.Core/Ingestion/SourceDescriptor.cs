using System.Text.Json;
using AINotebook.Core.Language;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// Deterministic, prose-free source metadata. Never contains summaries, LLM output or absolute paths.
/// <c>Lang</c> is serialized as an explicit JSON null when unknown.
/// </summary>
public sealed record SourceDescriptor(int Version, string Title, string Type, int PageCount, int SheetCount, long SizeBytes, string? Lang)
{
    /// <summary>Title preference: nonblank embedded title, first Markdown <c># </c> heading, filename without extension.</summary>
    public static SourceDescriptor Make(CanonicalDocument document, string filename, long sizeBytes, string? lang)
    {
        ArgumentNullException.ThrowIfNull(document);
        ArgumentNullException.ThrowIfNull(filename);
        string title = !string.IsNullOrWhiteSpace(document.Title) ? document.Title.Trim()
            : MarkdownHeading(document) ?? FileTitle(filename);
        return new SourceDescriptor(1, title, document.Kind, document.Pages.Count, document.SheetNames.Count, sizeBytes, lang);
    }

    public string ToJson()
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteNumber("version", Version);
            writer.WriteString("title", Title);
            writer.WriteString("type", Type);
            writer.WriteNumber("pageCount", PageCount);
            writer.WriteNumber("sheetCount", SheetCount);
            writer.WriteNumber("sizeBytes", SizeBytes);
            if (Lang is null) writer.WriteNull("lang");
            else writer.WriteString("lang", Lang);
            writer.WriteEndObject();
        }
        return System.Text.Encoding.UTF8.GetString(buffer.ToArray());
    }

    /// <summary>Lang coverage JSON <c>{version,langCoverageBp,sharesBp,unknownShareBp}</c>, shares in ordinal key order.</summary>
    public static string CoverageJson(LanguageDocumentResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        return CoverageJson(result.LangCoverageBp, result.SharesBp, result.UnknownShareBp);
    }

    internal static string CoverageJson(LanguageAggregate result)
    {
        ArgumentNullException.ThrowIfNull(result);
        return CoverageJson(result.LangCoverageBp, result.SharesBp, result.UnknownShareBp);
    }

    private static string CoverageJson(long langCoverageBp, IReadOnlyDictionary<string, long> sharesBp, long unknownShareBp)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteNumber("version", 1);
            writer.WriteNumber("langCoverageBp", langCoverageBp);
            writer.WriteStartObject("sharesBp");
            foreach (var (label, share) in sharesBp.OrderBy(p => p.Key, StringComparer.Ordinal))
                writer.WriteNumber(label, share);
            writer.WriteEndObject();
            writer.WriteNumber("unknownShareBp", unknownShareBp);
            writer.WriteEndObject();
        }
        return System.Text.Encoding.UTF8.GetString(buffer.ToArray());
    }

    private static string? MarkdownHeading(CanonicalDocument document)
    {
        if (document.Kind != "markdown") return null;
        foreach (string line in document.Text.Split('\n'))
            if (line.StartsWith("# ", StringComparison.Ordinal) && line[2..].Trim() is { Length: > 0 } heading)
                return heading;
        return null;
    }

    private static string FileTitle(string filename)
    {
        string name = filename[(filename.LastIndexOfAny(['/', '\\']) + 1)..];
        int dot = name.LastIndexOf('.');
        string title = dot > 0 ? name[..dot] : name;
        return title.Trim().Length == 0 ? name : title.Trim();
    }
}

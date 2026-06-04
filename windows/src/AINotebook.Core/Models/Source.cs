using System.IO;

namespace AINotebook.Core.Models;

public enum SourceType { Pdf, Text, Markdown, Web, Docx, Pptx, Xlsx, Note }

public static class SourceTypeExtensions
{
    public static string RawValue(this SourceType type) => type switch
    {
        SourceType.Pdf => "pdf",
        SourceType.Text => "text",
        SourceType.Markdown => "markdown",
        SourceType.Web => "web",
        SourceType.Docx => "docx",
        SourceType.Pptx => "pptx",
        SourceType.Xlsx => "xlsx",
        SourceType.Note => "note",
        _ => throw new ArgumentOutOfRangeException(nameof(type), type, null)
    };

    public static SourceType FromRawValue(string raw) => raw switch
    {
        "pdf" => SourceType.Pdf,
        "text" => SourceType.Text,
        "markdown" => SourceType.Markdown,
        "web" => SourceType.Web,
        "docx" => SourceType.Docx,
        "pptx" => SourceType.Pptx,
        "xlsx" => SourceType.Xlsx,
        "note" => SourceType.Note,
        _ => throw new ArgumentOutOfRangeException(nameof(raw), raw, "Unknown SourceType raw value")
    };

    // DB-mapper aliases (consumed by NotebookStore partials in Tasks 7-11).
    public static string ToDb(this SourceType v) => v.RawValue();
    public static SourceType FromDb(string raw) => FromRawValue(raw);

    /// <summary>Best-effort detection from a filename. Returns null for unknown extensions.
    /// Mirrors Swift SourceType.detect(filename:). Note: ".note" is never detected here.</summary>
    public static SourceType? Detect(string filename)
    {
        // Path.GetExtension returns ".md" (with the dot); trim it and lowercase to match
        // (filename as NSString).pathExtension.lowercased().
        var ext = Path.GetExtension(filename).TrimStart('.').ToLowerInvariant();
        return ext switch
        {
            "pdf" => SourceType.Pdf,
            "txt" => SourceType.Text,
            "md" or "markdown" => SourceType.Markdown,
            "docx" => SourceType.Docx,
            "pptx" => SourceType.Pptx,
            "xlsx" => SourceType.Xlsx,
            _ => null
        };
    }
}

public enum SourceStatus { Pending, Chunking, Ready, Error }

public static class SourceStatusExtensions
{
    public static string RawValue(this SourceStatus status) => status switch
    {
        SourceStatus.Pending => "pending",
        SourceStatus.Chunking => "chunking",
        SourceStatus.Ready => "ready",
        SourceStatus.Error => "error",
        _ => throw new ArgumentOutOfRangeException(nameof(status), status, null)
    };

    public static SourceStatus FromRawValue(string raw) => raw switch
    {
        "pending" => SourceStatus.Pending,
        "chunking" => SourceStatus.Chunking,
        "ready" => SourceStatus.Ready,
        "error" => SourceStatus.Error,
        _ => throw new ArgumentOutOfRangeException(nameof(raw), raw, "Unknown SourceStatus raw value")
    };

    // DB-mapper aliases (consumed by NotebookStore partials in Tasks 7-11).
    public static string ToDb(this SourceStatus v) => v.RawValue();
    public static SourceStatus FromDb(string raw) => FromRawValue(raw);

    /// <summary>true for Ready/Error; false for Pending/Chunking (Swift SourceStatus.isTerminal).</summary>
    public static bool IsTerminal(this SourceStatus status) =>
        status is SourceStatus.Ready or SourceStatus.Error;
}

public record Source(
    long? Id,
    long NotebookId,
    SourceType Type,
    string Title,
    string? Uri,
    string? RawPath,
    SourceStatus Status,
    string? Error,
    DateTime IngestedAt);

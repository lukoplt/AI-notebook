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

    public static string ToDb(this SourceType v) => v.RawValue();
    public static SourceType FromDb(string raw) => FromRawValue(raw);

    public static SourceType? Detect(string filename)
    {
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

    public static string ToDb(this SourceStatus v) => v.RawValue();
    public static SourceStatus FromDb(string raw) => FromRawValue(raw);

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
    DateTime IngestedAt,
    DateTime? LastSyncedAt = null,
    string? ContentHash = null);

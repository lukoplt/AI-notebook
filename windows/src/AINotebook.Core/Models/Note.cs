namespace AINotebook.Core.Models;

public enum NoteOrigin { Manual, Chat, Transformation }

public static class NoteOriginExtensions
{
    public static string RawValue(this NoteOrigin origin) => origin switch
    {
        NoteOrigin.Manual => "manual",
        NoteOrigin.Chat => "chat",
        NoteOrigin.Transformation => "transformation",
        _ => throw new ArgumentOutOfRangeException(nameof(origin), origin, null)
    };

    public static NoteOrigin FromRawValue(string raw) => raw switch
    {
        "manual" => NoteOrigin.Manual,
        "chat" => NoteOrigin.Chat,
        "transformation" => NoteOrigin.Transformation,
        _ => throw new ArgumentOutOfRangeException(nameof(raw), raw, "Unknown NoteOrigin raw value")
    };

    // DB-mapper aliases (consumed by NotebookStore partials in Tasks 7-11).
    public static string ToDb(this NoteOrigin v) => v.RawValue();
    public static NoteOrigin FromDb(string raw) => FromRawValue(raw);
}

public record Note(
    long? Id,
    long NotebookId,
    string Title,
    string BodyMd,
    NoteOrigin Origin,
    long? OriginRef,
    long? AutoSourceId,
    string NoteUuid,
    DateTime CreatedAt,
    DateTime UpdatedAt);

public record NoteAttachment(
    long? Id,
    long NoteId,
    string NoteUuid,
    string Filename,
    string Mime,
    long ByteSize,
    DateTime CreatedAt);

public enum NoteVersionReason { Autosave, Manual, Restore }

public static class NoteVersionReasonExtensions
{
    public static string RawValue(this NoteVersionReason reason) => reason switch
    {
        NoteVersionReason.Autosave => "autosave",
        NoteVersionReason.Manual => "manual",
        NoteVersionReason.Restore => "restore",
        _ => throw new ArgumentOutOfRangeException(nameof(reason), reason, null)
    };

    public static NoteVersionReason FromRawValue(string raw) => raw switch
    {
        "autosave" => NoteVersionReason.Autosave,
        "manual" => NoteVersionReason.Manual,
        "restore" => NoteVersionReason.Restore,
        _ => throw new ArgumentOutOfRangeException(nameof(raw), raw, "Unknown NoteVersionReason raw value")
    };

    // DB-mapper aliases (consumed by NotebookStore partials in Tasks 7-11).
    public static string ToDb(this NoteVersionReason v) => v.RawValue();
    public static NoteVersionReason FromDb(string raw) => FromRawValue(raw);
}

public record NoteVersion(
    long? Id,
    long NoteId,
    string Title,
    string BodyMd,
    DateTime SavedAt,
    NoteVersionReason Reason);

namespace AINotebook.Core.Models;

public record ChatSession(
    long? Id,
    long NotebookId,
    string Title,
    DateTime CreatedAt);

public enum ChatRole { System, User, Assistant }

public static class ChatRoleExtensions
{
    public static string RawValue(this ChatRole role) => role switch
    {
        ChatRole.System => "system",
        ChatRole.User => "user",
        ChatRole.Assistant => "assistant",
        _ => throw new ArgumentOutOfRangeException(nameof(role), role, null)
    };

    // Swift decode fallback on unknown raw value => .user
    public static ChatRole FromRawValue(string raw) => raw switch
    {
        "system" => ChatRole.System,
        "assistant" => ChatRole.Assistant,
        _ => ChatRole.User
    };

    // DB-mapper aliases (consumed by NotebookStore partials in Tasks 7-11).
    public static string ToDb(this ChatRole v) => v.RawValue();
    public static ChatRole FromDb(string raw) => FromRawValue(raw);
}

// Swift Int is 64-bit: offsets must support the full JSON-safe integer range.
public record CitationSpan(long Start, long End, int? PageFrom, int? PageTo);

public record Citation(
    int Marker,
    long ChunkId,
    long SourceId,
    string Snippet)
{
    public long? FolderId { get; init; }
    public string? RelPath { get; init; }
    public string? DisplayName { get; init; }
    public long? RevisionId { get; init; }
    public IReadOnlyList<CitationSpan> Spans { get; init; } = Array.Empty<CitationSpan>();
    public IReadOnlyList<long> ChunkIds { get; init; } = Array.Empty<long>();
    public string? Text { get; init; }

    public bool IsV2 => FolderId is not null || RelPath is not null || DisplayName is not null
        || RevisionId is not null || Spans.Count > 0 || ChunkIds.Count > 0 || Text is not null;
}

public record ChatMessage(
    long? Id,
    long SessionId,
    ChatRole Role,
    string Content,
    IReadOnlyList<Citation> Citations,
    DateTime CreatedAt,
    string? Model = null);

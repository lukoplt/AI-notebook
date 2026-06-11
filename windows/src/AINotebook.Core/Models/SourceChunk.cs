namespace AINotebook.Core.Models;

public record SourceChunk(
    long? Id,
    long SourceId,
    int Ord,
    string Text,
    int TokenCount,
    int? PageHint,
    string? Context = null);

public sealed record ChunkDraft(
    string Text,
    int TokenCount,
    int? PageHint = null);

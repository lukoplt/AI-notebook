namespace AINotebook.Core.Models;

public record SourceChunk(
    long? Id,
    long SourceId,
    int Ord,
    string Text,
    int TokenCount,
    int? PageHint,
    string? Context = null,
    long? RevisionId = null,
    int? CharStart = null,
    int? CharEnd = null,
    string? Lang = null,
    bool LangInherited = false);

public sealed record ChunkDraft(
    string Text,
    int TokenCount,
    int? PageHint = null);

namespace AINotebook.Core.Storage;

/// <summary>A page's immutable scalar interval in one revision's canonical text.</summary>
public sealed record RevisionPage(long RevisionId, int Page, int CharStart, int CharEnd);

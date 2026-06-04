namespace AINotebook.Core.Extractors;

/// <summary>
/// Result of extraction. PageHints carries one int per PAGE segment (NOT per
/// chunk); null when the extractor cannot determine page boundaries
/// (txt / md / web / Office). 1:1 port of Sources/AINotebookCore/TextExtractor.swift.
/// </summary>
public sealed record ExtractedText(string Title, string Text, int[]? PageHints = null);

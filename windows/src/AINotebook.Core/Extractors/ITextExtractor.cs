using AINotebook.Core.Models;

namespace AINotebook.Core.Extractors;

/// <summary>
/// Extract normalized text. kind is the caller's best guess at the source type
/// (the extractor may double-check it). Port of TextExtractor protocol.
/// </summary>
public interface ITextExtractor
{
    Task<ExtractedText> ExtractAsync(Uri url, SourceType kind);
}

using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;

namespace AINotebook.Core.Extractors;

/// <summary>
/// Legacy <see cref="ITextExtractor"/> for .docx/.pptx/.xlsx (injectable into IngestionService). It
/// shares the bounded OOXML reader used by folder and loose-file indexing, so both resolve the main
/// part through the package relationships (e.g. word/document2.xml) and order slides by presentation
/// order. Same behaviour as macOS OfficeExtractor.
/// </summary>
public sealed class OfficeTextExtractor : ITextExtractor
{
    public async Task<ExtractedText> ExtractAsync(Uri url, SourceType kind)
    {
        if (kind is not (SourceType.Docx or SourceType.Pptx or SourceType.Xlsx))
            throw new ExtractorException.OfficeArchiveCorrupt(url);
        CanonicalDocument document;
        try
        {
            document = await new BoundedDocumentExtractor().ExtractAsync(url, kind, FolderRules.Defaults).ConfigureAwait(false);
        }
        catch (FolderIngestionException error) when (error.Code == "missingMainPart")
        {
            throw new ExtractorException.OfficeMainPartMissing(url);
        }
        catch (FolderIngestionException error)
            when (error.Code is "corruptArchive" or "invalidRelationship" or "invalidCell" or "unsupportedSyntax")
        {
            throw new ExtractorException.OfficeArchiveCorrupt(url);
        }
        string text = document.Text.Trim();
        if (text.Length == 0) throw new ExtractorException.EmptyContent();
        return new ExtractedText(Path.GetFileNameWithoutExtension(url.LocalPath), text);
    }
}

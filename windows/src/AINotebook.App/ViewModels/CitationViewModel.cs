using AINotebook.Core.Models;

namespace AINotebook.App.ViewModels;

public sealed class CitationViewModel
{
    public required Citation Citation { get; init; }
    public required string SourceTitle { get; init; }
    public int? PageHint { get; init; }
    public string? PdfFilePath { get; init; }   // absolute path when source is a PDF with rawPath
    public long? NoteIdToOpen { get; init; }     // owning note id when source.type == note

    public string Marker => $"[{Citation.Marker}]";
    public string Snippet => Citation.Snippet;
}

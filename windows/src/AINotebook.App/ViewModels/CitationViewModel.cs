using System;
using System.Linq;
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

    // Mirrors ChatView.showCitation(): resolve source/page/note metadata for the Flyout.
    // Shared by ChatViewModel and NotesChatPanelViewModel.
    public static CitationViewModel Resolve(AINotebook.Core.Storage.NotebookStore store, Citation c)
    {
        var source = store.Source(c.SourceId);
        var chunks = source is null ? Array.Empty<SourceChunk>() : store.Chunks(c.SourceId).ToArray();
        int? hint = chunks.FirstOrDefault(ch => ch.Id == c.ChunkId)?.PageHint;
        var isPdf = source?.Type == SourceType.Pdf;
        var pdfPath = (isPdf && source?.RawPath is { Length: > 0 }) ? source.RawPath : null;

        long? noteId = null;
        if (source?.Type == SourceType.Note && source is not null)
        {
            var notes = store.Notes(source.NotebookId);
            noteId = notes.FirstOrDefault(n => n.AutoSourceId == source.Id)?.Id;
        }
        return new CitationViewModel
        {
            Citation = c,
            SourceTitle = source?.Title ?? "",
            PageHint = hint,
            PdfFilePath = pdfPath,
            NoteIdToOpen = noteId
        };
    }
}

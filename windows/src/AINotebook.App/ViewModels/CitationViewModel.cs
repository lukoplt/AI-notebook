using System;
using System.Linq;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;

namespace AINotebook.App.ViewModels;

public sealed class CitationViewModel
{
    public required Citation Citation { get; init; }
    public required string SourceTitle { get; init; }
    public int? PageHint { get; init; }
    // Legacy display field only: absolute path when the live source is a PDF with rawPath.
    // Never authorization to launch — opening always goes through the original resolver.
    public string? PdfFilePath { get; init; }
    public long? NoteIdToOpen { get; init; }     // owning note id when source.type == note
    /// <summary>The citation whose [N] was clicked (highlighted and scrolled to in the Citations panel).</summary>
    public bool IsFocused { get; set; }
    /// <summary>Saved relative path, when it adds something to the title.</summary>
    public string? PathText => Citation.RelPath is { Length: > 0 } rel && rel != SourceTitle ? rel : null;

    public string Marker => $"[{Citation.Marker}]";
    // WP8: the saved snapshot text wins; legacy citations keep their snippet.
    public string Snippet => Citation.Text ?? Citation.Snippet;

    /// <summary>Click-time decision of the last "Open original" attempt (null before any click).</summary>
    public CitationOriginalDecision? OriginalDecision { get; set; }
    /// <summary>Localized status for <see cref="OriginalDecision"/> (changed / unavailable / outside folder).</summary>
    public string? OriginalStatus { get; set; }

    // Mirrors ChatView.showCitation(): resolve source/page/note metadata for the Flyout.
    // Shared by ChatViewModel and NotesChatPanelViewModel. Saved snapshot fields (display
    // name, relative path, span page) precede live metadata, so a deleted or changed
    // original still shows the evidence that was sent.
    public static CitationViewModel Resolve(AINotebook.Core.Storage.NotebookStore store, Citation c)
    {
        var source = store.Source(c.SourceId);
        int? hint = c.Spans.Select(s => s.PageFrom).FirstOrDefault(p => p is not null);
        if (hint is null && source is not null)
            hint = store.Chunks(c.SourceId).FirstOrDefault(ch => ch.Id == c.ChunkId)?.PageHint;
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
            SourceTitle = c.DisplayName ?? c.RelPath ?? source?.Title ?? "",
            PageHint = hint,
            PdfFilePath = pdfPath,
            NoteIdToOpen = noteId
        };
    }
}

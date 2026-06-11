using System.IO.Compression;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

/// <summary>
/// Exports notes and notebooks to portable formats.
/// Never includes API keys or internal file paths (security: FR-B1/B2).
/// </summary>
public static class ExportService
{
    public static string ExportNoteMarkdown(Note note)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"# {note.Title}");
        sb.AppendLine();
        sb.AppendLine(note.BodyMd);
        return sb.ToString();
    }

    public static Stream ExportNotebookZip(long notebookId, NotebookStore store)
    {
        var ms = new MemoryStream();
        using (var archive = new ZipArchive(ms, ZipArchiveMode.Create, leaveOpen: true))
        {
            var notes = store.Notes(notebookId);
            foreach (var note in notes)
            {
                var safeName = SanitizeFilename(note.Title) + ".md";
                var entry = archive.CreateEntry($"notes/{safeName}", CompressionLevel.Fastest);
                using var w = new StreamWriter(entry.Open(), Encoding.UTF8);
                w.Write(ExportNoteMarkdown(note));
            }

            var sources = store.Sources(notebookId);
            var sourceMeta = sources.Select(s => new
            {
                id = s.Id,
                title = s.Title,
                type = s.Type.ToDb(),
                status = s.Status.ToDb(),
                uri = s.Uri,
                ingestedAt = s.IngestedAt.ToString("o")
            }).ToList();
            var metaEntry = archive.CreateEntry("sources.json", CompressionLevel.Fastest);
            using var mw = new StreamWriter(metaEntry.Open(), Encoding.UTF8);
            mw.Write(JsonSerializer.Serialize(sourceMeta, new JsonSerializerOptions { WriteIndented = true }));
        }
        ms.Position = 0;
        return ms;
    }

    private static string SanitizeFilename(string raw)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var sb = new StringBuilder();
        foreach (var c in raw)
            sb.Append(invalid.Contains(c) ? '_' : c);
        var result = sb.ToString().Trim('_', ' ');
        return result.Length == 0 ? "note" : result[..Math.Min(result.Length, 80)];
    }
}

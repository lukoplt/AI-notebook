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
            // Two notes can easily share a title ("Meeting notes"), and they
            // then sanitise to the same filename. Without this de-duplication
            // the archive holds two entries with one name and the extractor
            // keeps whichever it saw last — exporting would lose a note.
            // Mirrors ExportService.swift's usedNames pass.
            var usedNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var note in notes)
            {
                var baseName = SanitizeFilename(note.Title);
                var candidate = baseName;
                for (var n = 2; !usedNames.Add(candidate); n++)
                    candidate = $"{baseName}-{n}";
                var safeName = candidate + ".md";
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
        // Path.GetInvalidFileNameChars() is platform-dependent — on Unix it is
        // just '\0' and '/', so a backslash would survive sanitisation and the
        // resulting zip entry ("notes/..\..\evil.md") would be read as a
        // traversal by any extractor on Windows. Both separators are rejected
        // explicitly so the archive is safe wherever it was written.
        var invalid = Path.GetInvalidFileNameChars().Concat(['/', '\\']).ToHashSet();
        var sb = new StringBuilder();
        foreach (var c in raw)
            sb.Append(invalid.Contains(c) ? '_' : c);
        var result = sb.ToString().Trim('_', ' ');
        return result.Length == 0 ? "note" : result[..Math.Min(result.Length, 80)];
    }
}

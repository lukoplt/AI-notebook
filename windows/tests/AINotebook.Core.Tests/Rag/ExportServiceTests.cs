using System.IO.Compression;
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

/// <summary>
/// FR-B1 note export and FR-B2 notebook ZIP export. Includes the security
/// criterion from cross-cutting requirement 4: an export must never carry API
/// keys or internal filesystem paths out of the app.
/// </summary>
public class ExportServiceTests
{
    private static (NotebookStore store, long notebookId) NewStore()
    {
        var store = new NotebookStore(StorePath.InMemory);
        return (store, store.CreateNotebook("NB").Id!.Value);
    }

    private static ZipArchive OpenZip(Stream s) => new(s, ZipArchiveMode.Read);

    private static string ReadEntry(ZipArchive zip, string name)
    {
        using var reader = new StreamReader(zip.GetEntry(name)!.Open());
        return reader.ReadToEnd();
    }

    [Fact]
    public void NoteMarkdownLeadsWithTheTitleAsAnH1ThenTheBody()
    {
        var note = new Note(1, 1, "My title", "Body **text**.", NoteOrigin.Manual,
            null, null, "uuid", DateTime.UtcNow, DateTime.UtcNow);

        var md = ExportService.ExportNoteMarkdown(note);

        Assert.StartsWith("# My title", md);
        Assert.Contains("Body **text**.", md);
    }

    [Fact]
    public void ZipContainsOneMarkdownFilePerNote()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        store.CreateNote(nb, "First", "one");
        store.CreateNote(nb, "Second", "two");

        using var stream = ExportService.ExportNotebookZip(nb, store);
        using var zip = OpenZip(stream);

        var noteEntries = zip.Entries.Where(e => e.FullName.StartsWith("notes/")).ToList();
        Assert.Equal(2, noteEntries.Count);
        Assert.Contains(noteEntries, e => e.FullName == "notes/First.md");
        Assert.Contains(noteEntries, e => e.FullName == "notes/Second.md");
        Assert.Contains("# First", ReadEntry(zip, "notes/First.md"));
    }

    [Fact]
    public void TitlesThatArePathTraversalAttemptsCannotEscapeTheNotesFolder()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        store.CreateNote(nb, "../../etc/passwd", "body");

        using var stream = ExportService.ExportNotebookZip(nb, store);
        using var zip = OpenZip(stream);

        // A zip-slip entry would let an extractor write outside the target dir.
        // What makes it safe is the absence of separators, not the absence of
        // dots: "notes/.._.._etc_passwd.md" is a single, harmless filename.
        var entry = Assert.Single(zip.Entries, e => e.FullName.StartsWith("notes/"));
        Assert.Equal(1, entry.FullName.Count(c => c == '/'));
        Assert.DoesNotContain('\\', entry.FullName);
    }

    [Fact]
    public void BackslashesInATitleNeverSurviveIntoTheEntryName()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        store.CreateNote(nb, @"..\..\evil", "body");

        using var stream = ExportService.ExportNotebookZip(nb, store);
        using var zip = OpenZip(stream);

        // Path.GetInvalidFileNameChars() is platform-dependent: on Unix it
        // omits '\\', so a backslash title sanitised on macOS would produce an
        // entry that a Windows extractor reads as a directory separator.
        var entry = Assert.Single(zip.Entries, e => e.FullName.StartsWith("notes/"));
        Assert.DoesNotContain('\\', entry.FullName);
    }

    [Fact]
    public void ATitleOfNothingButSeparatorsStillProducesAUsableFilename()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        store.CreateNote(nb, "///", "body");

        using var stream = ExportService.ExportNotebookZip(nb, store);
        using var zip = OpenZip(stream);

        var entry = Assert.Single(zip.Entries, e => e.FullName.StartsWith("notes/"));
        Assert.Equal("notes/note.md", entry.FullName);
    }

    [Fact]
    public void TwoNotesWithTheSameTitleBothSurviveTheExport()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        store.CreateNote(nb, "Meeting notes", "the first one");
        store.CreateNote(nb, "Meeting notes", "the second one");

        using var stream = ExportService.ExportNotebookZip(nb, store);
        using var zip = OpenZip(stream);

        // Same title, same sanitised filename. Without de-duplication the
        // archive carries two entries called notes/Meeting notes.md and the
        // extractor silently keeps one — the user loses a note by exporting.
        var entries = zip.Entries.Where(e => e.FullName.StartsWith("notes/")).ToList();
        Assert.Equal(2, entries.Count);
        Assert.Equal(2, entries.Select(e => e.FullName).Distinct().Count());
    }

    [Fact]
    public void SourcesManifestIsValidJsonDescribingEverySource()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        store.CreateSource(nb, SourceType.Web, "Article", "https://example.com/a", null);
        store.CreateSource(nb, SourceType.Text, "Memo", null, "/Users/someone/private/memo.txt");

        using var stream = ExportService.ExportNotebookZip(nb, store);
        using var zip = OpenZip(stream);

        using var doc = JsonDocument.Parse(ReadEntry(zip, "sources.json"));
        var entries = doc.RootElement.EnumerateArray().ToList();
        Assert.Equal(2, entries.Count);
        Assert.Contains(entries, e => e.GetProperty("title").GetString() == "Article");
        Assert.Contains(entries, e => e.GetProperty("uri").GetString() == "https://example.com/a");
    }

    [Fact]
    public void ExportNeverLeaksInternalFilesystemPaths()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        store.CreateSource(nb, SourceType.Text, "Memo", null, "/Users/someone/private/memo.txt");
        store.CreateNote(nb, "Note", "body");

        using var stream = ExportService.ExportNotebookZip(nb, store);
        using var zip = OpenZip(stream);
        var manifest = ReadEntry(zip, "sources.json");

        // rawPath is where the original file lives on this machine. It is
        // deliberately absent from the manifest (cross-cutting requirement 4);
        // shipping it would disclose the user's home directory layout to
        // anyone they send the export to.
        Assert.DoesNotContain("/Users/someone", manifest);
        Assert.DoesNotContain("rawPath", manifest);
        Assert.DoesNotContain("raw_path", manifest);
    }

    [Fact]
    public void ExportingANotebookOnlyIncludesItsOwnContent()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var mine = store.CreateNotebook("Mine").Id!.Value;
        var theirs = store.CreateNotebook("Theirs").Id!.Value;
        store.CreateNote(mine, "MyNote", "a");
        store.CreateNote(theirs, "TheirNote", "b");
        store.CreateSource(theirs, SourceType.Text, "TheirSource", null, null);

        using var stream = ExportService.ExportNotebookZip(mine, store);
        using var zip = OpenZip(stream);

        Assert.Contains(zip.Entries, e => e.FullName == "notes/MyNote.md");
        Assert.DoesNotContain(zip.Entries, e => e.FullName == "notes/TheirNote.md");
        Assert.DoesNotContain("TheirSource", ReadEntry(zip, "sources.json"));
    }

    [Fact]
    public void AnEmptyNotebookStillExportsAReadableArchive()
    {
        var (store, nb) = NewStore();
        using var _ = store;

        using var stream = ExportService.ExportNotebookZip(nb, store);
        using var zip = OpenZip(stream);

        // Only the manifest, and it parses as an empty array.
        using var doc = JsonDocument.Parse(ReadEntry(zip, "sources.json"));
        Assert.Empty(doc.RootElement.EnumerateArray());
        Assert.DoesNotContain(zip.Entries, e => e.FullName.StartsWith("notes/"));
    }
}

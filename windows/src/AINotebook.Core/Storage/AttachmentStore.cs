using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

/// <summary>
/// Stores attachment bytes on disk under root/&lt;noteUuid&gt;/&lt;filename&gt;
/// and a row in the attachments table. Faithful to AttachmentStore.swift.
/// </summary>
public sealed class AttachmentStore
{
    private readonly NotebookStore _store;
    public string Root { get; }

    public AttachmentStore(NotebookStore store, string root)
    {
        _store = store;
        Root = root;
        Directory.CreateDirectory(root);
    }

    /// <summary>%APPDATA%\AINotebook\attachments, created on demand.</summary>
    public static string DefaultRoot()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var dir = Path.Combine(appData, "AINotebook", "attachments");
        Directory.CreateDirectory(dir);
        return dir;
    }

    public NoteAttachment Save(long noteId, string noteUuid, string filename, string mime, byte[] bytes)
    {
        var folder = Path.Combine(Root, noteUuid);
        Directory.CreateDirectory(folder);
        var resolved = UniqueFilename(folder, filename);
        File.WriteAllBytes(Path.Combine(folder, resolved), bytes);

        var now = DateTime.UtcNow;
        var id = _store.Connection.ExecuteScalar<long>(
            """
            INSERT INTO attachments(note_id, note_uuid, filename, mime, byte_size, created_at)
            VALUES($nid, $uuid, $file, $mime, $size, $created);
            SELECT last_insert_rowid();
            """,
            new { nid = noteId, uuid = noteUuid, file = resolved, mime, size = (long)bytes.Length, created = SqliteDate.ToDb(now) });
        return new NoteAttachment(id, noteId, noteUuid, resolved, mime, bytes.Length, now);
    }

    public byte[] Read(string noteUuid, string filename) =>
        File.ReadAllBytes(Path.Combine(Root, noteUuid, filename));

    public IReadOnlyList<NoteAttachment> List(long noteId) =>
        _store.Connection.Query(
            "SELECT id, note_id, note_uuid, filename, mime, byte_size, created_at FROM attachments WHERE note_id=$nid ORDER BY created_at ASC",
            new { nid = noteId })
            .Select(r => new NoteAttachment(
                (long)r.id, (long)r.note_id, (string)r.note_uuid, (string)r.filename,
                (string)r.mime, (long)r.byte_size, SqliteDate.FromDb((string)r.created_at)))
            .ToList();

    public void DeleteFolder(string noteUuid)
    {
        var folder = Path.Combine(Root, noteUuid);
        if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
    }

    private static string UniqueFilename(string folder, string requested)
    {
        var stem = Path.GetFileNameWithoutExtension(requested);
        var ext = Path.GetExtension(requested); // includes leading '.' or "" if none
        var candidate = requested;
        var n = 2;
        while (File.Exists(Path.Combine(folder, candidate)))
        {
            candidate = $"{stem} ({n}){ext}";
            n++;
            if (n > 9999) break;
        }
        return candidate;
    }
}

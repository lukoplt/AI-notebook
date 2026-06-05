using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    private const string NoteCols =
        "id, notebook_id, title, body_md, origin, origin_ref, auto_source_id, note_uuid, created_at, updated_at";

    private static Note MapNote(dynamic r) => new Note(
        (long)r.id, (long)r.notebook_id, (string)r.title, (string)r.body_md,
        NoteOriginExtensions.FromDb((string)r.origin),
        r.origin_ref is null ? (long?)null : (long)r.origin_ref,
        r.auto_source_id is null ? (long?)null : (long)r.auto_source_id,
        (string)r.note_uuid,
        SqliteDate.FromDb((string)r.created_at), SqliteDate.FromDb((string)r.updated_at));

    public Note CreateNote(long notebookId, string title, string bodyMd,
        NoteOrigin origin = NoteOrigin.Manual, long? originRef = null)
    {
        var now = Now();
        var uuid = Guid.NewGuid().ToString().ToLowerInvariant();
        var trimmed = title.Trim();
        var id = Connection.ExecuteScalar<long>(
            """
            INSERT INTO notes(notebook_id, title, body_md, origin, origin_ref, note_uuid, created_at, updated_at)
            VALUES($nb, $title, $body, $origin, $ref, $uuid, $created, $updated);
            SELECT last_insert_rowid();
            """,
            new
            {
                nb = notebookId, title = trimmed, body = bodyMd, origin = origin.ToDb(),
                @ref = originRef, uuid, created = SqliteDate.ToDb(now), updated = SqliteDate.ToDb(now)
            });
        FireNoteSaved(id);
        return new Note(id, notebookId, trimmed, bodyMd, origin, originRef, null, uuid, now, now);
    }

    public IReadOnlyList<Note> Notes(long notebookId) =>
        Connection.Query(
            $"SELECT {NoteCols} FROM notes WHERE notebook_id=$nb ORDER BY updated_at DESC",
            new { nb = notebookId })
            .Select(r => (Note)MapNote(r)).ToList();

    public Note? Note(long id)
    {
        var row = Connection.QueryFirstOrDefault($"SELECT {NoteCols} FROM notes WHERE id=$id", new { id });
        return row is null ? null : MapNote(row);
    }

    public void UpdateNote(long id, string title, string bodyMd)
    {
        // Snapshot the PRE-update content as an autosave version FIRST.
        SnapshotNoteVersion(id, NoteVersionReason.Autosave);
        Connection.Execute(
            "UPDATE notes SET title=$title, body_md=$body, updated_at=$updated WHERE id=$id",
            new { title = title.Trim(), body = bodyMd, updated = SqliteDate.ToDb(Now()), id });
        FireNoteSaved(id);
    }

    public string? DeleteNote(long id)
    {
        var uuid = Connection.QueryFirstOrDefault<string?>(
            "SELECT note_uuid FROM notes WHERE id=$id", new { id });
        Connection.Execute("DELETE FROM notes WHERE id=$id", new { id });
        if (uuid is not null && OnNoteDeleted is not null)
            _ = OnNoteDeleted(uuid);
        return uuid;
    }

    public void LinkNoteToShadowSource(long noteId, long sourceId) =>
        Connection.Execute("UPDATE notes SET auto_source_id=$src WHERE id=$id",
            new { src = sourceId, id = noteId });

    private void FireNoteSaved(long noteId)
    {
        if (OnNoteSaved is not null) _ = OnNoteSaved(noteId);
    }
}

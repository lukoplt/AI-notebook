using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    public const int NoteVersionCap = 50;

    public IReadOnlyList<NoteVersion> NoteVersions(long noteId) =>
        Connection.Query(
            "SELECT id, note_id, title, body_md, saved_at, reason FROM note_versions WHERE note_id=$nid ORDER BY saved_at ASC",
            new { nid = noteId })
            .Select(r => new NoteVersion(
                (long)r.id, (long)r.note_id, (string)r.title, (string)r.body_md,
                SqliteDate.FromDb((string)r.saved_at),
                NoteVersionReasonExtensions.FromDb((string)r.reason)))
            .ToList();

    public NoteVersion? SnapshotNoteVersion(long noteId, NoteVersionReason reason)
    {
        var note = Note(noteId);
        if (note is null) return null;
        var savedAt = DateTime.UtcNow;
        var id = Connection.ExecuteScalar<long>(
            """
            INSERT INTO note_versions(note_id, title, body_md, saved_at, reason)
            VALUES($nid, $title, $body, $saved, $reason);
            SELECT last_insert_rowid();
            """,
            new { nid = noteId, title = note.Title, body = note.BodyMd, saved = SqliteDate.ToDb(savedAt), reason = reason.ToDb() });
        PruneIfNeeded(noteId);
        return new NoteVersion(id, noteId, note.Title, note.BodyMd, savedAt, reason);
    }

    public void RestoreNoteVersion(long versionId)
    {
        var row = Connection.QueryFirstOrDefault(
            "SELECT note_id, title, body_md FROM note_versions WHERE id=$id", new { id = versionId });
        if (row is null) return;
        long noteId = (long)row.note_id;
        var current = Note(noteId);
        if (current is not null)
        {
            Connection.Execute(
                """
                INSERT INTO note_versions(note_id, title, body_md, saved_at, reason)
                VALUES($nid, $title, $body, $saved, $reason)
                """,
                new
                {
                    nid = noteId, title = current.Title, body = current.BodyMd,
                    saved = SqliteDate.ToDb(DateTime.UtcNow), reason = NoteVersionReason.Restore.ToDb()
                });
            PruneIfNeeded(noteId);
        }
        Connection.Execute(
            "UPDATE notes SET title=$title, body_md=$body, updated_at=$updated WHERE id=$id",
            new { title = (string)row.title, body = (string)row.body_md, updated = SqliteDate.ToDb(DateTime.UtcNow), id = noteId });
        FireNoteSaved(noteId);
    }

    private void PruneIfNeeded(long noteId)
    {
        var total = Connection.ExecuteScalar<int>(
            "SELECT count(*) FROM note_versions WHERE note_id=$nid", new { nid = noteId });
        if (total > NoteVersionCap)
        {
            Connection.Execute(
                """
                DELETE FROM note_versions
                WHERE id IN (
                  SELECT id FROM note_versions
                  WHERE note_id=$nid
                  ORDER BY saved_at ASC
                  LIMIT $limit
                )
                """,
                new { nid = noteId, limit = total - NoteVersionCap });
        }
    }
}

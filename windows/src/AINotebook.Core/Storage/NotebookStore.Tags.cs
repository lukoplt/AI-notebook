using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    public IReadOnlyList<Tag> Tags() =>
        Connection.Query("SELECT id, name FROM tags ORDER BY name ASC")
            .Select(r => new Tag((long)r.id, (string)r.name))
            .ToList();

    public Tag CreateTag(string name)
    {
        var trimmed = name.Trim();
        var id = Connection.ExecuteScalar<long>(
            """
            INSERT INTO tags(name) VALUES($name)
            ON CONFLICT(name) DO UPDATE SET name=excluded.name;
            SELECT id FROM tags WHERE name=$name;
            """,
            new { name = trimmed });
        return new Tag(id, trimmed);
    }

    public void DeleteTag(long id) =>
        Connection.Execute("DELETE FROM tags WHERE id=$id", new { id });

    public void SetNoteTags(long noteId, IReadOnlyList<long> tagIds)
    {
        using var tx = Connection.BeginTransaction();
        Connection.Execute("DELETE FROM note_tags WHERE note_id=$nid", new { nid = noteId }, tx);
        foreach (var tid in tagIds)
            Connection.Execute(
                "INSERT OR IGNORE INTO note_tags(note_id, tag_id) VALUES($nid, $tid)",
                new { nid = noteId, tid }, tx);
        tx.Commit();
    }

    public void SetSourceTags(long sourceId, IReadOnlyList<long> tagIds)
    {
        using var tx = Connection.BeginTransaction();
        Connection.Execute("DELETE FROM source_tags WHERE source_id=$sid", new { sid = sourceId }, tx);
        foreach (var tid in tagIds)
            Connection.Execute(
                "INSERT OR IGNORE INTO source_tags(source_id, tag_id) VALUES($sid, $tid)",
                new { sid = sourceId, tid }, tx);
        tx.Commit();
    }

    public IReadOnlyList<long> NoteTagIds(long noteId) =>
        Connection.Query<long>(
            "SELECT tag_id FROM note_tags WHERE note_id=$nid", new { nid = noteId })
            .ToList();

    public IReadOnlyList<long> SourceTagIds(long sourceId) =>
        Connection.Query<long>(
            "SELECT tag_id FROM source_tags WHERE source_id=$sid", new { sid = sourceId })
            .ToList();

    public IReadOnlyList<Tag> TagsForNote(long noteId) =>
        Connection.Query(
            "SELECT t.id, t.name FROM tags t JOIN note_tags nt ON nt.tag_id=t.id WHERE nt.note_id=$nid ORDER BY t.name",
            new { nid = noteId })
            .Select(r => new Tag((long)r.id, (string)r.name))
            .ToList();

    public IReadOnlyList<Tag> TagsForSource(long sourceId) =>
        Connection.Query(
            "SELECT t.id, t.name FROM tags t JOIN source_tags st ON st.tag_id=t.id WHERE st.source_id=$sid ORDER BY t.name",
            new { sid = sourceId })
            .Select(r => new Tag((long)r.id, (string)r.name))
            .ToList();
}

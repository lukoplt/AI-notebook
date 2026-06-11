using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    public IReadOnlyList<SourceSet> SourceSets(long notebookId) =>
        Connection.Query(
            "SELECT id, notebook_id, name, created_at FROM source_sets WHERE notebook_id=$nb ORDER BY name ASC",
            new { nb = notebookId })
            .Select(r => new SourceSet((long)r.id, (long)r.notebook_id, (string)r.name,
                SqliteDate.FromDb((string)r.created_at)))
            .ToList();

    public SourceSet CreateSourceSet(long notebookId, string name)
    {
        var trimmed = name.Trim();
        var now = Now();
        var id = Connection.ExecuteScalar<long>(
            """
            INSERT INTO source_sets(notebook_id, name, created_at)
            VALUES($nb, $name, $created);
            SELECT last_insert_rowid();
            """,
            new { nb = notebookId, name = trimmed, created = SqliteDate.ToDb(now) });
        return new SourceSet(id, notebookId, trimmed, now);
    }

    public void RenameSourceSet(long id, string name) =>
        Connection.Execute(
            "UPDATE source_sets SET name=$name WHERE id=$id",
            new { name = name.Trim(), id });

    public void DeleteSourceSet(long id) =>
        Connection.Execute("DELETE FROM source_sets WHERE id=$id", new { id });

    public void SetSourceSetMembers(long setId, IReadOnlyList<long> sourceIds)
    {
        using var tx = Connection.BeginTransaction();
        Connection.Execute("DELETE FROM source_set_members WHERE set_id=$sid", new { sid = setId }, tx);
        foreach (var srcId in sourceIds)
            Connection.Execute(
                "INSERT OR IGNORE INTO source_set_members(set_id, source_id) VALUES($sid, $src)",
                new { sid = setId, src = srcId }, tx);
        tx.Commit();
    }

    public IReadOnlyList<long> SourceSetMembers(long setId) =>
        Connection.Query<long>(
            "SELECT source_id FROM source_set_members WHERE set_id=$sid", new { sid = setId })
            .ToList();
}

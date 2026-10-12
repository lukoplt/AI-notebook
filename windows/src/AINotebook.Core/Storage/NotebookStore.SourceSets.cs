using AINotebook.Core.Models;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    public IReadOnlyList<SourceSet> SourceSets(long notebookId)
    {
        lock (_gate)
            return Connection.Query(
                "SELECT id, notebook_id, name, created_at FROM source_sets WHERE notebook_id=$nb ORDER BY name ASC",
                new { nb = notebookId })
                .Select(r => new SourceSet((long)r.id, (long)r.notebook_id, (string)r.name,
                    SqliteDate.FromDb((string)r.created_at)))
                .ToList();
    }

    public SourceSet CreateSourceSet(long notebookId, string name)
    {
        lock (_gate)
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
    }

    public void RenameSourceSet(long id, string name)
    {
        lock (_gate)
            Connection.Execute(
                "UPDATE source_sets SET name=$name WHERE id=$id",
                new { name = name.Trim(), id });
    }

    public void DeleteSourceSet(long id)
    {
        lock (_gate)
            Connection.Execute("DELETE FROM source_sets WHERE id=$id", new { id });
    }

    public void SetSourceSetMembers(long setId, IReadOnlyList<long> sourceIds)
    {
        lock (_gate)
        {
            using var tx = Connection.BeginTransaction();
            long notebook = RequireSourceSetNotebook(setId, tx);
            foreach (long sourceId in sourceIds.Distinct())
            {
                long? sourceNotebook = Connection.QuerySingleOrDefault<long?>(
                    "SELECT notebook_id FROM sources WHERE id=$sourceId", new { sourceId }, tx);
                if (sourceNotebook is null) throw new StorageV19Exception("notFound");
                if (sourceNotebook != notebook) throw new StorageV19Exception("notebookMismatch");
            }
            Connection.Execute("DELETE FROM source_set_members WHERE set_id=$sid", new { sid = setId }, tx);
            foreach (var srcId in sourceIds)
                Connection.Execute(
                    "INSERT OR IGNORE INTO source_set_members(set_id, source_id) VALUES($sid, $src)",
                    new { sid = setId, src = srcId }, tx);
            tx.Commit();
        }
    }

    public IReadOnlyList<long> SourceSetMembers(long setId)
    {
        lock (_gate)
            return Connection.Query<long>(
                "SELECT source_id FROM source_set_members WHERE set_id=$sid", new { sid = setId })
                .ToList();
    }

    public void SetSourceSetFolders(long setId, IReadOnlyList<long> folderIds)
    {
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction();
            long notebook = RequireSourceSetNotebook(setId, transaction);
            foreach (long folderId in folderIds.Distinct())
                if (RequireFolderNotebook(folderId, transaction) != notebook)
                    throw new StorageV19Exception("notebookMismatch");
            _conn.Execute("DELETE FROM source_set_folders WHERE set_id=$setId", new { setId }, transaction);
            foreach (long folderId in folderIds.Distinct())
                _conn.Execute("INSERT INTO source_set_folders(set_id,folder_id) VALUES($setId,$folderId)",
                    new { setId, folderId }, transaction);
            transaction.Commit();
        }
    }

    public IReadOnlyList<long> SourceSetFolders(long setId)
    {
        lock (_gate)
        {
            RequireSourceSetNotebook(setId);
            return _conn.Query<long>("SELECT folder_id FROM source_set_folders WHERE set_id=$setId ORDER BY folder_id",
                new { setId }).ToArray();
        }
    }

    private long RequireSourceSetNotebook(long setId, SqliteTransaction? transaction = null)
        => _conn.QuerySingleOrDefault<long?>("SELECT notebook_id FROM source_sets WHERE id=$setId", new { setId }, transaction)
            ?? throw new StorageV19Exception("notFound");
}

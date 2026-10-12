using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    /// <summary>
    /// Resolves a selection against current rows in one read transaction. IDs owned by another notebook throw
    /// <c>notebookMismatch</c>; deleted IDs are dropped (a removed selected folder leaves an empty selection, never
    /// <see cref="RetrievalScope.All"/>). Selected sets contribute their current source and folder IDs; folder IDs stay
    /// unexpanded for live per-turn membership.
    /// </summary>
    public RetrievalScope ResolveFolderScope(long notebookId, FolderScopeSelection selection)
    {
        ArgumentNullException.ThrowIfNull(selection);
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: true);
            var scope = ResolveFolderScope(tx, notebookId, selection);
            tx.Commit();
            return scope;
        }
    }

    /// <summary>
    /// Persists an explicit selection (sources and folders, named sets resolved first) as one source set in one write.
    /// Whole-notebook scopes are rejected rather than materialized into a misleading permanent set.
    /// </summary>
    public SourceSet SaveFolderScopeSet(long notebookId, string name, FolderScopeSelection selection)
    {
        ArgumentNullException.ThrowIfNull(selection);
        if (selection.WholeNotebook) throw new StorageV19Exception("invalidValue");
        string trimmed = (name ?? "").Trim();
        if (trimmed.Length == 0) throw new StorageV19Exception("invalidValue");
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            if (ResolveFolderScope(tx, notebookId, selection) is not RetrievalScope.Selection resolved)
                throw new StorageV19Exception("invalidValue");
            var now = DateTime.UtcNow;
            long id = _conn.ExecuteScalar<long>("""
                INSERT INTO source_sets(notebook_id,name,created_at) VALUES($notebookId,$name,$created);
                SELECT last_insert_rowid();
                """, new { notebookId, name = trimmed, created = SqliteDate.ToDb(now) }, tx);
            foreach (long source in resolved.SourceIds.Order())
                _conn.Execute("INSERT OR IGNORE INTO source_set_members(set_id,source_id) VALUES($id,$source)", new { id, source }, tx);
            foreach (long folder in resolved.FolderIds.Order())
                _conn.Execute("INSERT INTO source_set_folders(set_id,folder_id) VALUES($id,$folder)", new { id, folder }, tx);
            tx.Commit();
            return new SourceSet(id, notebookId, trimmed, now);
        }
    }

    private RetrievalScope ResolveFolderScope(SqliteTransaction tx, long notebookId, FolderScopeSelection selection)
    {
        RequireNotebookV19(notebookId, tx);
        if (selection.WholeNotebook) return new RetrievalScope.All();
        HashSet<long> Owned(string table, IEnumerable<long> ids)
        {
            var kept = new HashSet<long>();
            // `table` comes only from the fixed literals below.
            foreach (long id in ids.Order())
            {
                long? owner = _conn.QuerySingleOrDefault<long?>($"SELECT notebook_id FROM {table} WHERE id=$id", new { id }, tx);
                if (owner is null) continue;
                if (owner != notebookId) throw new StorageV19Exception("notebookMismatch");
                kept.Add(id);
            }
            return kept;
        }
        var sources = Owned("sources", selection.SourceIds);
        var folders = Owned("folder_sources", selection.FolderIds);
        var setScopes = new Dictionary<long, RetrievalScope>();
        foreach (long set in Owned("source_sets", selection.SetIds))
            setScopes[set] = new RetrievalScope.Selection(
                _conn.Query<long>("SELECT source_id FROM source_set_members WHERE set_id=$set", new { set }, tx).ToHashSet(),
                _conn.Query<long>("SELECT folder_id FROM source_set_folders WHERE set_id=$set", new { set }, tx).ToHashSet());
        return new FolderScopeSelection(false, sources, folders, setScopes.Keys.ToHashSet()).Resolved(setScopes);
    }
}

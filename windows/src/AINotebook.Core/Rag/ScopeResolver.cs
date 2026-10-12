using System.Text.Json;
using AINotebook.Core.Storage;
using Dapper;

namespace AINotebook.Core.Rag;

public static class ScopeResolver
{
    public static ResolvedRetrievalScope? Resolve(NotebookStore store, long notebookId,
        RetrievalScope scope, string modelKey)
    {
        if (scope.IsEmptySelection) return null;
        var (pin, value) = store.WithQueryPin(notebookId, modelKey, (connection, transaction, captured) =>
        {
            const string sql = """
                SELECT s.id,s.folder_id,s.rel_path,s.title,s.published_revision_id,s.mtime/1000000000 AS mtime_s
                FROM sources s
                WHERE s.notebook_id=$nb AND s.availability='present' AND s.eligible=1
                  AND ($all=1 OR s.id IN (SELECT CAST(value AS INTEGER) FROM json_each($sourceIds))
                    OR s.folder_id IN (SELECT CAST(value AS INTEGER) FROM json_each($folderIds)))
                ORDER BY s.id
                """;
            store.RetrievalStatementExecuted?.Invoke(sql);
            var sources = connection.Query(sql, new
            {
                nb = notebookId, all = scope is RetrievalScope.All ? 1 : 0,
                sourceIds = JsonSerializer.Serialize(scope is RetrievalScope.Selection s ? s.SourceIds.Order().ToArray() : Array.Empty<long>()),
                folderIds = JsonSerializer.Serialize(scope is RetrievalScope.Selection f ? f.FolderIds.Order().ToArray() : Array.Empty<long>())
            }, transaction).Select(row => new ScopedSource((long)row.id, (long?)row.folder_id,
                (string?)row.rel_path, (string)row.title, (long?)row.published_revision_id,
                captured.VectorRevisions.TryGetValue((long)row.id, out long revision) ? revision : (long?)null,
                (long?)row.mtime_s)).ToArray();
            var generation = captured.GenerationId is long id ? GenerationSQL.Read(connection, transaction, id) : null;
            // Capture the epoch with the same SQL snapshot; a later change prevents admission.
            // A building (partial) pin streams: every build write bumps the epoch, so an
            // admitted matrix would be stale at once (retrieval-partial-index-v1 §3).
            var key = generation is null ? null : new RetrievalCacheKey(store.RetrievalDatabaseId,
                notebookId, generation.Id, store.RefreshRetrievalEpoch(transaction));
            if (generation?.State == "building") key = null;
            return (sources, generation, key);
        });
        try { return new(store, pin, scope, value.sources, value.generation, value.key); }
        catch { store.ReleaseQuery(pin); throw; }
    }
}

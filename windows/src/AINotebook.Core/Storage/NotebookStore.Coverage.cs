using AINotebook.Core.Rag;
using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    public CoverageSnapshot Coverage(long notebookId, RetrievalScope scope)
    {
        // Empty selection must never expand to a notebook query.
        if (scope.IsEmptySelection) return new(0, 0, 0, 0, 0, 0, 0, 0, false, 0, 0);
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: true);
            RequireNotebookV19(notebookId, tx);
            var args = new DynamicParameters(new { nb = notebookId, allScope = scope is RetrievalScope.All ? 1 : 0 });
            string BindIds(IEnumerable<long> ids, string prefix)
            {
                var names = ids.Select((id, i) =>
                {
                    string name = prefix + i;
                    args.Add(name, id);
                    return "$" + name;
                }).ToArray();
                return names.Length == 0 ? "NULL" : string.Join(",", names);
            }
            var selected = scope as RetrievalScope.Selection;
            string sourceIds = BindIds(selected?.SourceIds ?? new HashSet<long>(), "source");
            string folderIds = BindIds(selected?.FolderIds ?? new HashSet<long>(), "folder");
            var row = _conn.QuerySingle($"""
                WITH entities(availability,eligible,published,current,status,refresh) AS (
                  SELECT s.availability,
                         s.eligible=1 AND coalesce(i.kind,'eligible')<>'skipped',
                         s.published_revision_id,s.current_revision,s.status,
                         s.status IN ('pending','chunking') OR EXISTS(
                           SELECT 1 FROM ingest_jobs j WHERE j.kind='extract'
                             AND j.target='source:'||s.id AND j.target_revision IS s.current_revision
                             AND j.state IN ('queued','running','paused'))
                  FROM sources s LEFT JOIN scan_items i ON i.folder_id=s.folder_id AND i.rel_path=s.rel_path
                  WHERE s.notebook_id=$nb AND ($allScope=1 OR s.id IN ({sourceIds}) OR s.folder_id IN ({folderIds}))
                  UNION ALL
                  SELECT 'present',i.kind='eligible',NULL,NULL,'pending',1
                  FROM scan_items i JOIN folder_sources f ON f.id=i.folder_id
                  WHERE f.notebook_id=$nb AND ($allScope=1 OR f.id IN ({folderIds}))
                    AND NOT EXISTS(SELECT 1 FROM sources s WHERE s.folder_id=i.folder_id AND s.rel_path=i.rel_path)
                )
                SELECT
                  coalesce(sum(availability='present' AND eligible=1 AND published IS NOT NULL),0) AS searchable,
                  coalesce(sum(availability='present' AND eligible=1 AND published IS NULL),0) AS notSearchable,
                  coalesce(sum(availability='present' AND eligible=1 AND published IS NULL AND status<>'error'),0) AS pending,
                  coalesce(sum(availability='present' AND eligible=1 AND published IS NULL AND status='error'),0) AS error,
                  coalesce(sum(availability='present' AND eligible=0),0) AS skipped,
                  coalesce(sum(availability='missing'),0) AS missing,
                  coalesce(sum(availability='unavailable'),0) AS unavailable,
                  coalesce(sum(availability='present' AND eligible=1 AND status<>'error'
                    AND (published IS NULL OR current IS NOT published OR refresh)),0) AS refreshPending,
                  coalesce(sum(availability='present' AND eligible=1 AND status='error'),0) AS refreshError,
                  coalesce(sum(availability='present' AND eligible=1 AND status<>'error'
                    AND published IS NOT NULL AND current IS published AND NOT refresh),0) AS current
                FROM entities
                """, args, tx);
            bool lowerBound = _conn.ExecuteScalar<bool>($"""
                SELECT EXISTS(SELECT 1 FROM folder_sources f
                  WHERE f.notebook_id=$nb AND f.scan_state='partial'
                    AND ($allScope=1 OR f.id IN ({folderIds}) OR EXISTS(
                      SELECT 1 FROM sources s WHERE s.folder_id=f.id AND s.notebook_id=$nb AND s.id IN ({sourceIds}))))
                """, args, tx);
            var result = new CoverageSnapshot((int)row.searchable, (int)row.pending, (int)row.error,
                (int)row.skipped, (int)row.missing, (int)row.unavailable, (int)row.refreshPending,
                (int)row.refreshError, lowerBound, (int)row.notSearchable, (int)row.current);
            tx.Commit();
            return result;
        }
    }
}

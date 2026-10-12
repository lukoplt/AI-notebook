import GRDB

extension NotebookStore {
    /// Counts inventory, searchable evidence and refresh state from one database snapshot.
    public func coverage(notebookId: Int64, scope: RetrievalScope) throws -> CoverageSnapshot {
        try dbQueue.read { try Self.coverage($0, notebookId: notebookId, scope: scope) }
    }

    /// `coverage(notebookId:scope:)` inside the caller's read transaction.
    nonisolated static func coverage(_ db: Database, notebookId: Int64, scope: RetrievalScope) throws -> CoverageSnapshot {
        if scope.isEmptySelection {
            return CoverageSnapshot(searchable: 0, pending: 0, error: 0, skipped: 0,
                                    missing: 0, unavailable: 0, refreshPending: 0,
                                    refreshError: 0, isLowerBound: false,
                                    notSearchable: 0, current: 0)
        }

        let includeAll: Bool
        let sourceIds: [Int64]
        let folderIds: [Int64]
        switch scope {
        case .all:
            includeAll = true
            sourceIds = []
            folderIds = []
        case let .selection(sources, folders):
            includeAll = false
            sourceIds = sources.sorted()
            folderIds = folders.sorted()
        }

        // Only placeholder syntax is interpolated. Scope identifiers are bound values.
        func selectedRows(_ ids: [Int64]) -> String {
            ids.isEmpty ? "SELECT NULL WHERE 0" : "VALUES " + ids.map { _ in "(?)" }.joined(separator: ",")
        }
        var arguments = StatementArguments(sourceIds)
        arguments += StatementArguments(folderIds)
        arguments += [notebookId, includeAll]

        do {
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM notebooks WHERE id=?)",
                                    arguments: [notebookId]) == true else {
                throw StorageV19Error.notFound
            }
            let row = try Row.fetchOne(db, sql: """
                WITH selected_sources(id) AS (\(selectedRows(sourceIds))),
                selected_folders(id) AS (\(selectedRows(folderIds))),
                scope(notebook_id,include_all) AS (VALUES (?,?)),
                scoped_sources AS (
                    SELECT s.*
                    FROM sources s, scope
                    WHERE s.notebook_id=scope.notebook_id
                      AND (scope.include_all OR s.id IN (SELECT id FROM selected_sources)
                           OR s.folder_id IN (SELECT id FROM selected_folders))
                ),
                included_folders AS (
                    SELECT f.id,f.scan_state
                    FROM folder_sources f, scope
                    WHERE f.notebook_id=scope.notebook_id
                      AND (scope.include_all OR f.id IN (SELECT id FROM selected_folders)
                           OR EXISTS(SELECT 1 FROM scoped_sources s WHERE s.folder_id=f.id))
                ),
                entities(availability,eligible,published,current_revision,status) AS (
                    SELECT s.availability,
                           s.eligible AND coalesce(i.kind<>'skipped',1),
                           s.published_revision_id,s.current_revision,s.status
                    FROM scoped_sources s
                    LEFT JOIN scan_items i ON i.folder_id=s.folder_id AND i.rel_path=s.rel_path
                    UNION ALL
                    SELECT 'present',i.kind='eligible',NULL,NULL,'pending'
                    FROM scan_items i
                    JOIN folder_sources f ON f.id=i.folder_id, scope
                    WHERE f.notebook_id=scope.notebook_id
                      AND (scope.include_all OR f.id IN (SELECT id FROM selected_folders))
                      AND NOT EXISTS(SELECT 1 FROM sources s
                                     WHERE s.folder_id=i.folder_id AND s.rel_path=i.rel_path)
                ),
                classified AS (
                    SELECT *, availability='present' AND eligible=1 AS in_corpus,
                           published IS NULL OR current_revision IS NOT published
                             OR status IN ('pending','chunking') AS refresh_pending
                    FROM entities
                )
                SELECT
                    coalesce(sum(in_corpus AND published IS NOT NULL),0) AS searchable,
                    coalesce(sum(in_corpus AND published IS NULL),0) AS not_searchable,
                    coalesce(sum(in_corpus AND published IS NULL AND status<>'error'),0) AS pending,
                    coalesce(sum(in_corpus AND published IS NULL AND status='error'),0) AS error,
                    coalesce(sum(availability='present' AND eligible=0),0) AS skipped,
                    coalesce(sum(availability='missing'),0) AS missing,
                    coalesce(sum(availability='unavailable'),0) AS unavailable,
                    coalesce(sum(in_corpus AND status<>'error' AND refresh_pending),0) AS refresh_pending,
                    coalesce(sum(in_corpus AND status='error'),0) AS refresh_error,
                    coalesce(sum(in_corpus AND status<>'error' AND NOT refresh_pending),0) AS current,
                    EXISTS(SELECT 1 FROM included_folders WHERE scan_state='partial') AS is_lower_bound
                FROM classified
                """, arguments: arguments)!
            return CoverageSnapshot(searchable: row["searchable"], pending: row["pending"],
                                    error: row["error"], skipped: row["skipped"],
                                    missing: row["missing"], unavailable: row["unavailable"],
                                    refreshPending: row["refresh_pending"], refreshError: row["refresh_error"],
                                    isLowerBound: row["is_lower_bound"],
                                    notSearchable: row["not_searchable"], current: row["current"])
        }
    }
}

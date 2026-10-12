import Foundation
import GRDB

extension NotebookStore {
    /// Resolves a selection against current rows in one read transaction.
    /// IDs owned by another notebook throw `notebookMismatch`; deleted IDs are
    /// dropped (a removed selected folder leaves an empty selection, never
    /// `.all`). Selected sets contribute their current source and folder IDs.
    public func resolveFolderScope(notebookId: Int64, selection: FolderScopeSelection) throws -> RetrievalScope {
        try dbQueue.read { db in try FolderScopeSQL.resolve(db, notebookId: notebookId, selection: selection) }
    }

    /// Persists an explicit selection (sources and folders, with named sets
    /// resolved first) as one source set in one write. Whole-notebook scopes
    /// are rejected rather than materialized into a misleading permanent set.
    public func saveFolderScopeSet(notebookId: Int64, name: String, selection: FolderScopeSelection) throws -> SourceSet {
        guard !selection.wholeNotebook else { throw StorageV19Error.invalidValue }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidSourceSetName(name) }
        let now = Date()
        return try dbQueue.write { db in
            guard case let .selection(sourceIds, folderIds) = try FolderScopeSQL.resolve(db, notebookId: notebookId, selection: selection) else {
                throw StorageV19Error.invalidValue
            }
            try db.execute(sql: "INSERT INTO source_sets(notebook_id,name,created_at) VALUES(?,?,?)", arguments: [notebookId, trimmed, now])
            let id = db.lastInsertedRowID
            for source in sourceIds.sorted() {
                try db.execute(sql: "INSERT OR IGNORE INTO source_set_members(set_id,source_id) VALUES(?,?)", arguments: [id, source])
            }
            for folder in folderIds.sorted() {
                try db.execute(sql: "INSERT INTO source_set_folders(set_id,folder_id) VALUES(?,?)", arguments: [id, folder])
            }
            return SourceSet(id: id, notebookId: notebookId, name: trimmed, createdAt: now)
        }
    }
}

enum FolderScopeSQL {
    static func resolve(_ db: Database, notebookId: Int64, selection: FolderScopeSelection) throws -> RetrievalScope {
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM notebooks WHERE id=?", arguments: [notebookId]) != nil else {
            throw StorageV19Error.notFound
        }
        if selection.wholeNotebook { return .all }
        func owned(_ table: String, _ ids: Set<Int64>) throws -> Set<Int64> {
            var kept = Set<Int64>()
            // `table` comes only from the fixed literals below.
            for id in ids.sorted() {
                guard let owner = try Int64.fetchOne(db, sql: "SELECT notebook_id FROM \(table) WHERE id=?", arguments: [id]) else { continue }
                guard owner == notebookId else { throw StorageV19Error.notebookMismatch }
                kept.insert(id)
            }
            return kept
        }
        let sources = try owned("sources", selection.sourceIds)
        let folders = try owned("folder_sources", selection.folderIds)
        var setScopes: [Int64: RetrievalScope] = [:]
        for set in try owned("source_sets", selection.setIds) {
            setScopes[set] = .selection(
                sourceIds: Set(try Int64.fetchAll(db, sql: "SELECT source_id FROM source_set_members WHERE set_id=?", arguments: [set])),
                folderIds: Set(try Int64.fetchAll(db, sql: "SELECT folder_id FROM source_set_folders WHERE set_id=?", arguments: [set])))
        }
        return FolderScopeSelection(wholeNotebook: false, sourceIds: sources, folderIds: folders, setIds: Set(setScopes.keys))
            .resolved(setScopes: setScopes)
    }
}

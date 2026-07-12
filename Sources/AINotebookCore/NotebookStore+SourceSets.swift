import Foundation
import GRDB

/// Named source sets (Epic C, FR-C2) and per-notebook instructions (FR-C1).
/// Ported from the Windows `NotebookStore.SourceSets` partial plus the
/// instructions accessor.
extension NotebookStore {

    // MARK: Per-notebook instructions (FR-C1)

    public func notebookInstructions(id: Int64) throws -> String {
        try runOnDatabase { db in
            try String.fetchOne(db, sql: "SELECT instructions FROM notebooks WHERE id=?", arguments: [id]) ?? ""
        }
    }

    public func updateNotebookInstructions(id: Int64, instructions: String) throws {
        try runOnDatabase { db in
            try db.execute(
                sql: "UPDATE notebooks SET instructions=?, updated_at=? WHERE id=?",
                arguments: [instructions, Date(), id]
            )
        }
        try refresh()
    }

    // MARK: Source sets (FR-C2)

    public func sourceSets(notebookId: Int64) throws -> [SourceSet] {
        try runOnDatabase { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, notebook_id, name, created_at FROM source_sets WHERE notebook_id=? ORDER BY name ASC",
                arguments: [notebookId]
            ).map { SourceSet(id: $0["id"], notebookId: $0["notebook_id"], name: $0["name"], createdAt: $0["created_at"]) }
        }
    }

    @discardableResult
    public func createSourceSet(notebookId: Int64, name: String) throws -> SourceSet {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidSourceSetName(name) }
        let now = Date()
        return try runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO source_sets(notebook_id, name, created_at) VALUES(?, ?, ?)",
                arguments: [notebookId, trimmed, now]
            )
            return SourceSet(id: db.lastInsertedRowID, notebookId: notebookId, name: trimmed, createdAt: now)
        }
    }

    public func renameSourceSet(id: Int64, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidSourceSetName(name) }
        try runOnDatabase { db in
            try db.execute(sql: "UPDATE source_sets SET name=? WHERE id=?", arguments: [trimmed, id])
        }
    }

    public func deleteSourceSet(id: Int64) throws {
        try runOnDatabase { db in
            try db.execute(sql: "DELETE FROM source_sets WHERE id=?", arguments: [id])
        }
    }

    public func setSourceSetMembers(setId: Int64, sourceIds: [Int64]) throws {
        try runOnDatabase { db in
            try db.execute(sql: "DELETE FROM source_set_members WHERE set_id=?", arguments: [setId])
            for src in sourceIds {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO source_set_members(set_id, source_id) VALUES(?, ?)",
                    arguments: [setId, src]
                )
            }
        }
    }

    public func sourceSetMembers(setId: Int64) throws -> [Int64] {
        try runOnDatabase { db in
            try Int64.fetchAll(db, sql: "SELECT source_id FROM source_set_members WHERE set_id=?", arguments: [setId])
        }
    }
}

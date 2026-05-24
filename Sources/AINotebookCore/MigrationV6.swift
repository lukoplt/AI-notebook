import Foundation
import GRDB

public func registerMigrationV6(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v6_notes_auto_source_and_uuid") { db in
        try db.alter(table: "notes") { t in
            t.add(column: "auto_source_id", .integer)
                .references("sources", onDelete: .setNull)
            t.add(column: "note_uuid", .text)
        }
        try db.create(
            index: "idx_notes_auto_source",
            on: "notes",
            columns: ["auto_source_id"]
        )
        let ids: [Int64] = try Int64.fetchAll(db, sql: "SELECT id FROM notes WHERE note_uuid IS NULL")
        for id in ids {
            try db.execute(
                sql: "UPDATE notes SET note_uuid = ? WHERE id = ?",
                arguments: [UUID().uuidString.lowercased(), id]
            )
        }
    }
}

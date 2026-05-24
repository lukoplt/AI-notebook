import GRDB

public func registerMigrationV8(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v8_note_versions") { db in
        try db.create(table: "note_versions") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("note_id", .integer)
                .notNull()
                .references("notes", onDelete: .cascade)
            t.column("title",    .text).notNull()
            t.column("body_md",  .text).notNull()
            t.column("saved_at", .datetime).notNull()
            t.column("reason",   .text).notNull()
        }
        try db.create(
            index: "idx_note_versions_note",
            on: "note_versions",
            columns: ["note_id", "saved_at"]
        )
    }
}

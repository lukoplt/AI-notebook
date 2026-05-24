import GRDB

public func registerMigrationV7(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v7_attachments") { db in
        try db.create(table: "attachments") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("note_id", .integer)
                .notNull()
                .references("notes", onDelete: .cascade)
            t.column("note_uuid",  .text).notNull()
            t.column("filename",   .text).notNull()
            t.column("mime",       .text).notNull()
            t.column("byte_size",  .integer).notNull()
            t.column("created_at", .datetime).notNull()
        }
        try db.create(
            index: "idx_attachments_note",
            on: "attachments",
            columns: ["note_id"]
        )
    }
}

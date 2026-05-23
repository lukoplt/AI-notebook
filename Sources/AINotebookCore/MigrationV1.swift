import GRDB

/// Schema v1 — adds only the `notebooks` table. Subsequent migrations
/// (v2, v3, …) add sources, chunks, notes, etc.
public func registerMigrationV1(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v1_notebooks") { db in
        try db.create(table: "notebooks") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull()
            t.column("description", .text).notNull().defaults(to: "")
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
        }
        try db.create(
            index: "notebooks_name_idx",
            on: "notebooks",
            columns: ["name"]
        )
    }
}

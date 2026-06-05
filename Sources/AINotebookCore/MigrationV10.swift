import GRDB

public func registerMigrationV10(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v10_source_summary") { db in
        try db.execute(sql: "ALTER TABLE sources ADD COLUMN \"summary\" TEXT;")
    }
}

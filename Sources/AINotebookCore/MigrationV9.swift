import GRDB

public func registerMigrationV9(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v9_transformations_description") { db in
        try db.alter(table: "transformations") { t in
            t.add(column: "description", .text).notNull().defaults(to: "")
        }
    }
}

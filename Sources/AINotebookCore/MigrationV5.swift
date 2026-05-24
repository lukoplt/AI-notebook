import GRDB

public func registerMigrationV5(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v5_notes_and_transformations") { db in
        try db.create(table: "notes") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("notebook_id", .integer)
                .notNull()
                .references("notebooks", onDelete: .cascade)
            t.column("title",       .text).notNull()
            t.column("body_md",     .text).notNull()
            t.column("origin",      .text).notNull()
            t.column("origin_ref",  .integer)
            t.column("created_at",  .datetime).notNull()
            t.column("updated_at",  .datetime).notNull()
        }
        try db.create(
            index: "idx_notes_notebook",
            on: "notes",
            columns: ["notebook_id", "updated_at"]
        )

        try db.create(table: "transformations") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name",            .text).notNull()
            t.column("prompt_template", .text).notNull()
            t.column("scope",           .text).notNull()
            t.column("is_builtin",      .integer).notNull().defaults(to: 0)
        }
        try db.create(
            index: "idx_transformations_name",
            on: "transformations",
            columns: ["name"]
        )

        try db.create(table: "transformation_runs") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("transformation_id", .integer)
                .notNull()
                .references("transformations", onDelete: .cascade)
            t.column("source_id", .integer)
                .references("sources", onDelete: .setNull)
            t.column("result_note_id", .integer)
                .references("notes", onDelete: .setNull)
            t.column("ran_at", .datetime).notNull()
        }
    }
}

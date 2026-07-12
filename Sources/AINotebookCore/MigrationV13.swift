import GRDB

/// Schema v13 — per-notebook instructions, regenerated-message model tag, and
/// named source sets (Epic C, FR-C1/C2/C3). Mirrors the Windows `Migrator.V13`
/// DDL verbatim.
public func registerMigrationV13(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v13_instructions_and_sourcesets") { db in
        try db.execute(sql: #"ALTER TABLE notebooks ADD COLUMN "instructions" TEXT NOT NULL DEFAULT ''"#)
        try db.execute(sql: #"ALTER TABLE messages ADD COLUMN "model" TEXT"#)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "source_sets" (
              "id" INTEGER PRIMARY KEY AUTOINCREMENT,
              "notebook_id" INTEGER NOT NULL REFERENCES "notebooks"("id") ON DELETE CASCADE,
              "name" TEXT NOT NULL,
              "created_at" DATETIME NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "source_set_members" (
              "set_id" INTEGER NOT NULL REFERENCES "source_sets"("id") ON DELETE CASCADE,
              "source_id" INTEGER NOT NULL REFERENCES "sources"("id") ON DELETE CASCADE,
              PRIMARY KEY (set_id, source_id)
            )
            """)
        try db.execute(sql: #"CREATE INDEX "idx_source_sets_notebook" ON "source_sets"("notebook_id")"#)
    }
}

import GRDB

/// Schema v18 — personas (Epic C5): a named, reusable combination of chat
/// instructions + a source set + a model, selectable in chat. Shared migration
/// identifier across both platforms (Windows adds the same `v18_personas` after
/// its repair migrations v16/v17, which macOS never needed).
public func registerMigrationV18(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v18_personas") { db in
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "personas" (
              "id" INTEGER PRIMARY KEY AUTOINCREMENT,
              "notebook_id" INTEGER NOT NULL REFERENCES "notebooks"("id") ON DELETE CASCADE,
              "name" TEXT NOT NULL,
              "instructions" TEXT NOT NULL DEFAULT '',
              "source_set_id" INTEGER REFERENCES "source_sets"("id") ON DELETE SET NULL,
              "model" TEXT,
              "created_at" DATETIME NOT NULL
            )
            """)
        try db.execute(sql: #"CREATE INDEX "idx_personas_notebook" ON "personas"("notebook_id")"#)
    }
}

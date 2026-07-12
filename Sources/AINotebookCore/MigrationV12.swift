import GRDB

/// Schema v12 — tags + note full-text search (Epic B, FR-B8/B9). Mirrors the
/// Windows `Migrator.V12` DDL verbatim so both platforms carry identical
/// schema. Creates `tags`, `note_tags`, `source_tags`, the `notes_fts` FTS5
/// virtual table with insert/delete/update triggers, and backfills the FTS
/// index for every note already in the database.
public func registerMigrationV12(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v12_tags_and_notes_fts") { db in
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "tags" (
              "id" INTEGER PRIMARY KEY AUTOINCREMENT,
              "name" TEXT NOT NULL UNIQUE
            )
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "note_tags" (
              "note_id" INTEGER NOT NULL REFERENCES "notes"("id") ON DELETE CASCADE,
              "tag_id" INTEGER NOT NULL REFERENCES "tags"("id") ON DELETE CASCADE,
              PRIMARY KEY (note_id, tag_id)
            )
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS "source_tags" (
              "source_id" INTEGER NOT NULL REFERENCES "sources"("id") ON DELETE CASCADE,
              "tag_id" INTEGER NOT NULL REFERENCES "tags"("id") ON DELETE CASCADE,
              PRIMARY KEY (source_id, tag_id)
            )
            """)
        try db.execute(sql: #"CREATE INDEX "idx_note_tags_tag" ON "note_tags"("tag_id")"#)
        try db.execute(sql: #"CREATE INDEX "idx_source_tags_tag" ON "source_tags"("tag_id")"#)

        try db.execute(sql: """
            CREATE VIRTUAL TABLE notes_fts USING fts5(title, body_md, note_id UNINDEXED, tokenize = 'porter unicode61')
            """)
        try db.execute(sql: """
            CREATE TRIGGER notes_ai AFTER INSERT ON notes BEGIN
              INSERT INTO notes_fts(rowid, title, body_md, note_id) VALUES (new.id, new.title, new.body_md, new.id);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER notes_ad AFTER DELETE ON notes BEGIN
              DELETE FROM notes_fts WHERE rowid = old.id;
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER notes_au AFTER UPDATE ON notes BEGIN
              UPDATE notes_fts SET title = new.title, body_md = new.body_md WHERE rowid = old.id;
            END
            """)
        // Backfill FTS for all notes that predate this migration.
        try db.execute(sql: """
            INSERT INTO notes_fts(rowid, title, body_md, note_id)
            SELECT id, title, body_md, id FROM notes
            """)
    }
}

import GRDB

/// Schema v2 — adds sources, source_chunks, FTS5 mirrors, and triggers
/// keeping the FTS tables in sync with their parents.
public func registerMigrationV2(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v2_sources_and_chunks") { db in
        try db.create(table: "sources") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("notebook_id", .integer)
                .notNull()
                .references("notebooks", onDelete: .cascade)
            t.column("type",        .text).notNull()
            t.column("title",       .text).notNull()
            t.column("uri",         .text)
            t.column("raw_path",    .text)
            t.column("status",      .text).notNull()
            t.column("error",       .text)
            t.column("ingested_at", .datetime).notNull()
        }
        try db.create(
            index: "idx_sources_notebook",
            on: "sources",
            columns: ["notebook_id"]
        )

        try db.create(table: "source_chunks") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("source_id", .integer)
                .notNull()
                .references("sources", onDelete: .cascade)
            t.column("ord",         .integer).notNull()
            t.column("text",        .text).notNull()
            t.column("token_count", .integer).notNull()
            t.column("page_hint",   .integer)
        }
        try db.create(
            index: "idx_chunks_source",
            on: "source_chunks",
            columns: ["source_id", "ord"]
        )

        try db.execute(sql: """
            CREATE VIRTUAL TABLE sources_fts USING fts5(
                title,
                source_id UNINDEXED,
                tokenize = 'porter unicode61'
            )
            """)
        try db.execute(sql: """
            CREATE VIRTUAL TABLE chunks_fts USING fts5(
                text,
                chunk_id UNINDEXED,
                tokenize = 'porter unicode61'
            )
            """)

        // Keep sources_fts in sync with sources (title only — v1 has no body
        // column on the sources row itself).
        try db.execute(sql: """
            CREATE TRIGGER sources_ai AFTER INSERT ON sources BEGIN
              INSERT INTO sources_fts(rowid, title, source_id)
              VALUES (new.id, new.title, new.id);
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER sources_ad AFTER DELETE ON sources BEGIN
              DELETE FROM sources_fts WHERE rowid = old.id;
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER sources_au AFTER UPDATE ON sources BEGIN
              UPDATE sources_fts SET title = new.title WHERE rowid = old.id;
            END;
            """)

        // Keep chunks_fts in sync with source_chunks.
        try db.execute(sql: """
            CREATE TRIGGER chunks_ai AFTER INSERT ON source_chunks BEGIN
              INSERT INTO chunks_fts(rowid, text, chunk_id)
              VALUES (new.id, new.text, new.id);
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER chunks_ad AFTER DELETE ON source_chunks BEGIN
              DELETE FROM chunks_fts WHERE rowid = old.id;
            END;
            """)
        try db.execute(sql: """
            CREATE TRIGGER chunks_au AFTER UPDATE ON source_chunks BEGIN
              UPDATE chunks_fts SET text = new.text WHERE rowid = old.id;
            END;
            """)
    }
}

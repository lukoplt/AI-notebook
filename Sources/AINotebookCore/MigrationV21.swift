import GRDB

/// Schema v21 — the per-source extraction failure budget (`ingestion-retry-cap-v1` §2).
/// One table keyed by source and no data (absent row = no failures, unknown
/// content); shared identifier with Windows `MigrationV21`.
public func registerMigrationV21(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v21_extract_retry_budget") { db in
        try db.execute(sql: v21Schema)
    }
}

let v21Schema = """
CREATE TABLE source_extract_budget (
 source_id INTEGER PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
 failures INTEGER NOT NULL DEFAULT 0 CHECK(failures>=0),
 content_hash TEXT CHECK(content_hash IS NULL OR length(content_hash)>0)
);
"""

import GRDB

/// Schema v15 — live-source sync bookkeeping (Epic E, FR-E1/E2). `last_synced_at`
/// and `content_hash` let watched folders and re-crawlable URLs detect change
/// and reindex only what moved. Mirrors the Windows `Migrator.V15` DDL.
public func registerMigrationV15(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v15_live_sources") { db in
        try db.execute(sql: #"ALTER TABLE sources ADD COLUMN "last_synced_at" TEXT"#)
        try db.execute(sql: #"ALTER TABLE sources ADD COLUMN "content_hash" TEXT"#)
    }
}

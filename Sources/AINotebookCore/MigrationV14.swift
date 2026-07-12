import GRDB

/// Schema v14 — contextual chunk enrichment column (Epic D, FR-D1). Holds an
/// optional 1–2 sentence document-level context string prepended to a chunk's
/// text before embedding. Mirrors the Windows `Migrator.V14` DDL.
public func registerMigrationV14(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v14_chunk_context") { db in
        try db.execute(sql: #"ALTER TABLE source_chunks ADD COLUMN "context" TEXT"#)
    }
}

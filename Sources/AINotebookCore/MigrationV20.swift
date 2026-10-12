import GRDB

/// Schema v20 — dedup ledger of every vector a build stores (`embedding-plan-v1` §5).
/// Adds one table and no data; shared identifier with Windows `MigrationV20`.
public func registerMigrationV20(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v20_embedding_dedup") { db in
        try db.execute(sql: v20Schema)
    }
}

let v20Schema = """
CREATE TABLE generation_text_hashes (
 generation_id INTEGER NOT NULL REFERENCES index_generations(id) ON DELETE CASCADE,
 chunk_id INTEGER NOT NULL REFERENCES source_chunks(id) ON DELETE CASCADE,
 text_hash TEXT NOT NULL CHECK(length(text_hash)=64),
 copied INTEGER NOT NULL CHECK(copied IN (0,1)),
 PRIMARY KEY(generation_id,chunk_id)
) WITHOUT ROWID;
CREATE INDEX idx_generation_text_hashes_hash ON generation_text_hashes(generation_id,text_hash);
CREATE INDEX idx_generation_text_hashes_chunk ON generation_text_hashes(chunk_id);
CREATE INDEX idx_generation_text_hashes_copied ON generation_text_hashes(generation_id) WHERE copied=1;
"""

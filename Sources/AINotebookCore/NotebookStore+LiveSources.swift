import Foundation
import GRDB

/// Chunk context (Epic D1) and live-source sync bookkeeping (Epic E1/E2).
extension NotebookStore {

    /// Stores the enrichment context for a single chunk (FR-D1).
    public func setChunkContext(chunkId: Int64, context: String) throws {
        try runOnDatabase { db in
            try db.execute(sql: "UPDATE source_chunks SET context=? WHERE id=?", arguments: [context, chunkId])
        }
    }

    /// Records a successful live-source sync (FR-E1/E2).
    public func updateSourceSyncInfo(id: Int64, lastSyncedAt: Date, contentHash: String) throws {
        try runOnDatabase { db in
            try db.execute(
                sql: "UPDATE sources SET last_synced_at=?, content_hash=? WHERE id=?",
                arguments: [lastSyncedAt, contentHash, id]
            )
        }
    }

    /// The recorded content hash for a source, or nil if never synced.
    public func sourceContentHash(id: Int64) throws -> String? {
        try runOnDatabase { db in
            try String.fetchOne(db, sql: "SELECT content_hash FROM sources WHERE id=?", arguments: [id])
        }
    }
}

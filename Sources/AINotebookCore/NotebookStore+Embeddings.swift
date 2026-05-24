import Foundation
import GRDB

public struct StoredEmbedding: Equatable, Sendable {
    public let chunkId: Int64
    public let sourceId: Int64
    public let vector: EmbeddingVector
}

extension NotebookStore {

    public func storeEmbedding(
        chunkId: Int64,
        model: String,
        vector: EmbeddingVector
    ) throws {
        try runOnDatabase { db in
            try db.execute(
                sql: """
                INSERT INTO chunk_embeddings(chunk_id, dim, model, embedding)
                VALUES (?,?,?,?)
                ON CONFLICT(chunk_id) DO UPDATE SET
                  dim = excluded.dim,
                  model = excluded.model,
                  embedding = excluded.embedding
                """,
                arguments: [chunkId, vector.dim, model, vector.asData()]
            )
        }
    }

    /// All embeddings in a notebook for the given model.
    public func embeddings(notebookId: Int64, model: String) throws -> [StoredEmbedding] {
        try runOnDatabase { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT ce.chunk_id, sc.source_id, ce.embedding
                FROM chunk_embeddings ce
                JOIN source_chunks sc ON sc.id = ce.chunk_id
                JOIN sources s ON s.id = sc.source_id
                WHERE s.notebook_id = ? AND ce.model = ?
                """,
                arguments: [notebookId, model]
            )
            return try rows.map { row in
                let bytes: Data = row["embedding"]
                return StoredEmbedding(
                    chunkId: row["chunk_id"],
                    sourceId: row["source_id"],
                    vector: try EmbeddingVector(data: bytes)
                )
            }
        }
    }

    /// Chunks that do not yet have a row in `chunk_embeddings` for the given model.
    public func unembeddedChunks(model: String, limit: Int) throws -> [SourceChunk] {
        try runOnDatabase { db in
            try SourceChunk.fetchAll(
                db,
                sql: """
                SELECT sc.* FROM source_chunks sc
                LEFT JOIN chunk_embeddings ce
                  ON ce.chunk_id = sc.id AND ce.model = ?
                WHERE ce.chunk_id IS NULL
                ORDER BY sc.id ASC
                LIMIT ?
                """,
                arguments: [model, limit]
            )
        }
    }

    public func unembeddedCount(model: String) throws -> Int {
        try runOnDatabase { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT count(*) FROM source_chunks sc
                LEFT JOIN chunk_embeddings ce
                  ON ce.chunk_id = sc.id AND ce.model = ?
                WHERE ce.chunk_id IS NULL
                """,
                arguments: [model]
            ) ?? 0
        }
    }

    public func deleteAllEmbeddings(model: String) throws {
        try runOnDatabase { db in
            try db.execute(
                sql: "DELETE FROM chunk_embeddings WHERE model = ?",
                arguments: [model]
            )
        }
    }
}

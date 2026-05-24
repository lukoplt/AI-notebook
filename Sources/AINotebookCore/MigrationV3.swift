import GRDB

public func registerMigrationV3(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v3_chunk_embeddings") { db in
        try db.create(table: "chunk_embeddings") { t in
            t.column("chunk_id", .integer)
                .primaryKey()
                .references("source_chunks", onDelete: .cascade)
            t.column("dim",       .integer).notNull()
            t.column("model",     .text).notNull()
            t.column("embedding", .blob).notNull()
        }
        try db.create(
            index: "idx_chunk_embeddings_model",
            on: "chunk_embeddings",
            columns: ["model"]
        )
    }
}

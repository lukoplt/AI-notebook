import GRDB

/// Schema v11 — provider registry. Creates `providers`, seeds the built-in
/// Ollama row, and requalifies `chunk_embeddings.model` to the fully
/// qualified "{providerId}:{model}" key (FR-A11) so same-named models under
/// different providers can never return each other's vectors.
public func registerMigrationV11(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v11_providers") { db in
        try db.create(table: "providers") { t in
            t.column("id", .text).primaryKey()
            t.column("type", .text).notNull()
            t.column("name", .text).notNull()
            t.column("base_url", .text).notNull()
            t.column("enabled", .integer).notNull().defaults(to: 1)
            t.column("privacy_acknowledged", .integer).notNull().defaults(to: 0)
            t.column("created_at", .datetime).notNull()
        }
        try db.execute(
            sql: """
            INSERT INTO providers(id, type, name, base_url, enabled, privacy_acknowledged, created_at)
            VALUES (?, 'ollama', 'Ollama (local)', 'http://127.0.0.1:11434', 1, 1, datetime('now'))
            """,
            arguments: [ProviderConfig.ollamaId]
        )
        try db.execute(
            sql: """
            UPDATE chunk_embeddings
            SET model = ? || ':' || model
            WHERE model NOT LIKE '%:%'
            """,
            arguments: [ProviderConfig.ollamaId]
        )
    }
}

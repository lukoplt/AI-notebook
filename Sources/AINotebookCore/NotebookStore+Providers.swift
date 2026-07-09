import Foundation
import GRDB

extension NotebookStore {

    public func providers() throws -> [ProviderConfig] {
        try runOnDatabase { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, type, name, base_url, enabled, privacy_acknowledged, created_at
                FROM providers ORDER BY created_at, id
                """
            )
            return rows.map(Self.providerConfig(from:))
        }
    }

    public func provider(id: String) throws -> ProviderConfig? {
        try runOnDatabase { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT id, type, name, base_url, enabled, privacy_acknowledged, created_at
                FROM providers WHERE id = ?
                """,
                arguments: [id]
            ).map(Self.providerConfig(from:))
        }
    }

    /// Upsert. On update, `privacy_acknowledged` is intentionally NOT
    /// overwritten — consent is granted once via `acknowledgePrivacy` and an
    /// edit must not reset it.
    public func saveProvider(_ config: ProviderConfig) throws {
        try runOnDatabase { db in
            try db.execute(
                sql: """
                INSERT INTO providers(id, type, name, base_url, enabled, privacy_acknowledged, created_at)
                VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  type = excluded.type,
                  name = excluded.name,
                  base_url = excluded.base_url,
                  enabled = excluded.enabled
                """,
                arguments: [
                    config.id, config.type.rawValue, config.name, config.baseURL,
                    config.enabled, config.privacyAcknowledged, config.createdAt
                ]
            )
        }
    }

    public func deleteProvider(id: String) throws {
        guard id != ProviderConfig.ollamaId else {
            throw StoreError.builtInProviderUndeletable
        }
        try runOnDatabase { db in
            try db.execute(sql: "DELETE FROM providers WHERE id = ?", arguments: [id])
        }
    }

    public func acknowledgePrivacy(providerId: String) throws {
        try runOnDatabase { db in
            try db.execute(
                sql: "UPDATE providers SET privacy_acknowledged = 1 WHERE id = ?",
                arguments: [providerId]
            )
        }
    }

    private static func providerConfig(from row: Row) -> ProviderConfig {
        ProviderConfig(
            id: row["id"],
            type: ProviderType.fromStorage(row["type"]),
            name: row["name"],
            baseURL: row["base_url"],
            enabled: (row["enabled"] as Int64? ?? 0) != 0,
            privacyAcknowledged: (row["privacy_acknowledged"] as Int64? ?? 0) != 0,
            createdAt: row["created_at"]
        )
    }
}

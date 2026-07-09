import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV11Tests: XCTestCase {

    func testV11CreatesProvidersTable() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let cols: [Row] = try Row.fetchAll(db, sql: "PRAGMA table_info('providers')")
            let names = cols.compactMap { $0["name"] as String? }
            XCTAssertEqual(
                Set(names),
                ["id", "type", "name", "base_url", "enabled", "privacy_acknowledged", "created_at"],
                "got: \(names)"
            )
        }
    }

    func testV11SeedsBuiltInOllamaRow() throws {
        let store = try NotebookStore(path: .inMemory)
        let cfg = try XCTUnwrap(try store.provider(id: ProviderConfig.ollamaId))
        XCTAssertEqual(cfg.type, .ollama)
        XCTAssertEqual(cfg.baseURL, "http://127.0.0.1:11434")
        XCTAssertTrue(cfg.enabled)
        XCTAssertTrue(cfg.privacyAcknowledged)
    }

    /// Builds a v10 database by hand (migrations v1-v10 only — no `providers`
    /// table yet) and plants a single legacy `chunk_embeddings` row with the
    /// given `model` string. Callers then register + run v11 and inspect the
    /// result.
    private func makeV10Database(legacyModel: String) throws -> (DatabaseQueue, DatabaseMigrator) {
        let q = try DatabaseQueue()
        var m = DatabaseMigrator()
        registerMigrationV1(on: &m)
        registerMigrationV2(on: &m)
        registerMigrationV3(on: &m)
        registerMigrationV4(on: &m)
        registerMigrationV5(on: &m)
        registerMigrationV6(on: &m)
        registerMigrationV7(on: &m)
        registerMigrationV8(on: &m)
        registerMigrationV9(on: &m)
        registerMigrationV10(on: &m)
        try m.migrate(q)

        try q.write { db in
            // FK-safe insert: PRAGMA foreign_keys = OFF is a no-op inside the
            // active transaction that `write` opens (SQLite only honors this
            // pragma outside a transaction), so we build a minimal
            // notebook -> source -> source_chunk parent chain instead of
            // relying on disabling FK enforcement. See MigrationV1/V2/V3 for
            // the real column lists.
            try db.execute(
                sql: """
                INSERT INTO notebooks(name, description, created_at, updated_at)
                VALUES ('Test', '', datetime('now'), datetime('now'))
                """
            )
            let notebookId = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO sources(notebook_id, type, title, status, ingested_at)
                VALUES (?, 'text', 'Test source', 'ready', datetime('now'))
                """,
                arguments: [notebookId]
            )
            let sourceId = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO source_chunks(source_id, ord, text, token_count)
                VALUES (?, 0, 'hello world', 2)
                """,
                arguments: [sourceId]
            )
            let chunkId = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO chunk_embeddings(chunk_id, dim, model, embedding) VALUES (?, 2, ?, x'00000000')",
                arguments: [chunkId, legacyModel]
            )
        }
        return (q, m)
    }

    /// Legacy Ollama model strings routinely contain colons (tags like
    /// "llama3.2:3b", "nomic-embed-text:latest") — before v11 the
    /// `providers` table didn't exist, so no legacy row can already be
    /// legitimately provider-qualified. Requalification must not skip these.
    func testV11RequalifiesExistingEmbeddingKeys() throws {
        let (q, m) = try makeV10Database(legacyModel: "llama3.2:3b")
        var migrator = m
        registerMigrationV11(on: &migrator)
        try migrator.migrate(q)

        try q.read { db in
            let model = try XCTUnwrap(String.fetchOne(db, sql: "SELECT model FROM chunk_embeddings LIMIT 1"))
            XCTAssertEqual(model, "\(ProviderConfig.ollamaId):llama3.2:3b")
        }
    }

    /// The only row that must survive untouched is one already prefixed
    /// with the built-in Ollama id — that's the sole marker v11 can trust
    /// to mean "already qualified", since the `providers` table (and thus
    /// any other real provider id) didn't exist before this migration.
    func testV11DoesNotDoubleQualifyAlreadyQualifiedKeys() throws {
        let (q, m) = try makeV10Database(legacyModel: "\(ProviderConfig.ollamaId):nomic")
        var migrator = m
        registerMigrationV11(on: &migrator)
        try migrator.migrate(q)

        try q.read { db in
            let model = try XCTUnwrap(String.fetchOne(db, sql: "SELECT model FROM chunk_embeddings LIMIT 1"))
            XCTAssertEqual(
                model, "\(ProviderConfig.ollamaId):nomic",
                "a row already prefixed with the built-in Ollama id must not be rewritten"
            )
        }
    }

    /// A colon-containing string NOT prefixed with the built-in Ollama id
    /// (e.g. "abc:nomic") cannot have originated from a real provider —
    /// `providers` didn't exist pre-v11 — so it must be requalified too.
    /// This is a behavior change from the old (buggy) `NOT LIKE '%:%'` rule.
    func testV11RequalifiesArbitraryColonContainingLegacyKey() throws {
        let (q, m) = try makeV10Database(legacyModel: "abc:nomic")
        var migrator = m
        registerMigrationV11(on: &migrator)
        try migrator.migrate(q)

        try q.read { db in
            let model = try XCTUnwrap(String.fetchOne(db, sql: "SELECT model FROM chunk_embeddings LIMIT 1"))
            XCTAssertEqual(model, "\(ProviderConfig.ollamaId):abc:nomic")
        }
    }
}

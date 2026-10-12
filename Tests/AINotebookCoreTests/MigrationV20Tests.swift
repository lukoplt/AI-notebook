import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

/// Shared `storage-v20` schema: the dedup ledger (`embedding-plan-v1` §5).
@MainActor
final class MigrationV20Tests: XCTestCase {
    private func fixtureCase(_ name: String) throws -> [[String: Any]] {
        let root = try SharedFixtures.json("contracts/storage-v20.json")
        XCTAssertEqual(root["migration"] as? String, "v20_embedding_dedup")
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let match = try XCTUnwrap(cases.first { $0["name"] as? String == name })
        return try XCTUnwrap(match["queries"] as? [[String: Any]])
    }

    func testFreshSchemaMatchesSharedFixture() throws {
        let store = try V19TestStore.make()
        try V19TestStore.assertQueries(store, queries: fixtureCase("fresh-schema"))
        try store.runOnDatabase { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertThrowsError(try db.execute(sql: "INSERT INTO generation_text_hashes VALUES (1,1,'short',0)"))
        }
    }

    func testUpgradeFromV18AddsAnEmptyLedger() throws {
        let (store, directory, _) = try V19TestStore.upgradeCopy(configuredKey: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        try V19TestStore.assertQueries(store, queries: fixtureCase("upgrade-from-v18"))
        try store.runOnDatabase { db in
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testLedgerRowsCascadeWithGenerationAndChunk() throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "cascade").id)
        try EmbeddingPlanContractTests.seed(store, notebookId: notebook, sources: [
            ["id": 1, "type": "text", "chunks": ["a", "b"]], ["id": 2, "type": "text", "chunks": ["c"]]])
        let identity = GenerationIdentity(providerId: "local", endpointRevision: "1", model: "m", modelDigest: nil, dims: 2,
            normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")
        let generation = try store.createGeneration(notebookId: notebook, identity: identity, now: 0)
        try store.runOnDatabase { db in
            for chunk in try Int64.fetchAll(db, sql: "SELECT id FROM source_chunks ORDER BY id") {
                try db.execute(sql: "INSERT INTO generation_text_hashes VALUES (?,?,?,0)",
                               arguments: [generation.id, chunk, EmbeddingPlan.textHash("\(chunk)")])
            }
            try db.execute(sql: "DELETE FROM sources WHERE id=2")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM generation_text_hashes"), 2)
            try db.execute(sql: "DELETE FROM index_generations WHERE id=?", arguments: [generation.id])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM generation_text_hashes"), 0)
        }
    }
}

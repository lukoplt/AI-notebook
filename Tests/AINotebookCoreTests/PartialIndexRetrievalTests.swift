import XCTest
import GRDB
@testable import AINotebookCore

/// Scripted query session for retrieval-partial-v1: checks the pinned endpoint
/// revision like ProviderRouter, then returns the case's vector or fails.
private actor PartialScriptedProvider: EmbeddingProducing, EmbeddingSessionPreparing {
    enum Failure: Error { case unavailable }
    private let endpoint: String
    private let reply: [Float]?
    private(set) var calls = 0

    init(endpoint: String, reply: [Float]?) {
        self.endpoint = endpoint
        self.reply = reply
    }

    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        calls += 1
        guard let reply else { throw Failure.unavailable }
        return inputs.map { _ in reply }
    }

    nonisolated func prepareEmbedding(identity: GenerationIdentity) async throws -> ProviderEmbeddingSession {
        guard identity.endpointRevision == endpoint else { throw RetrievalError.endpointRevisionMismatch }
        return ProviderEmbeddingSession(client: self, model: identity.model, storageKey: identity.modelKey,
                                        endpointRevision: endpoint)
    }
}

@MainActor final class PartialIndexRetrievalTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        try SharedFixtures.json("contracts/retrieval-partial-v1.json")
    }

    func testSharedPartialIndexCases() async throws {
        let fixture = try fixture()
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        let selection = try XCTUnwrap(fixture["selection"] as? [String: String])
        let modelKey = selection["providerId"]! + ":" + selection["model"]!
        let notebookId = (fixture["notebookId"] as! NSNumber).int64Value
        let fetchK = (fixture["fetchK"] as! NSNumber).intValue
        for c in cases {
            let name = c["name"] as! String
            let expected = c["expected"] as! [String: Any]
            let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
            try Self.seed(store, fixture["seed"] as! [String: Any], world: c)
            let provider = c["provider"] as! [String: Any]
            let reply = (provider["kind"] as! String) == "vector"
                ? (provider["vector"] as! [NSNumber]).map(\.floatValue) : nil
            let client = PartialScriptedProvider(endpoint: c["sessionEndpointRevision"] as! String, reply: reply)
            let retriever = Retriever(store: store, client: client, model: modelKey,
                                      rrfK: (fixture["rrfK"] as! NSNumber).intValue)
            let pool = try await retriever.search(notebookId: notebookId, query: fixture["query"] as! String,
                                                  scope: .all, fetchK: fetchK)
            let snapshot = try XCTUnwrap(pool.snapshot, name)
            XCTAssertEqual(snapshot.generation?.id, (expected["generationId"] as? NSNumber)?.int64Value, name)
            XCTAssertEqual(snapshot.pin.generationId, (expected["generationId"] as? NSNumber)?.int64Value, name)
            XCTAssertEqual(snapshot.generation?.state, expected["generationState"] as? String, name)
            let revisions = Dictionary(uniqueKeysWithValues: (expected["vectorRevisions"] as! [[String: NSNumber]]).map {
                ($0["sourceId"]!.int64Value, $0["revisionId"]!.int64Value)
            })
            XCTAssertEqual(snapshot.pin.vectorRevisions, revisions, name)
            XCTAssertEqual(pool.diagnostics.vectorStatus, expected["vectorStatus"] as? String, name)
            let calls = await client.calls
            XCTAssertEqual(calls, (expected["embedCalls"] as! NSNumber).intValue, name)
            XCTAssertEqual(pool.embeddingError != nil, expected["embeddingError"] as! Bool, name)
            XCTAssertEqual(pool.lexical.map(\.reference.chunkId), Self.ids(expected["lexicalChunkIds"]), name)
            XCTAssertEqual(pool.vector.map(\.reference.chunkId), Self.ids(expected["vectorChunkIds"]), name)
            let fused = (expected["fused"] as! [[String: NSNumber]]).map { [$0["chunkId"]!.int64Value, $0["rrfMicro"]!.int64Value] }
            XCTAssertEqual(pool.fused.map { [$0.reference.chunkId, $0.rrfMicro] }, fused, name)
            if snapshot.generation?.state == "building" {
                // Partial pins never take an epoch-keyed matrix (every build write bumps the
                // epoch), but they are served by the generation's resident, revision-checked
                // matrix, which grows pair by pair as the build completes sources
                // (retrieval-resident-v1 §5).
                XCTAssertNil(snapshot.cacheKey, name)
                if pool.diagnostics.vectorStatus == "used" { XCTAssertFalse(pool.diagnostics.streamed, name) }
            }
            await pool.close()
        }
    }

    /// Context pack, citations and evidence hydration take the partial pin unchanged:
    /// every fused candidate of a building pin hydrates from its pinned revision.
    func testPartialPinHydratesEvidence() async throws {
        let fixture = try fixture()
        let c = try XCTUnwrap((fixture["cases"] as! [[String: Any]]).first { $0["name"] as? String == "building-partial" })
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        try Self.seed(store, fixture["seed"] as! [String: Any], world: c)
        let client = PartialScriptedProvider(endpoint: "e1", reply: [1, 0, 0])
        let retriever = Retriever(store: store, client: client, model: "p:m")
        let hits = try await retriever.search(notebookId: 1, query: "kiwi", topK: 8)
        let fused = ((c["expected"] as! [String: Any])["fused"] as! [[String: NSNumber]]).map { $0["chunkId"]!.int64Value }
        XCTAssertEqual(hits.map(\.chunkId), fused)
        XCTAssertTrue(hits.allSatisfy { !$0.snippet.isEmpty })
        XCTAssertFalse(hits.contains { [301, 511, 611].contains($0.chunkId) })
    }

    private static func ids(_ value: Any?) -> [Int64] {
        (value as? [Any] ?? []).map { ($0 as! NSNumber).int64Value }
    }

    static func seed(_ store: NotebookStore, _ seed: [String: Any], world: [String: Any]) throws {
        func rows(_ object: [String: Any], _ key: String) -> [[String: Any]] { object[key] as! [[String: Any]] }
        func value(_ any: Any?) -> DatabaseValue {
            switch any {
            case let number as NSNumber: return number.int64Value.databaseValue
            case let text as String: return text.databaseValue
            default: return .null
            }
        }
        func insert(_ db: Database, _ table: String, _ row: [String: Any], _ columns: [(String, String)]) throws {
            let names = columns.map(\.1).joined(separator: ",")
            let marks = Array(repeating: "?", count: columns.count).joined(separator: ",")
            try db.execute(sql: "INSERT INTO \(table)(\(names)) VALUES(\(marks))",
                           arguments: StatementArguments(columns.map { value(row[$0.0]) }))
        }
        try store.runOnDatabase { db in
            for row in rows(seed, "notebooks") {
                try insert(db, "notebooks", row, [("id", "id"), ("name", "name"), ("createdAt", "created_at"), ("updatedAt", "updated_at")])
            }
            for row in rows(seed, "sources") {
                try insert(db, "sources", row, [("id", "id"), ("notebookId", "notebook_id"), ("type", "type"), ("title", "title"),
                    ("status", "status"), ("ingestedAt", "ingested_at"), ("availability", "availability"), ("eligible", "eligible")])
            }
            for row in rows(seed, "revisions") {
                try insert(db, "source_revisions", row, [("id", "id"), ("sourceId", "source_id"), ("revision", "revision"),
                    ("contentHash", "content_hash"), ("canonicalText", "canonical_text"), ("textFormatVersion", "text_format_version"),
                    ("chunkerVersion", "chunker_version"), ("createdAt", "created_at")])
            }
            for row in rows(seed, "chunks") {
                try insert(db, "source_chunks", row, [("id", "id"), ("sourceId", "source_id"), ("revisionId", "revision_id"),
                    ("ord", "ord"), ("text", "text"), ("tokenCount", "token_count")])
            }
            for row in rows(seed, "sources") {
                try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?",
                               arguments: [value(row["currentRevision"]), value(row["publishedRevisionId"]), value(row["id"])])
            }
            for row in rows(world, "generations") {
                try insert(db, "index_generations", row, [("id", "id"), ("notebookId", "notebook_id"), ("providerId", "provider_id"),
                    ("endpointRevision", "endpoint_revision"), ("model", "model"), ("modelDigest", "model_digest"), ("dims", "dims"),
                    ("normalization", "normalization"), ("queryFormatVersion", "query_format_version"),
                    ("docFormatVersion", "doc_format_version"), ("chunkerVersion", "chunker_version"), ("state", "state"),
                    ("createdAt", "created_at")])
            }
            for row in rows(world, "manifest") {
                try insert(db, "index_generation_manifest", row, [("generationId", "generation_id"), ("sourceId", "source_id"),
                    ("revisionId", "revision_id"), ("state", "state"), ("reason", "reason")])
            }
            for row in rows(world, "embeddings") {
                let vector = (row["vector"] as! [NSNumber]).map(\.floatValue)
                try db.execute(sql: "INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES(?,?,?)",
                               arguments: [value(row["chunkId"]), value(row["generationId"]), EmbeddingVector(values: vector).asData()])
            }
        }
    }
}

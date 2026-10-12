import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

/// Records every provider request (input texts) and answers a deterministic nonzero vector per text.
final class RecordingTextEmbedder: EmbeddingProducing, @unchecked Sendable {
    private let gate = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] { gate.lock(); defer { gate.unlock() }; return recorded }
    private func record(_ inputs: [String]) { gate.lock(); recorded.append(inputs); gate.unlock() }
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        record(inputs)
        return inputs.map { text in
            let scalars = text.unicodeScalars.map { Int($0.value) }
            return [Float(scalars.count + 1), Float(scalars.reduce(0, +) % 997 + 1), Float(scalars.first ?? 7)]
        }
    }
}

private struct PlanClock: IngestLeaseClock {
    func now() -> Int64 { 2 }
    func wait(until: Int64) async throws { try await Task.sleep(nanoseconds: 1_000_000) }
}

/// Shared `embedding-plan-v1` cases: priority order, spreadsheet cap and dedup through the real coordinator.
@MainActor
final class EmbeddingPlanContractTests: XCTestCase {
    private func cases(_ operation: String) throws -> [[String: Any]] {
        let root = try SharedFixtures.json("contracts/embedding-plan-v1.json")
        let constants = try XCTUnwrap(root["constants"] as? [String: Any])
        XCTAssertEqual(constants["spreadsheetChunkCap"] as? Int, EmbeddingPlan.spreadsheetChunkCap)
        XCTAssertEqual(constants["roundScanFactor"] as? Int, EmbeddingPlan.roundScanFactor)
        XCTAssertEqual(constants["spreadsheetTypes"] as? [String], EmbeddingPlan.spreadsheetTypes.map(\.rawValue))
        let all = try XCTUnwrap(root["cases"] as? [[String: Any]])
        return all.filter { $0["operation"] as? String == operation }
    }

    func testClassifyAndTextHash() throws {
        let classify = try cases("classify")
        XCTAssertEqual(classify.count, SourceType.allCases.count)
        for c in classify {
            let input = try XCTUnwrap(c["input"] as? [String: Any]), expected = try XCTUnwrap(c["expected"] as? [String: Any])
            let type = try XCTUnwrap(SourceType(rawValue: try XCTUnwrap(input["sourceType"] as? String)))
            XCTAssertEqual(EmbeddingPlan.priorityClass(type), expected["priorityClass"] as? Int, c["name"] as? String ?? "")
            XCTAssertEqual(EmbeddingPlan.embedCap(type), expected["embedCap"] as? Int, c["name"] as? String ?? "")
        }
        let hashes = try cases("textHash")
        XCTAssertFalse(hashes.isEmpty)
        for c in hashes {
            let text = try XCTUnwrap((c["input"] as? [String: Any])?["text"] as? String)
            XCTAssertEqual(EmbeddingPlan.textHash(text), (c["expected"] as? [String: Any])?["hash"] as? String, c["name"] as? String ?? "")
        }
    }

    func testBuildCasesThroughTheCoordinator() async throws {
        let builds = try cases("build")
        XCTAssertGreaterThanOrEqual(builds.count, 6)
        for c in builds {
            for dims in [3, nil] as [Int?] {
                try await runBuild(c, dims: dims)
            }
        }
    }

    /// Seeds the case into a fresh store, builds through `FolderIndexCoordinator.execute` and checks the expectations.
    private func runBuild(_ c: [String: Any], dims: Int?) async throws {
        let name = (c["name"] as? String ?? "") + (dims == nil ? " (bootstrap)" : "")
        let input = try XCTUnwrap(c["input"] as? [String: Any]), expected = try XCTUnwrap(c["expected"] as? [String: Any])
        let batchSize = try XCTUnwrap(input["batchSize"] as? Int)
        let sources = try XCTUnwrap(input["sources"] as? [[String: Any]])
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebookId = try XCTUnwrap(store.createNotebook(name: "plan").id)
        try Self.seed(store, notebookId: notebookId, sources: sources)
        let selection = EmbeddingSelection(providerId: "local", endpointRevision: "1", model: "m", modelDigest: nil, dims: dims,
            normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")
        let embedder = RecordingTextEmbedder()
        let jobId = try store.requestEmbeddingBuild(notebookId: notebookId, selection: selection, copyExisting: false, now: 1)
        let job = try XCTUnwrap(store.claimJob(now: 1, leaseToken: "plan", id: jobId))
        let coordinator = FolderIndexCoordinator(store: store, admission: IngestionAdmission(), clock: PlanClock(),
            session: { _ in FolderEmbeddingSession(selection: selection, embedder: embedder) },
            selectedSelection: { _ in selection }, batchSize: batchSize)
        try await coordinator.execute(job: job, fence: JobFence(jobId: jobId, leaseToken: "plan"))

        // Compare UTF-8 bytes: Swift String equality would accept an NFD input for an NFC one.
        XCTAssertEqual(embedder.calls.map { $0.map { Array($0.utf8) } },
                       try XCTUnwrap(expected["calls"] as? [[String]]).map { $0.map { Array($0.utf8) } }, name)
        let active = try XCTUnwrap(store.activeGeneration(notebookId: notebookId), name)
        let progress = try store.runOnDatabase { try IndexingStatusSQL.chunkProgress($0, generationId: active.id) }
        let chunkProgress = try XCTUnwrap(expected["chunkProgress"] as? [String: Int])
        XCTAssertEqual(progress.done, chunkProgress["done"], name)
        XCTAssertEqual(progress.total, chunkProgress["total"], name)
        let manifest = try store.manifest(generationId: active.id)
        let sourceProgress = try XCTUnwrap(expected["sourceProgress"] as? [String: Int])
        XCTAssertEqual(manifest.filter { $0.state == "done" }.count, sourceProgress["done"], name)
        XCTAssertEqual(manifest.count, sourceProgress["total"], name)
        try store.runOnDatabase { db in
            let copied = try Int.fetchOne(db, sql: "SELECT count(*) FROM generation_text_hashes WHERE generation_id=? AND copied=1",
                                          arguments: [active.id])
            XCTAssertEqual(copied, expected["copied"] as? Int, name)
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.source_id,c.ord,c.text,e.embedding FROM source_chunks c
                LEFT JOIN chunk_embeddings e ON e.chunk_id=c.id AND e.generation_id=?
                ORDER BY c.source_id,c.ord
                """, arguments: [active.id])
            let unembedded = rows.filter { ($0["embedding"] as Data?) == nil }.map { [$0["source_id"] as Int64, $0["ord"] as Int64] }
            XCTAssertEqual(unembedded, try XCTUnwrap(expected["unembedded"] as? [[Int64]]), name)
            var byText: [Data: Data] = [:]
            for row in rows {
                guard let bytes = row["embedding"] as Data? else { continue }
                let text = Data((row["text"] as String).utf8)
                if let first = byText[text] { XCTAssertEqual(bytes, first, "copies are byte-equal: \(name)") } else { byText[text] = bytes }
            }
            let ledger = try Int.fetchOne(db, sql: "SELECT count(*) FROM generation_text_hashes WHERE generation_id=?", arguments: [active.id])
            XCTAssertEqual(ledger, progress.done, "every stored vector has a ledger row: \(name)")
        }
    }

    /// One published revision per source; chunk `ord` = index in the case.
    static func seed(_ store: NotebookStore, notebookId: Int64, sources: [[String: Any]]) throws {
        try store.runOnDatabase { db in
            for source in sources {
                let id = try XCTUnwrap(source["id"] as? Int), type = try XCTUnwrap(source["type"] as? String)
                let chunks = try XCTUnwrap(source["chunks"] as? [String])
                try db.execute(sql: """
                    INSERT INTO sources(id,notebook_id,type,title,status,ingested_at) VALUES (?,?,?,?,'ready','2026-10-11 00:00:00.000')
                    """, arguments: [id, notebookId, type, "source \(id)"])
                try db.execute(sql: """
                    INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES (?,1,?,?,1,2,'2026-10-11 00:00:00.000')
                    """, arguments: [id, "hash-\(id)", chunks.joined(separator: "\n\n")])
                let revision = db.lastInsertedRowID
                try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?", arguments: [revision, revision, id])
                for (ord, text) in chunks.enumerated() {
                    try db.execute(sql: """
                        INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id,char_start,char_end) VALUES (?,?,?,1,?,0,0)
                        """, arguments: [id, ord, text, revision])
                }
            }
        }
    }
}

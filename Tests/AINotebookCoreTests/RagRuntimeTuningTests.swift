import XCTest
@testable import AINotebookCore

private struct UnusedEmbedder: EmbeddingProducing {
    func embed(model: String, inputs: [String]) async throws -> [[Float]] { XCTFail("no embedding expected"); return [] }
}

private final class FetchKReads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.withLock { count } }
    func read() -> Int { lock.withLock { count += 1 }; return 48 }
}

final class RagRuntimeTuningTests: XCTestCase {
    func testDecisionParametersFromSharedCases() throws {
        let rows = try BenchmarkFixture.cases("benchmark-run-v1.json", kind: "tuning")
        XCTAssertEqual(rows.count, 8)
        for row in rows {
            let name = row["name"] as! String
            let bytes = try JSONSerialization.data(withJSONObject: row["input"]!)
            if row["error"] != nil {
                XCTAssertThrowsError(try RagRuntimeTuning.decodeDecision(bytes), name) {
                    XCTAssertEqual($0 as? RagTuningError, .invalidTuning, name)
                }
                continue
            }
            let value = try RagRuntimeTuning.decodeDecision(bytes)
            let expected = row["expected"] as! [String: Int]
            XCTAssertEqual(value.fetchK, expected["fetchK"], name)
            XCTAssertEqual(value.topK, expected["topK"], name)
            XCTAssertEqual(value.evidenceShareBp, expected["evidenceShareBp"], name)
        }
    }

    func testBundledAndV1EqualFrozenConstants() throws {
        let constants = try SharedFixtures.json("contracts/constants-v1.json")
        let retrieval = constants["retrieval"] as! [String: Any], pack = constants["pack"] as! [String: Any]
        XCTAssertEqual(RagRuntimeTuning.v1, try RagRuntimeTuning(fetchK: retrieval["fetchK"] as! Int,
                                                                 topK: retrieval["topK"] as! Int,
                                                                 evidenceShareBp: pack["evidenceShareBp"] as! Int))
        // Accepted runtime parameters must equal constants-v2 when it exists; otherwise v1.
        let v2 = SharedFixtures.url("contracts/constants-v2.json")
        let bundled = try RagRuntimeTuning.bundled()
        if FileManager.default.fileExists(atPath: v2.path) {
            let c2 = try SharedFixtures.json("contracts/constants-v2.json")
            let r2 = c2["retrieval"] as! [String: Any], p2 = c2["pack"] as! [String: Any]
            XCTAssertEqual(bundled, try RagRuntimeTuning(fetchK: r2["fetchK"] as! Int, topK: r2["topK"] as! Int,
                                                         evidenceShareBp: p2["evidenceShareBp"] as! Int))
        } else {
            XCTAssertEqual(bundled, .v1)
        }
    }

    func testInvalidConstructionAndDecodingNeverBypassValidation() throws {
        XCTAssertThrowsError(try RagRuntimeTuning(fetchK: 16, topK: 24, evidenceShareBp: 6000))
        XCTAssertThrowsError(try RagRuntimeTuning(fetchK: 32, topK: 0, evidenceShareBp: 6000))
        XCTAssertThrowsError(try RagRuntimeTuning(fetchK: 1025, topK: 16, evidenceShareBp: 6000))
        XCTAssertThrowsError(try RagRuntimeTuning(fetchK: 32, topK: 16, evidenceShareBp: -1))
        XCTAssertThrowsError(try JSONDecoder().decode(RagRuntimeTuning.self,
                                                      from: Data(#"{"fetchK":1,"topK":2,"evidenceShareBp":0}"#.utf8)))
        XCTAssertThrowsError(try ContextPackAlgorithms.budget(
            PackBudgetInput(runtimeContext: 100, maxOutputTokens: 10, mandatoryTokens: 1, evidenceBudgetCap: nil, topK: 1,
                            passages: [], mapTokensDesired: 0, noteWebTokensDesired: 0, historyTurnTokensNewestFirst: []),
            evidenceShareBp: 10_001))
    }

    func testTuningCannotCreateEvidenceAtZeroCap() throws {
        var input = try ContextPackFixtures.input("basic-cs")
        input.evidenceBudgetCap = 0
        let tuned = try RagRuntimeTuning(fetchK: 48, topK: 24, evidenceShareBp: 7000)
        let request = try ContextPackBuilder.build(input, estimator: PlaceholderTokenEstimatorV1(), tuning: tuned)
        XCTAssertTrue(request.citationMap.isEmpty)
        XCTAssertFalse(request.messages.flatMap(\.sections).contains { $0.kind == "evidence" })
    }

    func testSharedTuningBuilds() throws {
        let rows = try BenchmarkFixture.cases("benchmark-run-v1.json", kind: "tuning-build")
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            let name = row["name"] as! String
            let i = row["input"] as! [String: Any]
            XCTAssertEqual(i["estimatorVersion"] as? Int, 1)
            var input = try ContextPackFixtures.input(i["packFixture"] as! String)
            input.evidenceBudgetCap = i["evidenceBudgetCap"] as? Int
            let t = i["tuning"] as! [String: Int]
            let tuning = try RagRuntimeTuning(fetchK: t["fetchK"]!, topK: t["topK"]!, evidenceShareBp: t["evidenceShareBp"]!)
            let request = try ContextPackBuilder.build(input, estimator: PlaceholderTokenEstimatorV1(), tuning: tuning)
            let expected = row["expected"] as! [String: Any]
            XCTAssertEqual(try PreparedContextRequestJSON.object(request), expected["prepared"] as? NSDictionary, name)
            XCTAssertEqual(request.messages.flatMap(\.sections).filter { $0.kind == "evidence" }.count,
                           expected["evidenceSections"] as? Int, name)
        }
        // A different share changes only the evidence budget, never the v1 golden.
        let v1 = try ContextPackBuilder.build(try ContextPackFixtures.input("basic-cs"),
                                              estimator: PlaceholderTokenEstimatorV1(), tuning: .v1)
        let share6000 = try XCTUnwrap(rows.first { $0["name"] as? String == "tuning-share-6000" })
        XCTAssertEqual(try PreparedContextRequestJSON.object(v1),
                       (share6000["expected"] as! [String: Any])["prepared"] as? NSDictionary)
    }

    @MainActor func testOmittedFetchKUsesTuningOnceExplicitValueWins() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "tuning").id!
        for i in 0..<60 {
            let id = try store.createSource(notebookId: nb, type: .text, title: "s\(i)", uri: nil, rawPath: nil).id!
            let text = "needle \(i)"
            _ = try store.commitForegroundRevision(
                sourceId: id, draft: RevisionDraft(contentHash: "h\(i)", canonicalText: text, textFormatVersion: 1,
                                                   chunkerVersion: 2),
                chunks: ScalarChunker.chunk(text), now: 0, leaseToken: "t\(i)")
        }
        let reads = FetchKReads()
        let retriever = Retriever(store: store, client: UnusedEmbedder(), modelKey: { "m" }, cache: VectorMatrixCache(),
                                  tables: nil, hooks: RetrieverHooks(), defaultFetchK: { reads.read() })
        let omitted = try await retriever.search(notebookId: nb, query: "needle", scope: .all, includeVectors: false)
        XCTAssertEqual(omitted.lexical.count, 48)
        await omitted.close()
        let explicit = try await retriever.search(notebookId: nb, query: "needle", scope: .all, fetchK: 7, includeVectors: false)
        XCTAssertEqual(explicit.lexical.count, 7)
        await explicit.close()
        let empty = try await retriever.search(notebookId: nb, query: "needle",
                                               scope: .selection(sourceIds: [], folderIds: []))
        XCTAssertTrue(empty.fused.isEmpty)
        XCTAssertEqual(reads.reads, 1)
        do {
            _ = try await retriever.search(notebookId: nb, query: "needle", scope: .selection(sourceIds: [], folderIds: []),
                                           fetchK: 0)
            XCTFail("nonpositive fetchK accepted")
        } catch { XCTAssertEqual(error as? RetrievalError, .invalidFetchK) }
    }
}

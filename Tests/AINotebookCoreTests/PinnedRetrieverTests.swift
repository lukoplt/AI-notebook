import XCTest
import GRDB
@testable import AINotebookCore

private actor WP5CountingEmbedder: EmbeddingProducing {
    var calls = 0
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        calls += 1; return [[1,0]]
    }
}

/// Returns a scripted reply, optionally pausing until the test resumes it.
private actor WP5ScriptedEmbedder: EmbeddingProducing {
    enum Reply: Sendable { case vectors([[Float]]), failure(any Error) }
    private let reply: Reply
    private let pauses: Bool
    private(set) var calls = 0
    private(set) var models: [String] = []
    private var pending: CheckedContinuation<Void, Never>?
    private var started: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(_ reply: Reply, pauses: Bool = false) { self.reply = reply; self.pauses = pauses }
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        calls += 1; models.append(model)
        if pauses && !released {
            await withCheckedContinuation { continuation in
                pending = continuation
                started.forEach { $0.resume() }; started.removeAll()
            }
        }
        switch reply {
        case let .vectors(values): return values
        case let .failure(error): throw error
        }
    }
    func waitUntilSuspended() async {
        if pending != nil { return }
        await withCheckedContinuation { started.append($0) }
    }
    func resume() { released = true; pending?.resume(); pending = nil }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private enum WP5ProviderFailure: Error { case unavailable }

@MainActor final class PinnedRetrieverTests: XCTestCase {
    func testNoActiveGenerationIsLexicalOnly() async throws {
        let store = try RetrievalFixtureStore.make("no-active")
        let client = WP5CountingEmbedder()
        let retriever = Retriever(store: store, client: client, model: "m")
        let pool = try await retriever.search(notebookId: 1, query: "needle", scope: .all, fetchK: 2)
        XCTAssertEqual(pool.fused.map { $0.reference.chunkId }.sorted(), [1020,4010])
        XCTAssertTrue(pool.vector.isEmpty)
        XCTAssertEqual(pool.diagnostics.vectorStatus, "noActiveGeneration")
        XCTAssertTrue(pool.fused.allSatisfy { $0.generationId == nil })
        let calls = await client.calls
        XCTAssertEqual(calls, 0)
        await pool.close()
    }

    func testEmptyScopeDoesNothing() async throws {
        let store = try RetrievalFixtureStore.make()
        let client = WP5CountingEmbedder()
        let retriever = Retriever(store: store, client: client, modelKey: { fatalError("empty scope read model settings") })
        let pool = try await retriever.search(notebookId: 1, query: "needle",
            scope: .selection(sourceIds: [], folderIds: []), fetchK: 32)
        XCTAssertTrue(pool.fused.isEmpty)
        XCTAssertNil(pool.snapshot)
        XCTAssertEqual(RetrievalFixtureStore.sqlStatementCount(store),0)
        let calls = await client.calls
        XCTAssertEqual(calls,0)
        await pool.close()
    }

    func testPerBranchFetchKAndIntegerPool() async throws {
        let store = try RetrievalFixtureStore.make()
        let client = WP5CountingEmbedder()
        let retriever = Retriever(store: store, client: client, model: "m")
        let one = try await retriever.search(notebookId: 1, query: "needle", scope: .all, fetchK: 1)
        XCTAssertEqual(one.lexical.map(\.reference.chunkId), [1020])
        XCTAssertEqual(one.vector.map(\.reference.chunkId), [1010])
        XCTAssertEqual(one.lexical.map(\.rrfMicro), [16393])
        XCTAssertEqual(one.vector.map(\.rrfMicro), [16393])
        XCTAssertEqual(one.fused.map(\.reference.chunkId), [1010, 1020])
        XCTAssertEqual(one.fused.map(\.rrfMicro), [16393, 16393])
        XCTAssertEqual(one.diagnostics.vectorStatus, "legacyEndpointUnverified")
        await one.close()

        let two = try await retriever.search(notebookId: 1, query: "needle", scope: .all, fetchK: 2)
        XCTAssertEqual(two.lexical.map(\.reference.chunkId), [1020, 4010])
        XCTAssertEqual(two.vector.map(\.reference.chunkId), [1010, 4010])
        XCTAssertEqual(two.fused.map(\.reference.chunkId), [4010, 1010, 1020])
        XCTAssertEqual(two.fused.map(\.rrfMicro), [32258, 16393, 16393])
        XCTAssertLessThanOrEqual(two.fused.count, 4)
        let reference = try RetrievalRanking.fuse(lexical: two.lexical.map(\.reference), vector: two.vector.map(\.reference))
        XCTAssertEqual(two.fused.map(\.reference), reference.map(\.reference))
        XCTAssertEqual(two.fused.map(\.rrfMicro), reference.map(\.rrfMicro))
        XCTAssertTrue((two.lexical + two.vector + two.fused).allSatisfy { $0.generationId == 90 })
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: two.fused.map { ($0.reference.chunkId, $0.reference.revisionId) }),
                       [1010: 101, 1020: 102, 4010: 401])
        await two.close()

        // Cached and streamed scans share one heap and agree exactly.
        var results: [[PinnedRetrievalCandidate]] = []
        for budget: Int64 in [0, 160] {
            let isolated = Retriever(store: store, client: client, modelKey: { "m" }, cache: VectorMatrixCache(budgetBytes: budget))
            let pool = try await isolated.search(notebookId: 1, query: "needle", scope: .all, fetchK: 2)
            XCTAssertEqual(pool.diagnostics.streamed, budget == 0)
            XCTAssertLessThanOrEqual(pool.diagnostics.peakPageBytes, 8_388_608)
            XCTAssertEqual(pool.diagnostics.invalidVectorCount, 0)
            results.append(pool.vector)
            await pool.close()
        }
        XCTAssertEqual(results[0], results[1])

        let folder = try await retriever.search(notebookId: 1, query: "needle",
            scope: .selection(sourceIds: [], folderIds: [10]), fetchK: 4)
        XCTAssertEqual(folder.lexical.map(\.reference.chunkId), [1020])
        XCTAssertEqual(folder.vector.map(\.reference.chunkId), [1010])
        await folder.close()
    }

    func testOneGenerationAndModelReadAcrossAwait() async throws {
        for name in ["switch-during-query", "publish-during-query"] {
            let fixture = try XCTUnwrap(RetrievalFixtureStore.cases().first { $0["name"] as? String == name })
            let store = try RetrievalFixtureStore.make()
            let client = WP5ScriptedEmbedder(.vectors([[1, 0]]), pauses: true)
            let reads = CallCounter()
            let retriever = Retriever(store: store, client: client, modelKey: { reads.increment(); return "m" })
            let query = Task { try await retriever.search(notebookId: 1, query: "needle", scope: .all, fetchK: 4) }
            await client.waitUntilSuspended()
            try RetrievalFixtureStore.applyEvent(name, to: store)
            await client.resume()
            let pool = try await query.value
            XCTAssertEqual(reads.count, 1, name)
            XCTAssertEqual(pool.snapshot?.pin.generationId, 90, name)
            XCTAssertTrue((pool.lexical + pool.vector + pool.fused).allSatisfy { $0.generationId == 90 }, name)
            XCTAssertEqual(pool.lexical.map(\.reference.chunkId).sorted(), ids(fixture, "afterPublishedChunkIds"), name)
            XCTAssertEqual(pool.vector.map(\.reference.chunkId).sorted(), ids(fixture, "afterVectorChunkIds"), name)
            XCTAssertEqual(pool.lexical.first { $0.reference.sourceId == 1 }?.reference.revisionId, 102, name)
            XCTAssertEqual(pool.vector.first { $0.reference.sourceId == 1 }?.reference.revisionId, 101, name)
            let models = await client.models
            XCTAssertEqual(models, ["m"], name)
            await pool.close()
        }
    }

    func testRevocationBeforeReturnRemovesStaleHits() async throws {
        for name in ["revoke-availability", "revoke-eligible", "revoke-membership", "join-membership"] {
            let fixture = try XCTUnwrap(RetrievalFixtureStore.cases().first { $0["name"] as? String == name })
            let scope = try JSONDecoder().decode(RetrievalScope.self,
                from: JSONSerialization.data(withJSONObject: fixture["scope"]!))
            let store = try RetrievalFixtureStore.make()
            let passes = CallCounter()
            let hooks = RetrieverHooks(afterPass: { pass in
                passes.increment()
                guard pass == 1 else { return }
                await MainActor.run { try! RetrievalFixtureStore.applyEvent(name, to: store) }
            })
            let retriever = Retriever(store: store, client: WP5CountingEmbedder(), modelKey: { "m" },
                                      cache: VectorMatrixCache(budgetBytes: 0), tables: nil, hooks: hooks)
            let pool = try await retriever.search(notebookId: 1, query: "needle", scope: scope, fetchK: 1)
            let lexical = pool.lexical.map(\.reference.chunkId), vector = pool.vector.map(\.reference.chunkId)
            let afterLexical = ids(fixture, "afterPublishedChunkIds"), afterVector = ids(fixture, "afterVectorChunkIds")
            if name == "join-membership" {
                // A newly joined source never enters the running turn.
                XCTAssertEqual(lexical, afterLexical, name)
                XCTAssertEqual(vector, afterVector, name)
                XCTAssertEqual(passes.count, 1, name)
            } else {
                // The shrunken mask re-runs both branches, so the next valid hit
                // surfaces instead of an empty result filtered after top-K.
                XCTAssertEqual(lexical, Array(afterLexical.prefix(1)), name)
                XCTAssertEqual(vector, Array(afterVector.prefix(1)), name)
                XCTAssertFalse((pool.lexical + pool.vector + pool.fused).contains { $0.reference.sourceId == 1 }, name)
                XCTAssertEqual(passes.count, 2, name)
            }
            await pool.close()
        }
    }

    func testEmbeddingFailureFallsBackButCancellationThrows() async throws {
        let store = try RetrievalFixtureStore.make()
        let failing = WP5ScriptedEmbedder(.failure(WP5ProviderFailure.unavailable))
        let pool = try await Retriever(store: store, client: failing, model: "m")
            .search(notebookId: 1, query: "needle", scope: .all, fetchK: 4)
        XCTAssertEqual(pool.lexical.map(\.reference.chunkId), [1020, 4010])
        XCTAssertTrue(pool.vector.isEmpty)
        XCTAssertEqual(pool.diagnostics.vectorStatus, "embeddingFailed")
        await pool.close()
        // The legacy chat adapter keeps WP3's contract: a provider failure propagates.
        do {
            _ = try await Retriever(store: store, client: failing, model: "m").search(notebookId: 1, query: "needle")
            XCTFail("Legacy search swallowed a provider failure")
        } catch { XCTAssertTrue(error is WP5ProviderFailure) }

        let cancelling = WP5ScriptedEmbedder(.failure(CancellationError()))
        do {
            _ = try await Retriever(store: store, client: cancelling, model: "m")
                .search(notebookId: 1, query: "needle", scope: .all, fetchK: 4)
            XCTFail("Cancellation became lexical success")
        } catch { XCTAssertTrue(error is CancellationError) }

        // A modern generation without a session-capable client stays lexical-only.
        try store.runOnDatabase { db in
            try db.execute(sql: """
                UPDATE index_generations SET provider_id='provider-a',endpoint_revision='fixture',
                  query_format_version='1' WHERE id=90
                """)
        }
        let direct = WP5CountingEmbedder()
        let modern = try await Retriever(store: store, client: direct, model: "provider-a:m")
            .search(notebookId: 1, query: "needle", scope: .all, fetchK: 4)
        XCTAssertEqual(modern.diagnostics.vectorStatus, "embeddingSessionRequired")
        XCTAssertEqual(modern.lexical.map(\.reference.chunkId), [1020, 4010])
        XCTAssertTrue(modern.vector.isEmpty)
        let directCalls = await direct.calls
        XCTAssertEqual(directCalls, 0)
        await modern.close()

        // No error path leaked a pin: the retired generation's revision is collected.
        try assertNoLeakedPin(store)
    }

    func testLegacyAndEvalAdapters() async throws {
        let store = try RetrievalFixtureStore.make()
        let retriever = Retriever(store: store, client: WP5CountingEmbedder(), model: "m")
        let legacy = try await retriever.search(notebookId: 1, query: "needle", topK: 8, sourceIds: [])
        XCTAssertEqual(legacy.map(\.chunkId), [4010, 1010, 1020])
        XCTAssertEqual(legacy.map(\.sourceId), [4, 1, 1])
        XCTAssertEqual(legacy.map(\.score), [Float(32258) / 1_000_000, Float(16393) / 1_000_000, Float(16393) / 1_000_000])
        XCTAssertEqual(legacy.map(\.snippet), ["needle revision 401", "needle revision 101", "needle revision 102"])
        let topOne = try await retriever.search(notebookId: 1, query: "needle", topK: 1)
        XCTAssertEqual(topOne.map(\.chunkId), [1010])
        let scoped = try await retriever.search(notebookId: 1, query: "needle", topK: 8, sourceIds: [4])
        XCTAssertEqual(scoped.map(\.chunkId), [4010])

        let none = try await retriever.candidates(notebookId: 1, query: "needle", sourceIds: [])
        XCTAssertEqual(none, RetrievalCandidates(lexical: [], vector: [], fused: []))
        let all = try await retriever.candidates(notebookId: 1, query: "needle", fetchK: 2, sourceIds: nil)
        XCTAssertEqual(all.lexical.map(\.chunkId), [1020, 4010])
        XCTAssertEqual(all.vector.map(\.chunkId), [1010, 4010])
        XCTAssertEqual(all.fused.map(\.chunkId), [4010, 1010, 1020])
        XCTAssertEqual(all.fused.map(\.snippet), ["needle revision 401", "needle revision 101", "needle revision 102"])
        let lexicalOnly = try await retriever.candidates(notebookId: 1, query: "needle", fetchK: 2, includeVectors: false)
        XCTAssertTrue(lexicalOnly.vector.isEmpty)
        XCTAssertEqual(lexicalOnly.fused.map(\.chunkId), [1020, 4010])
        let selected = try await retriever.candidates(notebookId: 1, query: "needle", fetchK: 2, sourceIds: [4])
        XCTAssertEqual(selected.fused.map(\.chunkId), [4010])

        // Display snippets are 240 Unicode scalars of the revision's own text.
        let long = try NotebookStore(path: .inMemory)
        let notebook = try long.createNotebook(name: "snippets").id!
        let source = try long.createSource(notebookId: notebook, type: .text, title: "long", uri: nil, rawPath: nil).id!
        try long.replaceChunks(sourceId: source, chunks: [ChunkDraft(text: "needle " + String(repeating: "😀", count: 300), tokenCount: 2)])
        let hits = try await Retriever(store: long, client: WP5CountingEmbedder(), model: "m")
            .search(notebookId: notebook, query: "needle")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.snippet.unicodeScalars.count, 240)
        XCTAssertEqual(hits.first?.snippet, "needle " + String(repeating: "😀", count: 233))

        try assertNoLeakedPin(store)
    }

    func testInvalidLimitsAndMalformedQueryVector() async throws {
        let store = try RetrievalFixtureStore.make()
        let counting = WP5CountingEmbedder()
        let strict = Retriever(store: store, client: counting, modelKey: { fatalError("invalid fetchK read model settings") })
        for fetchK in [0, -1] {
            do {
                _ = try await strict.search(notebookId: 1, query: "needle", scope: .all, fetchK: fetchK)
                XCTFail("fetchK \(fetchK) accepted")
            } catch { XCTAssertEqual(error as? RetrievalError, .invalidFetchK) }
        }
        do {
            _ = try await strict.candidates(notebookId: 1, query: "needle", fetchK: 0)
            XCTFail("candidates fetchK 0 accepted")
        } catch { XCTAssertEqual(error as? EvalFailure, EvalFailure("invalid_fetch_k")) }
        XCTAssertEqual(RetrievalFixtureStore.sqlStatementCount(store), 0)
        let countingCalls = await counting.calls
        XCTAssertEqual(countingCalls, 0)

        let malformed: [[[Float]]] = [[[1, 0, 0]], [[0, 0]], [[.nan, 0]], [], [[1, 0], [1, 0]], [[]]]
        for reply in malformed {
            let client = WP5ScriptedEmbedder(.vectors(reply))
            let retriever = Retriever(store: store, client: client, model: "m")
            let pool = try await retriever.search(notebookId: 1, query: "needle", scope: .all, fetchK: 4)
            XCTAssertEqual(pool.diagnostics.vectorStatus, "invalidQueryVector", "\(reply)")
            XCTAssertEqual(pool.lexical.map(\.reference.chunkId), [1020, 4010], "\(reply)")
            XCTAssertTrue(pool.vector.isEmpty, "\(reply)")
            await pool.close()
            do {
                _ = try await retriever.candidates(notebookId: 1, query: "needle", fetchK: 4)
                XCTFail("Eval accepted malformed query vector \(reply)")
            } catch { XCTAssertEqual(error as? EvalFailure, EvalFailure("invalid_embedding")) }
        }
        // The WP7 seam validates a pre-embedded vector the same way.
        let snapshot = try XCTUnwrap(ScopeResolver.resolve(store: store, notebookId: 1, scope: .all, modelKey: "m"))
        let seam = try await Retriever(store: store, client: counting, model: "m")
            .searchEmbedded(snapshot: snapshot, query: "needle", queryVector: [0, 0], fetchK: 4)
        XCTAssertEqual(seam.diagnostics.vectorStatus, "invalidQueryVector")
        XCTAssertEqual(seam.lexical.map(\.reference.chunkId), [1020, 4010])
        await seam.close()

        // Oversized generation metadata: no embedding request and no vector BLOB read.
        let rank = try SharedFixtures.json("contracts/retrieval-rank-v1.json")
        let oversized = try XCTUnwrap((rank["cases"] as! [[String: Any]]).first { $0["name"] as? String == "oversized-generation" })
        let large = try RetrievalFixtureStore.make()
        try large.runOnDatabase { db in
            try db.execute(sql: "UPDATE index_generations SET dims=? WHERE id=90", arguments: [oversized["dims"] as! Int])
        }
        let blobReads = CallCounter()
        try large.runOnDatabase { db in
            db.trace { event in if event.description.contains("chunk_embeddings") { blobReads.increment() } }
        }
        let client = WP5CountingEmbedder()
        let pool = try await Retriever(store: large, client: client, model: "m")
            .search(notebookId: 1, query: "needle", scope: .all, fetchK: 4)
        XCTAssertEqual(pool.diagnostics.vectorStatus, oversized["expectedStatus"] as? String)
        XCTAssertEqual(pool.lexical.map(\.reference.chunkId), [1020, 4010])
        XCTAssertTrue(pool.vector.isEmpty)
        await pool.close()
        let calls = await client.calls
        XCTAssertEqual(calls, oversized["expectedEmbeddingCalls"] as? Int)
        XCTAssertEqual(blobReads.count, oversized["expectedBlobReads"] as? Int)
    }

    // MARK: - Helpers

    private func ids(_ fixture: [String: Any], _ key: String) -> [Int64] {
        (fixture[key] as! [NSNumber]).map(\.int64Value)
    }

    /// Retiring the fixture generation and collecting removes revision 101 only
    /// when no query pin (pool, operation or snippet borrow) is still registered.
    private func assertNoLeakedPin(_ store: NotebookStore, file: StaticString = #filePath, line: UInt = #line) throws {
        try store.retireGeneration(id: 90)
        _ = try store.garbageCollect(notebookId: 1)
        try store.runOnDatabase { db in
            XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT id FROM source_revisions WHERE id=101"), file: file, line: line)
            XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT id FROM index_generations WHERE id=90"), file: file, line: line)
        }
    }
}

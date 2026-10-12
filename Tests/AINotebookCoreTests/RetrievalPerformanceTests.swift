import CryptoKit
import XCTest
import GRDB
@testable import AINotebookCore

private enum PerfFixtureError: Error { case embedding, hydration }

@MainActor final class RetrievalPerformanceTests: XCTestCase {
    func testSharedSyntheticRows() throws {
        let f=try SharedFixtures.json("contracts/retrieval-perf-v1.json")
        let c=(f["cases"] as! [[String:Any]]).first { $0["name"] as? String == "small" }!
        var bytes = Data()
        for (i,r) in (c["rows"] as! [[String:Any]]).enumerated() {
            let row=SyntheticRetrievalCorpus.row(index:i,dims:c["dims"] as! Int,seed:c["seed"] as! Int)
            XCTAssertEqual(row.text,r["text"] as? String)
            XCTAssertEqual(row.vector,(r["vector"] as! [NSNumber]).map(\.floatValue))
            XCTAssertEqual(row.chunkId,Int64(i+1)); XCTAssertEqual(row.ord,i%100)
            XCTAssertEqual(row.sourceId,(r["sourceId"] as! NSNumber).int64Value)
            for value in row.vector { withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) } }
        }
        XCTAssertEqual(c["count"] as? Int, 8)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                       c["expectedVectorBytesSha256"] as? String)
    }

    func testTimingExcludesEmbeddingFromWarmRetrieval() async throws {
        let f=try SharedFixtures.json("contracts/retrieval-perf-v1.json")
        let c=(f["cases"] as! [[String:Any]]).first { $0["name"] as? String == "timing" }!
        let store=try RetrievalFixtureStore.make("no-active")
        let snapshot=try XCTUnwrap(ScopeResolver.resolve(store:store,notebookId:1,scope:.all,modelKey:"m"))
        let retriever=Retriever(store:store,client:WP5PerfEmbedder(),model:"m")
        var times:[UInt64]=(c["clockTicks"] as! [NSNumber]).map(\.uint64Value)
        var hydrated:[Int64]=[]
        let sample=try await RetrievalPerformance.measure(snapshot:snapshot,embedding:{ [1,0] },
            retrieval:{ vector in try await retriever.searchEmbedded(snapshot:snapshot,query:"needle",queryVector:vector) },
            hydration:{ pool in
                hydrated = try await EvidenceHydrator(reader:store.makeRetrievalReader()).hydrate(
                    pool.snapshot!,references:pool.fused.map(\.reference),neighborRadius:0).map(\.reference.chunkId)
            },ticksPerSecond:(c["frequency"] as! NSNumber).uint64Value,now:{ times.removeFirst() })
        XCTAssertEqual(sample.queryEmbeddingMs,(c["queryEmbeddingMs"] as! NSNumber).doubleValue)
        XCTAssertEqual(sample.warmRetrievalMs,(c["warmRetrievalMs"] as! NSNumber).doubleValue)
        XCTAssertEqual(sample.hydrationMs,(c["hydrationMs"] as! NSNumber).doubleValue)
        XCTAssertEqual(sample.endToEndMs, sample.queryEmbeddingMs + sample.warmRetrievalMs + sample.hydrationMs)
        XCTAssertTrue(times.isEmpty)
        XCTAssertEqual(hydrated.sorted(), [1020, 4010])
        try assertNoLeakedPin(store)
    }

    func testGeneratedStoreTraversesProductionRetrieval() async throws {
        let store = try NotebookStore(path: .inMemory)
        let handle = try SyntheticRetrievalCorpus.populate(store: store, chunkCount: 1000, dims: 16)
        XCTAssertEqual(handle.chunkCount, 1000)
        XCTAssertEqual(handle.dims, 16)
        XCTAssertEqual(try store.activeGeneration(notebookId: handle.notebookId)?.id, handle.generationId)
        let logical = try store.runOnDatabase { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id,c.source_id,c.ord,c.text FROM source_chunks c JOIN sources s ON s.id=c.source_id
                WHERE s.notebook_id=? ORDER BY c.source_id,c.ord
                """, arguments: [handle.notebookId])
        }
        XCTAssertEqual(logical.count, 1000)
        for index in [0, 99, 100, 999] {
            XCTAssertEqual(logical[index]["text"] as String, SyntheticRetrievalCorpus.row(index: index, dims: 16).text)
            XCTAssertEqual(logical[index]["ord"] as Int, index % 100)
        }
        let ids = logical.map { $0["id"] as Int64 }
        let probe = 123
        let query = SyntheticRetrievalCorpus.row(index: probe, dims: 16).vector
        let expected = Array(ids.indices.filter { $0 % 16 == probe % 16 }.map { ids[$0] }.prefix(8))

        let cache = VectorMatrixCache()
        var runs: [(ids: [Int64], diagnostics: RetrievalDiagnostics)] = []
        for budget in [nil, nil, Int64(0)] as [Int64?] {
            let retriever = Retriever(store: store, client: WP5PerfEmbedder(), modelKey: { "synthetic" },
                                      cache: budget.map { VectorMatrixCache(budgetBytes: $0) } ?? cache)
            let snapshot = try XCTUnwrap(ScopeResolver.resolve(store: store, notebookId: handle.notebookId,
                                                               scope: .all, modelKey: "synthetic"))
            let pool = try await retriever.searchEmbedded(snapshot: snapshot, query: "needle\(probe % 97)",
                                                          queryVector: query, fetchK: 8)
            runs.append((pool.vector.map(\.reference.chunkId), pool.diagnostics))
            XCTAssertTrue(pool.lexical.allSatisfy { ids.firstIndex(of: $0.reference.chunkId)! % 97 == probe % 97 })
            await pool.close()
        }
        XCTAssertEqual(runs[0].ids, expected)
        XCTAssertEqual(runs[1].ids, expected)
        XCTAssertEqual(runs[2].ids, expected)
        XCTAssertEqual(runs.map(\.diagnostics.streamed), [false, false, true])
        XCTAssertEqual(runs.map(\.diagnostics.vectorStatus), ["used", "used", "used"])
        XCTAssertTrue(runs.allSatisfy { $0.diagnostics.peakPageBytes > 0 && $0.diagnostics.peakPageBytes <= 8_388_608 })
        let warm = await cache.statistics()
        XCTAssertEqual(warm.loadCount, 1, "second query must reuse the warm matrix")
        // retrieval-resident-v1 §4: binary16 rows plus 32 bytes of row metadata.
        XCTAssertEqual(warm.residentBytes, Int64(1000 * (16 * 2 + 32)))

        // Query scope masks before the heap: a revoked source cannot occupy top-K.
        let firstSource = logical[0]["source_id"] as Int64
        try store.runOnDatabase { db in
            try db.execute(sql: "UPDATE sources SET availability='missing' WHERE id=?", arguments: [firstSource])
        }
        let snapshot = try XCTUnwrap(ScopeResolver.resolve(store: store, notebookId: handle.notebookId,
                                                           scope: .all, modelKey: "synthetic"))
        let revoked = try await Retriever(store: store, client: WP5PerfEmbedder(), modelKey: { "synthetic" }, cache: cache)
            .searchEmbedded(snapshot: snapshot, query: "needle", queryVector: query, fetchK: 8)
        let survivors = Array(ids.indices.filter { $0 >= 100 && $0 % 16 == probe % 16 }.map { ids[$0] }.prefix(8))
        XCTAssertEqual(revoked.vector.map(\.reference.chunkId), survivors)
        XCTAssertFalse(revoked.fused.contains { $0.reference.sourceId == firstSource })
        await revoked.close()

        for (count, dims) in [(0, 16), (-1, 16), (10, 0), (10, 2_097_153)] {
            XCTAssertThrowsError(try SyntheticRetrievalCorpus.populate(store: store, chunkCount: count, dims: dims)) {
                XCTAssertEqual($0 as? RetrievalError, .invalidMeasurementInput)
            }
        }
    }

    func testPercentileAndFailureClosesPool() async throws {
        XCTAssertEqual(RetrievalPerformance.percentile95((1...200).map(Double.init)), 190)
        XCTAssertEqual(RetrievalPerformance.percentile95([7]), 7)
        XCTAssertEqual(RetrievalPerformance.percentile95([3, 1, 2]), 3)

        for failure in ["embedding", "hydration", "clock", "frequency"] {
            let store = try RetrievalFixtureStore.make()
            let snapshot = try XCTUnwrap(ScopeResolver.resolve(store: store, notebookId: 1, scope: .all, modelKey: "m"))
            let retriever = Retriever(store: store, client: WP5PerfEmbedder(), model: "m")
            var ticks: [UInt64] = failure == "clock" ? [10, 5, 20, 30] : [1, 2, 3, 4]
            do {
                _ = try await RetrievalPerformance.measure(snapshot: snapshot,
                    embedding: {
                        if failure == "embedding" { throw PerfFixtureError.embedding }
                        return [1, 0]
                    },
                    retrieval: { vector in
                        try await retriever.searchEmbedded(snapshot: snapshot, query: "needle", queryVector: vector)
                    },
                    hydration: { _ in if failure == "hydration" { throw PerfFixtureError.hydration } },
                    ticksPerSecond: failure == "frequency" ? 0 : 1000, now: { ticks.removeFirst() })
                XCTFail("\(failure) measurement succeeded")
            } catch {
                switch failure {
                case "embedding": XCTAssertEqual(error as? PerfFixtureError, .embedding)
                case "hydration": XCTAssertEqual(error as? PerfFixtureError, .hydration)
                default: XCTAssertEqual(error as? RetrievalError, .invalidMeasurementInput, failure)
                }
            }
            XCTAssertThrowsError(try snapshot.acquireOperation(), failure)
            try assertNoLeakedPin(store)
        }
    }

    func testLargeCorpusSpecification() throws {
        let f=try SharedFixtures.json("contracts/retrieval-perf-v1.json")
        let cases = f["cases"] as! [[String: Any]]
        XCTAssertEqual(Set(f["scenarios"] as! [String]), ["concurrent-ingestion", "streaming-budget", "warm-cache"])
        for (name, count) in [("large100k", 100_000), ("large200k", 200_000)] {
            let c = try XCTUnwrap(cases.first { $0["name"] as? String == name })
            XCTAssertEqual(c["count"] as? Int, count)
            XCTAssertEqual(c["dims"] as? Int, 256)
            let seed = c["seed"] as! Int
            let index = count - 1
            let row = SyntheticRetrievalCorpus.row(index: index, dims: 256, seed: seed)
            XCTAssertEqual(row.chunkId, Int64(count))
            XCTAssertEqual(row.sourceId, Int64(1 + index / 100))
            XCTAssertEqual(row.ord, index % 100)
            XCTAssertEqual(row.text, "synthetic \(index) needle\(index % 97)")
            XCTAssertEqual(row.vector.count, 256)
            XCTAssertEqual(row.vector.firstIndex(of: 1), (index + seed) % 256)
            XCTAssertEqual(row.vector.reduce(0, +), 1)
        }
    }

    private func assertNoLeakedPin(_ store: NotebookStore, file: StaticString = #filePath, line: UInt = #line) throws {
        try store.retireGeneration(id: 90)
        _ = try store.garbageCollect(notebookId: 1)
        try store.runOnDatabase { db in
            XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT id FROM source_revisions WHERE id=101"), file: file, line: line)
        }
    }
}

private struct WP5PerfEmbedder: EmbeddingProducing {
    func embed(model:String,inputs:[String]) async throws -> [[Float]] { [[1,0]] }
}

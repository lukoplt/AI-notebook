import XCTest
@testable import AINotebookCore

@MainActor final class VectorMatrixCacheTests: XCTestCase {
    func testLeasedBytesRemainCharged() async throws {
        let f = try SharedFixtures.json("contracts/retrieval-cache-v1.json")
        let cache = VectorMatrixCache(budgetBytes: Int64(f["budgetBytes"] as! Int))
        let rows = (1...2).map { i in VectorRow(reference: .init(chunkId: Int64(i), sourceId: 1, revisionId: 1, ord: i-1), values: [1,0]) }
        func key(_ id: Int64) -> RetrievalCacheKey { .init(databaseId: "db", notebookId: id, generationId: 90, epoch: 0) }
        let first = try await cache.acquire(key: key(1), rowCount: 2, dims: 2, epoch: { 0 }, load: { rows })
        let second = try await cache.acquire(key: key(2), rowCount: 2, dims: 2, epoch: { 0 }, load: { rows })
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        await cache.invalidate(databaseId: "db")
        XCTAssertEqual(first?.topK(query: [1, 0], permittedSources: [1], k: 2).map { $0.reference.chunkId }, [1, 2])
        let blocked = try await cache.acquire(key: key(3), rowCount: 2, dims: 2, epoch: { 0 }, load: { rows })
        XCTAssertNil(blocked)
        let held = await cache.statistics()
        XCTAssertEqual(held.residentBytes, 160)
        await first?.close(); await second?.close()
        let released = await cache.statistics()
        XCTAssertEqual(released.residentBytes, 0)
    }

    func testCacheCaseTable() async throws {
        let fixture = try SharedFixtures.json("contracts/retrieval-cache-v1.json")
        let keys = fixture["keys"] as! [String: [String: Any]]
        func key(_ name: String) -> RetrievalCacheKey {
            let row = keys[name]!
            return .init(databaseId: row["databaseId"] as! String,
                notebookId: (row["notebookId"] as! NSNumber).int64Value,
                generationId: (row["generationId"] as! NSNumber).int64Value,
                epoch: (row["epoch"] as! NSNumber).uint64Value)
        }
        let namesByDatabase = Dictionary(uniqueKeysWithValues: keys.map { ($0.value["databaseId"] as! String, $0.key) })
        let dims = fixture["dims"] as! Int
        for c in fixture["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let cache = VectorMatrixCache(budgetBytes: (fixture["budgetBytes"] as! NSNumber).int64Value)
            var leases: [String: VectorMatrixLease] = [:]
            var pending: [String: Task<VectorMatrixLease?, Error>] = [:]
            var pendingBarrier: [String: String] = [:]
            var barriers: [String: CacheBarrier] = [:]
            var pendingKey: [String: RetrievalCacheKey] = [:]
            for action in c["actions"] as! [[String: Any]] {
                let operation = action["op"] as! String
                switch operation {
                case "acquire":
                    let rows = cacheRows(action["rows"] as! Int, dims: dims)
                    let lease = try await cache.acquire(key: key(action["key"] as! String), rowCount: rows.count,
                        dims: dims, epoch: { 0 }, load: { rows })
                    XCTAssertEqual(lease == nil ? "stream" : "cached", action["expectedMode"] as? String, name)
                    leases[action["lease"] as! String] = lease
                case "release":
                    let lease = leases.removeValue(forKey: action["lease"] as! String)
                    await lease?.close()
                    await lease?.close() // Closing an already released lease cannot debit twice.
                case "invalidate": await cache.invalidate(databaseId: key(action["key"] as! String).databaseId)
                case "startAcquire":
                    let label = action["lease"] as! String, barrierName = action["barrier"] as! String
                    let barrier = barriers[barrierName] ?? CacheBarrier()
                    barriers[barrierName] = barrier
                    let rows = cacheRows(action["rows"] as! Int, dims: dims), cacheKey = key(action["key"] as! String)
                    pendingBarrier[label] = barrierName
                    pendingKey[label] = cacheKey
                    pending[label] = Task {
                        try await cache.acquire(key: cacheKey, rowCount: rows.count, dims: dims, epoch: { 0 }, load: {
                            try await barrier.pause()
                            return rows
                        })
                    }
                    await barrier.waitStarted()
                    await cache.waitForWaiters(key: cacheKey, count: pendingKey.values.filter { $0 == cacheKey }.count)
                case "completeFill", "failFill":
                    let barrierName = action["barrier"] as! String
                    await barriers[barrierName]!.finish(failing: operation == "failFill")
                    for label in pendingBarrier.keys.sorted() where pendingBarrier[label] == barrierName {
                        do {
                            let lease = try await pending.removeValue(forKey: label)!.value
                            XCTAssertNil(action["expectedError"], name)
                            XCTAssertEqual(lease == nil ? "stream" : "cached", action["expectedMode"] as? String, name)
                            leases[label] = lease
                        } catch {
                            XCTAssertEqual(error as? CacheTestError, .loadFailed, name)
                            XCTAssertEqual(action["expectedError"] as? String, "loadFailed", name)
                        }
                        pendingKey.removeValue(forKey: label)
                        pendingBarrier.removeValue(forKey: label)
                    }
                default: XCTFail("Unhandled action \(operation)")
                }
                let expected = action["expected"] as! [String: Any]
                let statistics = await cache.statistics()
                XCTAssertEqual(statistics.residentBytes, (expected["residentBytes"] as! NSNumber).int64Value, name + operation)
                XCTAssertEqual(statistics.reservedBytes, (expected["reservedBytes"] as! NSNumber).int64Value, name + operation)
                XCTAssertEqual(statistics.entryCount, expected["entryCount"] as! Int, name + operation)
                XCTAssertEqual(statistics.loadCount, expected["loadCount"] as! Int, name + operation)
                let resident = await cache.residentKeys()
                XCTAssertEqual(resident.compactMap { namesByDatabase[$0.databaseId] }, expected["residentKeys"] as! [String], name + operation)
                XCTAssertLessThanOrEqual(statistics.residentBytes + statistics.reservedBytes,
                    (fixture["budgetBytes"] as! NSNumber).int64Value)
            }
            for lease in leases.values { await lease.close() }
            for row in keys.values { await cache.invalidate(databaseId: row["databaseId"] as! String) }
            let final = await cache.statistics()
            XCTAssertEqual(final.residentBytes, 0, name)
            XCTAssertEqual(final.reservedBytes, 0, name)
            XCTAssertTrue(pending.isEmpty, name)
        }
        XCTAssertNil(MatrixBudget.charge(rows: .max, dims: .max))
        XCTAssertNil(MatrixBudget.charge(rows: 0, dims: 2))
    }

    func testFillCancellationAndSingleFlight() async throws {
        let fixture = try SharedFixtures.json("contracts/retrieval-cache-v1.json")
        let cache = VectorMatrixCache(budgetBytes: (fixture["budgetBytes"] as! NSNumber).int64Value)
        let rows = cacheRows(fixture["rowsPerMatrix"] as! Int, dims: fixture["dims"] as! Int)
        let key = RetrievalCacheKey(databaseId: "cancel", notebookId: 1, generationId: 90, epoch: 0)
        let barrier = CacheBarrier()
        func acquire() -> Task<VectorMatrixLease?, Error> {
            Task { try await cache.acquire(key: key, rowCount: rows.count, dims: 2, epoch: { 0 }, load: {
                try await barrier.pause()
                return rows
            }) }
        }
        let first = acquire()
        await barrier.waitStarted()
        let second = acquire()
        await cache.waitForWaiters(key: key, count: 2)
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled waiter succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        await barrier.finish()
        let surviving = try await second.value
        XCTAssertNotNil(surviving)
        var statistics = await cache.statistics()
        XCTAssertEqual(statistics.loadCount, 1)
        XCTAssertEqual(statistics.residentBytes, (fixture["chargedBytesPerMatrix"] as! NSNumber).int64Value)
        await cache.invalidate(databaseId: key.databaseId)
        await surviving?.close()
        statistics = await cache.statistics()
        XCTAssertEqual(statistics.residentBytes, 0)

        let lastBarrier = CacheBarrier()
        let last = Task {
            try await cache.acquire(key: key, rowCount: rows.count, dims: 2, epoch: { 0 }, load: {
                try await lastBarrier.pause()
                return rows
            })
        }
        await lastBarrier.waitStarted()
        last.cancel()
        do { _ = try await last.value; XCTFail("Last waiter cancellation succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        await cache.waitForIdle()
        statistics = await cache.statistics()
        XCTAssertEqual(statistics.residentBytes, 0)
        XCTAssertEqual(statistics.reservedBytes, 0)

        // Completion must recheck the epoch even without an explicit invalidation.
        let epoch = CacheEpoch()
        let epochBarrier = CacheBarrier()
        let raced = Task {
            try await cache.acquire(key: key, rowCount: rows.count, dims: 2, epoch: { epoch.value }, load: {
                try await epochBarrier.pause()
                return rows
            })
        }
        await epochBarrier.waitStarted()
        epoch.increment()
        await epochBarrier.finish()
        let stale = try await raced.value
        XCTAssertNil(stale)
        statistics = await cache.statistics()
        XCTAssertEqual(statistics.residentBytes, 0)
        XCTAssertEqual(statistics.reservedBytes, 0)

        // A fill cannot grow beyond its reservation or publish a mutable builder.
        do {
            _ = try await cache.acquire(key: key, rowCount: 1, dims: 2, epoch: { 0 }, load: { rows })
            XCTFail("Over-capacity fill succeeded")
        } catch { XCTAssertFalse(error is CancellationError) }
        statistics = await cache.statistics()
        XCTAssertEqual(statistics.reservedBytes, 0)
    }

    func testStreamingAndCachedRankingAgree() async throws {
        let fixture = try SharedFixtures.json("contracts/retrieval-rank-v1.json")
        let c = (fixture["cases"] as! [[String: Any]]).first { $0["name"] as? String == "mask-before-heap" }!
        let input = c["rows"] as! [[String: Any]]
        let rows = input.map { r in VectorRow(reference: .init(chunkId: (r["chunkId"] as! NSNumber).int64Value,
            sourceId: (r["sourceId"] as! NSNumber).int64Value, revisionId: (r["revisionId"] as! NSNumber).int64Value,
            ord: r["ord"] as! Int), values: (r["vector"] as! [NSNumber]).map(\.floatValue)) }
        let query = (c["query"] as! [NSNumber]).map(\.floatValue)
        let permitted = Set(input.filter { $0["eligible"] as! Int == 1 }.map { ($0["sourceId"] as! NSNumber).int64Value })
        let dims = c["dims"] as! Int, k = c["k"] as! Int
        let key = RetrievalCacheKey(databaseId: "rank", notebookId: 1, generationId: 90, epoch: 0)
        let budget = try SharedFixtures.json("contracts/retrieval-cache-v1.json")["budgetBytes"] as! Int
        var results: [[ScoredChunk]] = []
        for bytes in [0, budget] {
            let cache = VectorMatrixCache(budgetBytes: Int64(bytes))
            let lease = try await cache.acquire(key: key, rowCount: rows.count, dims: dims, epoch: { 0 }, load: { rows })
            if let lease {
                results.append(lease.topK(query: query, permittedSources: permitted, k: k))
                await lease.close()
                XCTAssertTrue(lease.topK(query: query, permittedSources: permitted, k: k).isEmpty)
            } else {
                XCTAssertEqual(bytes, 0)
                var heap = try XCTUnwrap(MaskedVectorTopK(query: query, dims: dims, permittedSources: permitted, k: k))
                for row in rows {
                    var page = row.values
                    XCTAssertTrue(page.withUnsafeMutableBufferPointer { MaskedVectorTopK.normalize($0, allowZero: true) })
                    page.withUnsafeBufferPointer { heap.offer(row.reference, normalizedRow: $0) }
                }
                results.append(heap.sorted())
            }
        }
        XCTAssertEqual(results[0].map { $0.reference.chunkId }, (c["expectedIds"] as! [NSNumber]).map(\.int64Value))
        XCTAssertEqual(results[0].map(\.reference), results[1].map(\.reference))
        XCTAssertEqual(results[0].map(\.score), results[1].map(\.score))
    }

    private func cacheRows(_ count: Int, dims: Int) -> [VectorRow] {
        (0..<count).map { index in
            var vector = [Float](repeating: 0, count: dims)
            vector[0] = 1
            return VectorRow(reference: .init(chunkId: Int64(index + 1), sourceId: 1, revisionId: 1, ord: index), values: vector)
        }
    }
}

private enum CacheTestError: Error { case loadFailed }

/// Explicit barriers make tests independent of scheduling speed and wall time.
private actor CacheBarrier {
    private var started = false
    private var outcome: Result<Void, Error>?
    private var starters: [CheckedContinuation<Void, Never>] = []
    private var waiter: CheckedContinuation<Void, Error>?

    func pause() async throws {
        started = true
        starters.forEach { $0.resume() }; starters.removeAll()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let outcome { continuation.resume(with: outcome) }
                else { waiter = continuation }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }
    func waitStarted() async {
        if started { return }
        await withCheckedContinuation { starters.append($0) }
    }
    func finish(failing: Bool = false) {
        resolve(failing ? .failure(CacheTestError.loadFailed) : .success(()))
    }
    private func cancel() { resolve(.failure(CancellationError())) }
    private func resolve(_ result: Result<Void, Error>) {
        guard outcome == nil else { return }
        outcome = result
        waiter?.resume(with: result); waiter = nil
    }
}

private final class CacheEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 0
    var value: UInt64 { lock.withLock { current } }
    func increment() { lock.withLock { current += 1 } }
}

import XCTest
@testable import AINotebookCore

@MainActor final class BenchmarkMeasurementsTests: XCTestCase {
    private func code(_ error: any Error) -> String {
        if let e = error as? BenchmarkError { return e.code }
        if error is CancellationError { return "cancelled" }
        return "unexpected:\(error)"
    }

    func testColdWarmupAndMeasuredQueriesAreSeparate() async throws {
        var calls: [(Int, Bool)] = [], ticks: [Int64] = [200, 900]
        let phase = try await BenchmarkMeasurements.run(queries: 3, warmup: 2, concurrent: false,
            nowUs: { ticks.removeFirst() }, coldLoad: { calls.append((0, true)); return 100 }, runQuery: { i in
                calls.append((i, false))
                return BenchmarkTimingSample(queryId: i, embeddingUs: 1000, retrievalUs: 10, hydrationUs: 3, endToEndUs: 1013)
            }, writeBatch: { _ in XCTFail("unexpected ingestion") })
        XCTAssertEqual(calls.map(\.0), [0, 0, 1, 0, 1, 2])
        XCTAssertEqual(calls.map(\.1), [true, false, false, false, false, false])
        XCTAssertEqual(phase.coldCacheLoadUs, 100)
        XCTAssertEqual(phase.samples.map(\.retrievalUs), [10, 10, 10])
        XCTAssertEqual(phase.completedWrites, 0)
        XCTAssertEqual(phase.overlapUs, 0)
    }

    func testConcurrentWriterMustCompleteInsideMeasuredWindow() async throws {
        var clock: Int64 = 0
        var writes = 0, calls = 0
        let phase = try await BenchmarkMeasurements.run(queries: 2, warmup: 1, concurrent: true,
            nowUs: { clock += 10; return clock }, coldLoad: { nil }, runQuery: { i in
                calls += 1
                // Barrier (measured queries only; the writer starts after warmup): each
                // measured query waits until the writer finished one more batch.
                if calls > 1 {
                    let target = writes + 1
                    while writes < target { await Task.yield() }
                }
                return BenchmarkTimingSample(queryId: i, embeddingUs: 1, retrievalUs: 2, hydrationUs: 3, endToEndUs: 7)
            }, writeBatch: { _ in await Task.yield(); writes += 1 })
        XCTAssertGreaterThanOrEqual(phase.completedWrites, 2)
        XCTAssertGreaterThan(phase.overlapUs, 0)
        XCTAssertNil(phase.coldCacheLoadUs)

        do {
            _ = try await BenchmarkMeasurements.run(queries: 2, warmup: 0, concurrent: true,
                nowUs: { clock += 10; return clock }, coldLoad: { 1 },
                runQuery: { i in BenchmarkTimingSample(queryId: i, embeddingUs: 1, retrievalUs: 2, hydrationUs: 3, endToEndUs: 7) },
                writeBatch: { _ in throw CancellationError() })
            XCTFail("writer without completions passed")
        } catch { XCTAssertEqual(code(error), "insufficientIngestionOverlap") }
    }

    func testCancelledQueryAwaitsWriterAndPropagates() async throws {
        var writerRunning = false
        do {
            _ = try await BenchmarkMeasurements.run(queries: 3, warmup: 0, concurrent: true,
                nowUs: { 1 }, coldLoad: { 1 }, runQuery: { i in
                    if i == 1 { throw CancellationError() }
                    return BenchmarkTimingSample(queryId: i, embeddingUs: 1, retrievalUs: 2, hydrationUs: 3, endToEndUs: 7)
                }, writeBatch: { _ in writerRunning = true; await Task.yield(); writerRunning = false })
            XCTFail("cancelled run returned")
        } catch { XCTAssertEqual(code(error), "cancelled") }
        XCTAssertFalse(writerRunning, "writer was awaited")
    }

    func testSharedOverlapCacheFnvAndRounding() throws {
        for c in try BenchmarkFixture.cases("benchmark-run-v1.json", kind: "overlap") {
            let i = c["input"] as! [String: Any]
            let call = {
                try BenchmarkMeasurements.overlap(completionsUs: (i["completionsUs"] as! [NSNumber]).map(\.int64Value),
                                                  measuredStartUs: (i["measuredStartUs"] as! NSNumber).int64Value,
                                                  measuredEndUs: (i["measuredEndUs"] as! NSNumber).int64Value)
            }
            if let expectedError = c["error"] as? String {
                do { _ = try call(); XCTFail(c["name"] as! String) } catch { XCTAssertEqual(code(error), expectedError) }
            } else {
                let e = c["expected"] as! [String: NSNumber]
                let r = try call()
                XCTAssertEqual(r.completedWrites, e["completedWrites"]?.intValue)
                XCTAssertEqual(r.overlapUs, e["overlapUs"]?.int64Value)
            }
        }
        let caches = try BenchmarkFixture.cases("benchmark-run-v1.json", kind: "cache")
        XCTAssertEqual(caches.count, 3)
        for c in caches {
            let i = c["input"] as! [String: Any], e = c["expected"] as! [String: Any]
            let a = BenchmarkMeasurements.cacheAdmission(chunks: i["chunks"] as! Int, dims: i["dims"] as! Int,
                                                         budgetBytes: (i["budgetBytes"] as! NSNumber).int64Value)
            XCTAssertEqual(a.chargeBytes, (e["chargeBytes"] as! NSNumber).int64Value)
            XCTAssertEqual(a.cacheMode, e["cacheMode"] as? String)
            let ticks = (i["coldTicksUs"] as! [NSNumber]).map(\.int64Value)
            let cold: Int64? = a.cacheMode == "cached" ? ticks[1] - ticks[0] : nil
            XCTAssertEqual(cold, (e["coldCacheLoadUs"] as? NSNumber)?.int64Value)
        }
        for c in try BenchmarkFixture.cases("benchmark-run-v1.json", kind: "fnv") {
            XCTAssertEqual(Int(BenchmarkMeasurements.fnv1a32(c["input"] as! String)), c["expected"] as? Int)
        }
        for c in try BenchmarkFixture.cases("benchmark-run-v1.json", kind: "rounding") {
            let ms = ((c["input"] as! [String: Any])["ms"] as! NSNumber).doubleValue
            XCTAssertEqual(BenchmarkMath.microseconds(fromMilliseconds: ms),
                           ((c["expected"] as! [String: Any])["us"] as! NSNumber).int64Value, c["name"] as! String)
        }
    }

    func testCalibrationUsesOnlyTrainBodyCounts() async throws {
        let requests = [
            CalibrationRequest(id: "cs-a:0:3", family: "fixture-only", language: "cs", split: "train", kind: "body", text: "abc"),
            CalibrationRequest(id: "cs-b:0:3", family: "fixture-only", language: "cs", split: "holdout", kind: "body", text: "xyz"),
            CalibrationRequest(id: "prompt:q1", family: "fixture-only", language: "cs", split: "train", kind: "prompt",
                               text: "abc", messages: [ChatTurn(role: .user, content: "abc")]),
        ]
        var seen: [String] = []
        let rows = try await BenchmarkMeasurements.calibrate(requests: requests, modelDigest: "sha256:" + String(repeating: "a", count: 64)) { r in
            seen.append(r.id)
            return ChatTokenObservation(text: "x", promptTokens: r.kind == "body" ? 2 : 40, outputTokens: 1)
        }
        XCTAssertEqual(seen, requests.map(\.id))
        XCTAssertEqual(rows.map(\.method), ["ollama-raw-prompt", "ollama-raw-prompt", "ollama-chat-prompt"])
        XCTAssertEqual(rows[0].textHash, EvalCorpus.sha256(Data("abc".utf8)))
        XCTAssertEqual(try BenchmarkMeasurements.fitBodyRates(rows),
                       [TokenRate(family: "fixture-only", language: "cs", tokensPerScalarBp: 6667)])

        for (tokens, expected) in [(nil, "tokenCountUnavailable"), (-1, "invalidTokenCount")] as [(Int?, String)] {
            do {
                _ = try await BenchmarkMeasurements.calibrate(requests: [requests[0]], modelDigest: "d") { _ in
                    ChatTokenObservation(text: "", promptTokens: tokens, outputTokens: nil)
                }
                XCTFail(expected)
            } catch { XCTAssertEqual(code(error), expected) }
        }
        do {
            _ = try await BenchmarkMeasurements.calibrate(requests: [requests[0], requests[0]], modelDigest: "d") { _ in
                ChatTokenObservation(text: "", promptTokens: 1, outputTokens: nil)
            }
            XCTFail("duplicate ids")
        } catch { XCTAssertEqual(code(error), "invalidCalibration") }
        do {
            _ = try await BenchmarkMeasurements.calibrate(requests: requests, modelDigest: "d") { _ in throw CancellationError() }
            XCTFail("cancel")
        } catch { XCTAssertEqual(code(error), "cancelled") }
    }
}

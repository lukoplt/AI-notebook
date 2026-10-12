import XCTest
@testable import AINotebookCore

final class BenchmarkReportTests: XCTestCase {
    private let file = "benchmark-report-v1.json"

    private func code(_ body: () throws -> Void) -> String? {
        do { try body(); return nil }
        catch let e as BenchmarkError { return e.code }
        catch { return "unexpected:\(error)" }
    }

    func testReportGoldens() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "report")
        XCTAssertEqual(rows.count, 16)
        for c in rows {
            let name = c["name"] as! String
            let r = try JSONDecoder().decode(BenchmarkReportV1.self,
                                             from: JSONSerialization.data(withJSONObject: c["input"]!))
            if let error = c["error"] as? String {
                XCTAssertEqual(code { try r.validate() }, error, name)
                continue
            }
            try r.validate()
            let data = try r.jsonData()
            XCTAssertEqual(data.last, 0x0A, name)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? NSDictionary,
                           c["expectedJson"] as? NSDictionary, name)
            XCTAssertEqual(r.markdown(), c["expectedMarkdown"] as? String, name)
        }
    }

    func testNearestRankAndStrictGate() throws {
        let samples = (1...200).map(Int64.init)
        XCTAssertEqual(try BenchmarkMath.percentile(samples, bp: 9500), 190)
        XCTAssertEqual(try BenchmarkMath.percentile(samples, bp: 5000), 100)
        XCTAssertEqual(BenchmarkMath.warmGate(chunks: 100000, concurrent: false, queries: 200, p95Us: 300000), false)
        XCTAssertNil(BenchmarkMath.warmGate(chunks: 200000, concurrent: false, queries: 200, p95Us: 900000))
    }

    func testSharedPercentiles() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "percentile")
        XCTAssertEqual(rows.count, 5)
        for c in rows {
            let name = c["name"] as! String
            let samples = ((c["input"] as! [String: Any])["samples"] as! [NSNumber]).map(\.int64Value)
            if let error = c["error"] as? String {
                XCTAssertEqual(code { _ = try BenchmarkMath.percentile(samples, bp: 5000) }, error, name)
            } else {
                let expected = c["expected"] as! [String: NSNumber]
                XCTAssertEqual(try BenchmarkMath.percentile(samples, bp: 5000), expected["p50"]?.int64Value, name)
                XCTAssertEqual(try BenchmarkMath.percentile(samples, bp: 9500), expected["p95"]?.int64Value, name)
            }
        }
    }

    func testSharedGates() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "gate")
        XCTAssertEqual(rows.count, 5)
        for c in rows {
            let i = c["input"] as! [String: Any]
            XCTAssertEqual(BenchmarkMath.warmGate(chunks: i["chunks"] as! Int, concurrent: i["concurrent"] as! Bool,
                                                  queries: i["queries"] as! Int, p95Us: (i["p95Us"] as! NSNumber).int64Value),
                           c["expected"] as? Bool, c["name"] as! String)
        }
    }

    func testSharedThroughput() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "throughput")
        XCTAssertEqual(rows.count, 4)
        for c in rows {
            let name = c["name"] as! String
            let i = c["input"] as! [String: NSNumber]
            let tokens = i["tokens"]!.int64Value, elapsed = i["elapsedUs"]!.int64Value
            if let error = c["error"] as? String {
                XCTAssertEqual(code { _ = try BenchmarkMath.tokensPerSecondMilli(tokens: tokens, elapsedUs: elapsed) }, error, name)
            } else {
                let expected = (c["expected"] as! [String: Any])["tokensPerSecondMilli"] as? NSNumber
                XCTAssertEqual(try BenchmarkMath.tokensPerSecondMilli(tokens: tokens, elapsedUs: elapsed),
                               expected?.int64Value, name)
            }
        }
    }

    func testSharedEscapingAndRecallFormat() throws {
        let escapes = try BenchmarkFixture.cases(file, kind: "escape")
        XCTAssertEqual(escapes.count, 2)
        for c in escapes {
            XCTAssertEqual(BenchmarkMarkdown.escape(c["input"] as! String), c["expected"] as? String, c["name"] as! String)
        }
        let formats = try BenchmarkFixture.cases(file, kind: "recallFormat")
        XCTAssertEqual(formats.count, 1)
        for c in formats {
            let metrics = try JSONDecoder().decode([EvalMetric].self, from: JSONSerialization.data(withJSONObject: c["input"]!))
            XCTAssertEqual(metrics.map(BenchmarkMarkdown.recall), c["expected"] as? [String])
        }
    }

    func testAssembledPerformanceRowRecomputesSummaries() throws {
        let samples = (0..<200).map { i in
            BenchmarkQuerySample(queryId: i, embeddingUs: 1, retrievalUs: Int64(i + 1), hydrationUs: 1,
                                 endToEndUs: Int64(i + 4))
        }
        let row = try BenchmarkPerformanceRow(chunks: 100_000, concurrent: false, warmupQueries: 20, coldCacheLoadUs: 5,
                                              cacheMode: "cached", residentBytes: 1, peakPageBytes: 1, completedWrites: 0,
                                              overlapUs: 0, samples: samples)
        XCTAssertEqual(row.warmP50Us, 100)
        XCTAssertEqual(row.warmP95Us, 190)
        XCTAssertEqual(row.gatePassed, true)
        XCTAssertEqual(BenchmarkMath.microseconds(fromMilliseconds: 0.0005), 1)
        XCTAssertEqual(BenchmarkMath.microseconds(fromMilliseconds: -0.0005), -1)
    }
}

import XCTest
@testable import AINotebookCore

final class BenchmarkTelemetryTests: XCTestCase {
    private func code(_ body: () throws -> Void) -> String? {
        do { try body(); return nil }
        catch let e as BenchmarkError { return e.code }
        catch { return "unexpected:\(error)" }
    }

    private func snapshot(_ object: Any?) -> EmbeddingTelemetrySnapshot {
        let o = object as! [String: Any]
        return EmbeddingTelemetrySnapshot(serviceTokens: (o["serviceTokens"] as? NSNumber)?.int64Value,
                                          successfulTokens: (o["successfulTokens"] as! NSNumber).int64Value,
                                          requestCount: o["requestCount"] as! Int, rejectedRequests: o["rejectedRequests"] as! Int,
                                          splitParts: o["splitParts"] as! Int, uncountedRequests: o["uncountedRequests"] as! Int,
                                          serviceTokenStatus: o["serviceTokenStatus"] as! String)
    }

    func testCombinedPeakIsNotSumOfIndependentPeaks() throws {
        let peaks = try BenchmarkTelemetry.peaks([
            ProcessMemorySample(atUs: 0, runnerBytes: 80, serverTreeBytes: 10),
            ProcessMemorySample(atUs: 1, runnerBytes: 20, serverTreeBytes: 70)])
        XCTAssertEqual(peaks.runnerBytes, 80); XCTAssertEqual(peaks.serverBytes, 70)
        XCTAssertEqual(peaks.combinedBytes, 90)
    }

    func testSharedMemoryPeaks() throws {
        let rows = try BenchmarkFixture.cases("benchmark-run-v1.json", kind: "memory")
        XCTAssertEqual(rows.count, 5)
        for c in rows {
            let name = c["name"] as! String
            let samples = (c["input"] as! [[String: NSNumber]]).map {
                ProcessMemorySample(atUs: $0["atUs"]!.int64Value, runnerBytes: $0["runnerBytes"]!.int64Value,
                                    serverTreeBytes: $0["serverTreeBytes"]!.int64Value)
            }
            if let error = c["error"] as? String {
                XCTAssertEqual(code { _ = try BenchmarkTelemetry.peaks(samples) }, error, name)
            } else {
                let e = c["expected"] as! [String: NSNumber]
                XCTAssertEqual(try BenchmarkTelemetry.peaks(samples),
                               ProcessMemoryPeaks(runnerBytes: e["runnerBytes"]!.int64Value, serverBytes: e["serverBytes"]!.int64Value,
                                                  combinedBytes: e["combinedBytes"]!.int64Value), name)
            }
        }
    }

    func testSharedProcessTrees() throws {
        let rows = try BenchmarkFixture.cases("benchmark-run-v1.json", kind: "process")
        XCTAssertEqual(rows.count, 7)
        for c in rows {
            let name = c["name"] as! String
            let i = c["input"] as! [String: Any]
            let call = {
                try BenchmarkTelemetry.processTree(psOutput: i["psOutput"] as! String, rootPid: Int32(i["rootPid"] as! Int),
                                                   runnerPid: Int32(i["runnerPid"] as! Int))
            }
            if let error = c["error"] as? String {
                XCTAssertEqual(code { _ = try call() }, error, name)
            } else {
                let e = c["expected"] as! [String: Any]
                let tree = try call()
                XCTAssertEqual(tree.runnerBytes, (e["runnerBytes"] as! NSNumber).int64Value, name)
                XCTAssertEqual(tree.serverTreeBytes, (e["serverTreeBytes"] as! NSNumber).int64Value, name)
                XCTAssertEqual(tree.serverPids, (e["serverPids"] as! [Int]).map { Int32($0) }, name)
            }
        }
    }

    func testSharedTelemetrySnapshots() async throws {
        let rows = try BenchmarkFixture.cases("embedding-strict-v1.json", kind: "telemetry")
        XCTAssertEqual(rows.count, 2)
        for c in rows {
            let collector = BenchmarkEmbeddingTelemetry()
            let events = telemetryEvents(c["events"])
            for e in events { await collector.record(e) }
            let purpose = events.first!.purpose
            let actual = try await collector.snapshot(purpose: purpose)
            XCTAssertEqual(actual, snapshot(c["snapshot"]), c["name"] as! String)
            let other: EmbeddingPurpose = purpose == .query ? .document : .query
            let empty = try await collector.snapshot(purpose: other)
            XCTAssertEqual(empty.requestCount, 0)
        }
    }

    /// Every pipeline case's telemetry expectation, from real pipeline events.
    func testSharedPipelineTelemetry() async throws {
        let root = try SharedFixtures.json("contracts/embedding-strict-v1.json")
        let defaultProfile = try fixtureProfile(root["fixtureProfile"])
        let rows = try BenchmarkFixture.cases("embedding-strict-v1.json", kind: "pipeline")
        for c in rows {
            let name = c["name"] as! String
            let profile = c["profile"] == nil ? defaultProfile : try fixtureProfile(c["profile"])
            let transport = ScriptedEmbeddingTransport((c["exchanges"] as! [[String: Any]]).map(ScriptedExchange.init))
            let collector = BenchmarkEmbeddingTelemetry()
            let counter = (c["counter"] as? [String: Int]).map(FixtureCounter.init)
            let purpose = EmbeddingPurpose(rawValue: c["purpose"] as! String)!
            _ = try? await StrictEmbeddingPipeline(transport: transport, counter: counter, observer: collector)
                .embed(c["text"] as! String, profile: profile, purpose: purpose, effectiveLimit: c["effectiveLimit"] as! Int)
            let expected = (c["expected"] as! [String: Any])["telemetry"]
            let actual = try await collector.snapshot(purpose: purpose)
            XCTAssertEqual(actual, snapshot(expected), name)
        }
    }

    func testSamplerTakesStartAndEndSamplesAndFailsClosed() async throws {
        let ok = ProcessMemorySampler(intervalMs: 10_000) { ProcessMemorySample(atUs: 0, runnerBytes: 1, serverTreeBytes: 2) }
        await ok.start()
        let samples = await ok.stop()
        XCTAssertEqual(samples?.count, 2)
        let failing = ProcessMemorySampler(intervalMs: 10_000) { throw BenchmarkError(code: "processUnavailable") }
        await failing.start()
        let none = await failing.stop()
        XCTAssertNil(none)
    }
}

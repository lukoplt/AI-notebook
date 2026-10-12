import Foundation
import XCTest
@testable import AINotebookCore

/// Scripted strict transport: each call consumes one fixture exchange in order.
struct ScriptedExchange: Sendable {
    let input: String
    let outcome: String
    let vector: [Float]
    let promptTokens: Int?
    let status: Int?
    let body: String?

    init(_ row: [String: Any]) {
        input = row["input"] as! String
        outcome = row["outcome"] as! String
        vector = BenchmarkFixture.vector(row["vector"])
        promptTokens = row["promptTokens"] as? Int
        status = row["status"] as? Int
        body = row["body"] as? String
    }
}

actor ScriptedEmbeddingTransport: StrictEmbeddingTransport {
    private var script: [ScriptedExchange]
    private(set) var inputs: [String] = []

    init(_ script: [ScriptedExchange]) { self.script = script }

    func embed(model: String, input: String, nativeDims: Int, inputLimit: Int) async throws -> StrictEmbeddingResult {
        inputs.append(input)
        guard !script.isEmpty else { throw EmbeddingProfileError(code: "scriptExhausted") }
        let step = script.removeFirst()
        guard step.input == input else { throw EmbeddingProfileError(code: "unexpectedInput:\(input)") }
        switch step.outcome {
        case "ok":
            return StrictEmbeddingResult(vector: step.vector, promptTokens: step.promptTokens,
                                         totalDurationNs: nil, loadDurationNs: nil)
        case "lengthRejected": throw EmbeddingInputTooLong()
        case "httpError": throw ProviderError.http(code: step.status ?? 0, body: step.body ?? "")
        case "cancel": throw CancellationError()
        default: throw EmbeddingProfileError(code: "badScript")
        }
    }
}

actor RecordingTelemetry: EmbeddingTelemetryObserving {
    private(set) var events: [EmbeddingTelemetryEvent] = []
    func record(_ event: EmbeddingTelemetryEvent) { events.append(event) }
}

actor FixtureCounter: ExactTokenCounting {
    private let counts: [String: Int]
    private(set) var calls: [[String: String]] = []
    init(_ counts: [String: Int]) { self.counts = counts }
    func count(_ text: String, tokenizerId: String) async throws -> Int {
        calls.append(["text": text, "tokenizerId": tokenizerId])
        guard let n = counts[text] else { throw EmbeddingProfileError(code: "tokenCountUnavailable") }
        return n
    }
}

func fixtureProfile(_ object: Any?) throws -> EmbeddingProfile {
    var row = object as! [String: Any]
    row["ceilingSource"] = row["ceilingSource"] ?? "model-card"
    return try JSONDecoder().decode(EmbeddingProfile.self, from: JSONSerialization.data(withJSONObject: row))
}

func telemetryEvents(_ value: Any?) -> [EmbeddingTelemetryEvent] {
    (value as? [[String: Any]] ?? []).map {
        EmbeddingTelemetryEvent(kind: $0["kind"] as! String, purpose: EmbeddingPurpose(rawValue: $0["purpose"] as! String)!,
                                tokens: $0["tokens"] as? Int, start: $0["start"] as? Int, end: $0["end"] as? Int)
    }
}

final class StrictEmbeddingPipelineTests: XCTestCase {
    actor CounterTransport: StrictEmbeddingTransport {
        var requests = 0
        func embed(model: String, input: String, nativeDims: Int, inputLimit: Int) async throws -> StrictEmbeddingResult {
            requests += 1
            let n = input.unicodeScalars.count
            if n > 5 { throw EmbeddingInputTooLong() }
            return StrictEmbeddingResult(vector: [1, 0], promptTokens: n, totalDurationNs: 1000, loadDurationNs: 0)
        }
    }

    func testSplitKeepsEveryScalarAndCountsPrefixes() async throws {
        let transport = CounterTransport()
        let p = EmbeddingProfile(id: "fixture", model: "fixture", tokenizerId: "fixture-only", queryPrefix: "q:",
                                 documentPrefix: "", nativeDims: 2, dims: 2, maxInputTokens: 5, matryoshka: false,
                                 ceilingSource: "model-card")
        let result = try await StrictEmbeddingPipeline(transport: transport).embed(
            "ab😀cd", profile: p, purpose: .query, effectiveLimit: 5)
        XCTAssertEqual(result.parts.map(\.start), [0, 2])
        XCTAssertEqual(result.parts.map(\.end), [2, 5])
        XCTAssertEqual(result.successfulTokens, 9)
        XCTAssertEqual(result.rejectedRequests, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests, 3)
    }

    func testSharedPipelineCases() async throws {
        let root = try SharedFixtures.json("contracts/embedding-strict-v1.json")
        let defaultProfile = try fixtureProfile(root["fixtureProfile"])
        let rows = try BenchmarkFixture.cases("embedding-strict-v1.json", kind: "pipeline")
        XCTAssertEqual(rows.count, 16)
        for c in rows {
            let name = c["name"] as! String
            let expected = c["expected"] as! [String: Any]
            let profile = c["profile"] == nil ? defaultProfile : try fixtureProfile(c["profile"])
            let exchanges = c["exchanges"] as! [[String: Any]]
            let transport = ScriptedEmbeddingTransport(exchanges.map(ScriptedExchange.init))
            let telemetry = RecordingTelemetry()
            let counter = (c["counter"] as? [String: Int]).map(FixtureCounter.init)
            let pipeline = StrictEmbeddingPipeline(transport: transport, counter: counter, observer: telemetry)
            let purpose = EmbeddingPurpose(rawValue: c["purpose"] as! String)!
            do {
                let r = try await pipeline.embed(c["text"] as! String, profile: profile, purpose: purpose,
                                                 effectiveLimit: c["effectiveLimit"] as! Int)
                XCTAssertNil(expected["error"] as? String, name)
                let parts = (expected["parts"] as! [[String: Int]]).map {
                    EmbeddedPart(start: $0["start"]!, end: $0["end"]!, tokens: $0["tokens"]!)
                }
                XCTAssertEqual(r.parts, parts, name)
                XCTAssertEqual(r.successfulTokens, expected["successfulTokens"] as? Int, name)
                XCTAssertEqual(r.rejectedRequests, expected["rejectedRequests"] as? Int, name)
                BenchmarkFixture.assertMillionths(r.vector, expected["vectorMillionths"], name)
            } catch {
                XCTAssertEqual(benchmarkErrorCode(error), expected["error"] as? String, name)
            }
            let inputs = await transport.inputs
            XCTAssertEqual(inputs, exchanges.map { $0["input"] as! String }, name)
            XCTAssertEqual(inputs.count, expected["requestCount"] as? Int, name)
            let events = await telemetry.events
            if expected["events"] != nil { XCTAssertEqual(events, telemetryEvents(expected["events"]), name) }
            XCTAssertEqual(events.filter { $0.kind == "request" }.count, expected["requestCount"] as? Int, name)
            let calls = await counter?.calls ?? []
            XCTAssertEqual(calls, expected["counterCalls"] as? [[String: String]], name)
        }
    }

    func testCancellationBeforeRequestSendsNothing() async throws {
        let transport = ScriptedEmbeddingTransport([])
        let p = try EmbeddingProfiles.require("bge-m3-1024")
        let task = Task { () -> String? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await StrictEmbeddingPipeline(transport: transport).embed("abc", profile: p, purpose: .document,
                                                                                effectiveLimit: 8192); return nil }
            catch { return benchmarkErrorCode(error) }
        }
        let code = await task.value
        XCTAssertEqual(code, "cancelled")
        let inputs = await transport.inputs
        XCTAssertEqual(inputs, [])
    }

    func testOfflineTokenizerProcessMatchesRequestIds() async throws {
        let script = #"read line; case "$line" in *'"requestId":"r1"'*'"tokenizerId":"tok"'*) printf '%s\n' '{"assetsSha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","requestId":"r1","revision":"rev","tokenizerId":"tok","tokens":4}';; *) printf '%s\n' '{"requestId":"r1","error":"invalidRequest"}';; esac; read line; printf '%s\n' '{"requestId":"zzz","tokens":1}'"#
        let process = OfflineTokenizerProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        let count = try await process.countDetailed("Záruka", tokenizerId: "tok")
        XCTAssertEqual(count, OfflineTokenCount(tokens: 4, tokenizerId: "tok", revision: "rev",
                                                assetsSha256: String(repeating: "c", count: 64)))
        do {
            _ = try await process.count("x", tokenizerId: "tok")
            XCTFail("mismatched request id accepted")
        } catch { XCTAssertEqual(benchmarkErrorCode(error), "tokenizerUnavailable") }
        await process.terminate()
    }
}

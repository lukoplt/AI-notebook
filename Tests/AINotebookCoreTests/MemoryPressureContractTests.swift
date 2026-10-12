import Foundation
import XCTest
@testable import AINotebookCore

/// Shared `ingestion-memory-pressure-v1` fixture: graded admission and probe mappings.
final class MemoryPressureContractTests: XCTestCase {
    private func cases(_ operation: String) throws -> [[String: Any]] {
        let fixture = try SharedFixtures.json("contracts/ingestion-memory-pressure-v1.json")
        XCTAssertEqual(fixture["contract"] as? String, "ingestion-memory-pressure")
        XCTAssertEqual(fixture["version"] as? Int, 1)
        return try XCTUnwrap(fixture["cases"] as? [[String: Any]]).filter { $0["operation"] as? String == operation }
    }

    /// Waits (bounded) until the admission actor reflects an asynchronous acquire.
    /// Waits up to 10 s of wall time (not a fixed number of yields): CI runners
    /// under `swift test --parallel` can need far longer than 2,000 yields.
    private func settle(_ name: String, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("\(name): admission did not settle")
    }

    func testAdmissionTracesMatchFixture() async throws {
        let rows = try cases("admission")
        XCTAssertGreaterThanOrEqual(rows.count, 10)
        for row in rows {
            let name = row["name"] as! String, input = row["input"] as! [String: Any]
            let admission = IngestionAdmission(maxExtractions: (input["maxExtractions"] as! NSNumber).intValue,
                                               memoryBytes: (input["memoryBytes"] as! NSNumber).int64Value)
            var ids: [String: UUID] = [:], names: [UUID: String] = [:], tasks: [String: Task<Void, Error>] = [:]
            for event in input["events"] as! [[String: Any]] {
                switch event["operation"] as! String {
                case "pressure":
                    await admission.setMemoryPressure(try XCTUnwrap(MemoryPressureLevel(rawValue: event["level"] as! String)))
                case "blocked":
                    await admission.setMemoryPressure(event["blocked"] as! Bool)
                case "acquire":
                    let request = event["requestId"] as! String, id = UUID(), bytes = (event["bytes"] as! NSNumber).int64Value
                    ids[request] = id; names[id] = request
                    tasks[request] = Task { try await admission.acquireExtraction(bytes: bytes, token: id) }
                    await settle(name) { let s = await admission.snapshot(); return (s.reservations + s.waiters).contains { $0.token == id } }
                case "release":
                    let request = event["requestId"] as! String
                    try await tasks[request]!.value
                    await admission.releaseExtraction(try XCTUnwrap(ids[request]))
                default:
                    XCTFail("\(name): unknown operation")
                }
                let s = await admission.snapshot()
                let projection: [String: Any] = ["level": s.level.rawValue,
                                                 "reservations": s.reservations.map { names[$0.token]! },
                                                 "waiters": s.waiters.map { names[$0.token]! }]
                XCTAssertEqual(NSDictionary(dictionary: projection),
                               NSDictionary(dictionary: event["expected"] as! [String: Any]),
                               "\(name) \(event["operation"]!)")
            }
            for task in tasks.values { task.cancel() }
        }
    }

    func testDarwinLevelMapping() throws {
        let rows = try cases("darwin-level")
        XCTAssertGreaterThanOrEqual(rows.count, 5)
        for row in rows {
            XCTAssertEqual(MemoryPressureLevel.darwin(rawLevel: (row["input"] as! NSNumber).intValue).rawValue,
                           row["expected"] as? String, row["name"] as! String)
        }
    }

    func testMemoryLoadMapping() throws {
        let rows = try cases("memory-load")
        XCTAssertGreaterThanOrEqual(rows.count, 5)
        for row in rows {
            XCTAssertEqual(MemoryPressureLevel.memoryLoad(percent: (row["input"] as! NSNumber).intValue).rawValue,
                           row["expected"] as? String, row["name"] as! String)
        }
    }

    /// Field report (v0.15.0): a pressure signal closed the gate and the clearing
    /// event never applied, so every due extraction waited forever. The runtime
    /// now re-samples the probe on each tick, which reopens the gate.
    func testTickReappliesProbeAfterMissedNormalEvent() async throws {
        let admission = IngestionAdmission()
        let probe = LevelProbe(.critical)
        let runtime = try await MemoryPressureContractTests.runtime(admission: admission, probe: probe)
        try await runtime.tick(at: 0)
        let paused = await admission.snapshot().level
        XCTAssertEqual(paused, .critical)
        let waiting = Task { try await admission.acquireExtraction(bytes: 10) }
        await settle("waiter") { await admission.snapshot().waiters.count == 1 }
        // The OS is back to normal but no event was delivered: the next tick reopens the gate.
        probe.set(.normal)
        try await runtime.tick(at: 100)
        let token = try await waiting.value
        let granted = await admission.snapshot().reservations.map(\.token)
        XCTAssertEqual(granted, [token])
        // Warning degrades to one extraction instead of stopping.
        probe.set(.warning)
        try await runtime.tick(at: 200)
        await admission.releaseExtraction(token)
        let one = try await admission.acquireExtraction(bytes: 10)
        let second = Task { try await admission.acquireExtraction(bytes: 10) }
        await settle("second") { await admission.snapshot().waiters.count == 1 }
        await admission.releaseExtraction(one)
        _ = try await second.value
    }

    /// End to end: a due extraction stalls while the probe reports critical,
    /// the status strip says so, and the job runs once pressure drops — with
    /// no OS event, only the next scheduler tick.
    func testDueExtractionResumesAndStatusShowsPause() async throws {
        let admission = IngestionAdmission()
        let probe = LevelProbe(.critical)
        let store = try await MainActor.run { try NotebookStore(path: .inMemory) }
        let runtime = try FolderIngestionRuntime.make(store: store, admission: admission, session: { _ in nil },
            clock: SystemIngestLeaseClock(), watches: NativeFolderWatchFactory(), fileSystem: NativeFolderFileSystem(),
            dispatch: false, memoryPressure: { probe.get() })
        let (notebook, job) = try await MainActor.run { () throws -> (Int64, Int64) in
            let notebook = try XCTUnwrap(store.createNotebook(name: "n").id)
            let source = try store.createSource(notebookId: notebook, type: .text, title: "t", uri: nil, rawPath: nil)
            let job = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(source.id!)", targetRevision: nil), now: 0)
            return (notebook, job)
        }
        try await runtime.tick(at: 0)
        let paused = try await runtime.indexingStatus(notebookId: notebook)
        XCTAssertEqual(paused.phase.name, "extracting")
        XCTAssertEqual(paused.memoryPressure, .critical)
        let drain = Task { try await runtime.drainOnce() }
        await settle("paused extraction") { await admission.snapshot().waiters.count == 1 }
        let state = try await MainActor.run { try store.job(id: job)?.state }
        XCTAssertEqual(state, "queued", "nothing is claimed while paused")
        probe.set(.normal)
        try await runtime.tick(at: 100)
        let ran = try await drain.value
        XCTAssertTrue(ran)
        let attempts = try await MainActor.run { try store.job(id: job)?.attempts }
        XCTAssertEqual(attempts, 1, "the job was claimed after the gate reopened")
        let after = try await runtime.indexingStatus(notebookId: notebook)
        XCTAssertNil(after.memoryPressure)
    }

    final class LevelProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var level: MemoryPressureLevel
        init(_ level: MemoryPressureLevel) { self.level = level }
        func set(_ level: MemoryPressureLevel) { lock.lock(); self.level = level; lock.unlock() }
        func get() -> MemoryPressureLevel { lock.lock(); defer { lock.unlock() }; return level }
    }

    static func runtime(admission: IngestionAdmission, probe: LevelProbe) async throws -> FolderIngestionRuntime {
        let store = try await MainActor.run { try NotebookStore(path: .inMemory) }
        return try FolderIngestionRuntime.make(store: store, admission: admission, session: { _ in nil },
            clock: SystemIngestLeaseClock(), watches: NativeFolderWatchFactory(), fileSystem: NativeFolderFileSystem(),
            dispatch: false, memoryPressure: { probe.get() })
    }
}

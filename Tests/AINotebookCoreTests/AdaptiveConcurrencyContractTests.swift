import Foundation
import XCTest
@testable import AINotebookCore

/// Shared `ingestion-adaptive-concurrency-v1` fixture (contract
/// `ingestion-memory-pressure-v1` addendum A): capacity, target, governor,
/// adaptive admission and probe mappings.
final class AdaptiveConcurrencyContractTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let fixture = try SharedFixtures.json("contracts/ingestion-adaptive-concurrency-v1.json")
        XCTAssertEqual(fixture["contract"] as? String, "ingestion-adaptive-concurrency")
        XCTAssertEqual(fixture["version"] as? Int, 1)
        return fixture
    }

    private func cases(_ operation: String) throws -> [[String: Any]] {
        try XCTUnwrap(fixture()["cases"] as? [[String: Any]]).filter { $0["operation"] as? String == operation }
    }

    private func int(_ value: Any?) -> Int { (value as! NSNumber).intValue }
    private func int64(_ value: Any?) -> Int64 { (value as! NSNumber).int64Value }

    func testConstantsMatchFixture() throws {
        let f = try fixture()
        XCTAssertEqual(int(f["maxWorkers"]), AdaptiveConcurrency.maxWorkersCap)
        XCTAssertEqual(int(f["initialWorkers"]), AdaptiveConcurrency.initialWorkers)
        XCTAssertEqual(int(f["batteryWorkers"]), AdaptiveConcurrency.batteryWorkers)
        XCTAssertEqual(int(f["busyWorkers"]), AdaptiveConcurrency.busyWorkers)
        XCTAssertEqual(int(f["constrainedWorkers"]), AdaptiveConcurrency.constrainedWorkers)
        XCTAssertEqual(int(f["maxHashWidth"]), AdaptiveConcurrency.maxHashWidth)
        XCTAssertEqual(int64(f["minBudgetBytes"]), AdaptiveConcurrency.minBudgetBytes)
        XCTAssertEqual(int64(f["maxBudgetBytes"]), AdaptiveConcurrency.maxBudgetBytes)
        XCTAssertEqual(int64(f["budgetPercent"]), AdaptiveConcurrency.budgetPercent)
        XCTAssertEqual(int64(f["raiseAfterMs"]), AdaptiveConcurrency.raiseAfterMs)
        XCTAssertEqual(int64(f["sampleIntervalMs"]), AdaptiveConcurrency.sampleIntervalMs)
        XCTAssertEqual(f["thermal"] as? [String], AdaptiveConcurrency.Thermal.allCases.map(\.rawValue))
    }

    func testCapacityFunctions() throws {
        let workers = try cases("max-workers"), budgets = try cases("memory-budget"), widths = try cases("hash-width")
        XCTAssertGreaterThanOrEqual(workers.count, 8)
        XCTAssertGreaterThanOrEqual(budgets.count, 5)
        XCTAssertGreaterThanOrEqual(widths.count, 4)
        for row in workers {
            XCTAssertEqual(AdaptiveConcurrency.maxWorkers(cores: int(row["input"])), int(row["expected"]), row["name"] as! String)
        }
        for row in budgets {
            XCTAssertEqual(AdaptiveConcurrency.memoryBudget(physicalBytes: int64(row["input"])), int64(row["expected"]), row["name"] as! String)
        }
        for row in widths {
            XCTAssertEqual(AdaptiveConcurrency.hashWidth(extractionLimit: int(row["input"])), int(row["expected"]), row["name"] as! String)
        }
    }

    func testTargetMatchesFixture() throws {
        let rows = try cases("target")
        XCTAssertGreaterThanOrEqual(rows.count, 20)
        for row in rows {
            let input = row["input"] as! [String: Any]
            let sample = AdaptiveConcurrency.SystemSample(cores: int(input["cores"]), loadMilli: int(input["loadMilli"]),
                thermal: try XCTUnwrap(AdaptiveConcurrency.Thermal(rawValue: input["thermal"] as! String)),
                lowPower: input["lowPower"] as! Bool, onBattery: input["onBattery"] as! Bool)
            let memory = try XCTUnwrap(MemoryPressureLevel(rawValue: input["memory"] as! String))
            XCTAssertEqual(AdaptiveConcurrency.target(sample, ownWorkers: int(input["ownWorkers"]), memory: memory),
                           int(row["expected"]), row["name"] as! String)
        }
    }

    func testGovernorTracesMatchFixture() throws {
        let rows = try cases("governor")
        XCTAssertGreaterThanOrEqual(rows.count, 6)
        for row in rows {
            let input = row["input"] as! [String: Any]
            var governor = AdaptiveConcurrency.Governor(cap: int(input["cap"]))
            for (index, sample) in (input["samples"] as! [[String: Any]]).enumerated() {
                let limit = governor.observe(target: int(sample["target"]), atMs: int64(sample["atMs"]))
                XCTAssertEqual(limit, int(sample["expected"]), "\(row["name"]!) #\(index)")
                XCTAssertEqual(governor.limit, limit)
            }
        }
    }

    /// Waits (bounded) until the admission actor reflects an asynchronous acquire.
    private func settle(_ name: String, _ condition: () async -> Bool) async {
        for _ in 0..<2_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("\(name): admission did not settle")
    }

    func testAdmissionTracesMatchFixture() async throws {
        let rows = try cases("admission")
        XCTAssertGreaterThanOrEqual(rows.count, 6)
        for row in rows {
            let name = row["name"] as! String, input = row["input"] as! [String: Any]
            let admission = IngestionAdmission(maxExtractions: int(input["maxExtractions"]), memoryBytes: int64(input["memoryBytes"]))
            var ids: [String: UUID] = [:], names: [UUID: String] = [:], tasks: [String: Task<Void, Error>] = [:]
            for event in input["events"] as! [[String: Any]] {
                switch event["operation"] as! String {
                case "limit":
                    await admission.setConcurrencyLimit(int(event["limit"]))
                case "pressure":
                    await admission.setMemoryPressure(try XCTUnwrap(MemoryPressureLevel(rawValue: event["level"] as! String)))
                case "acquire":
                    let request = event["requestId"] as! String, id = UUID(), bytes = int64(event["bytes"])
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
                let projection: [String: Any] = ["limit": s.limit, "level": s.level.rawValue,
                                                 "reservations": s.reservations.map { names[$0.token]! },
                                                 "waiters": s.waiters.map { names[$0.token]! }]
                XCTAssertEqual(NSDictionary(dictionary: projection), NSDictionary(dictionary: event["expected"] as! [String: Any]),
                               "\(name) \(event["operation"]!)")
            }
            for task in tasks.values { task.cancel() }
        }
    }

    func testDarwinThermalMapping() throws {
        let rows = try cases("darwin-thermal")
        XCTAssertGreaterThanOrEqual(rows.count, 4)
        for row in rows {
            XCTAssertEqual(AdaptiveConcurrency.Thermal.darwin(rawValue: int(row["input"])).rawValue, row["expected"] as? String,
                           row["name"] as! String)
        }
    }

    /// The Windows probe mappings are pure: macOS checks them too (parity of the reference).
    func testWindowsMappingsAreConsistentWithReference() throws {
        for row in try cases("windows-power") {
            let input = row["input"] as! [String: Any], expected = row["expected"] as! [String: Any]
            XCTAssertEqual(int(input["acLineStatus"]) == 0, expected["onBattery"] as? Bool, row["name"] as! String)
            XCTAssertEqual(int(input["systemStatusFlag"]) & 1 == 1, expected["lowPower"] as? Bool, row["name"] as! String)
        }
        XCTAssertGreaterThanOrEqual(try cases("windows-load").count, 5)
    }

    func testStandardAdmissionScalesWithMachine() async {
        let admission = IngestionAdmission.standard()
        let cores = ProcessInfo.processInfo.activeProcessorCount
        XCTAssertEqual(admission.maxExtractions, AdaptiveConcurrency.maxWorkers(cores: cores))
        XCTAssertEqual(admission.memoryBytes, AdaptiveConcurrency.memoryBudget(physicalBytes: Int64(ProcessInfo.processInfo.physicalMemory)))
        let limit = await admission.concurrencyLimit
        XCTAssertEqual(limit, admission.maxExtractions, "without a governor the limit is the cap")
    }

    func testDarwinSampleIsSane() {
        let sample = AdaptiveConcurrency.sampleDarwin()
        XCTAssertEqual(sample.cores, ProcessInfo.processInfo.activeProcessorCount)
        XCTAssertGreaterThanOrEqual(sample.loadMilli, 0)
    }

    final class SampleProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var sample: AdaptiveConcurrency.SystemSample
        private(set) var reads = 0
        init(_ sample: AdaptiveConcurrency.SystemSample) { self.sample = sample }
        func set(_ sample: AdaptiveConcurrency.SystemSample) { lock.lock(); self.sample = sample; lock.unlock() }
        func get() -> AdaptiveConcurrency.SystemSample { lock.lock(); defer { lock.unlock() }; reads += 1; return sample }
    }

    /// The scheduler tick samples the system probe every `sampleIntervalMs`, runs the
    /// target through the governor and applies the limit to admission (addendum A §A.4).
    func testRuntimeTickGovernsTheAdmissionLimit() async throws {
        let admission = IngestionAdmission(maxExtractions: 6, memoryBytes: 1 << 30)
        let probe = SampleProbe(.init(cores: 12, loadMilli: 0))
        let store = try await MainActor.run { try NotebookStore(path: .inMemory) }
        let runtime = try FolderIngestionRuntime.make(store: store, admission: admission, session: { _ in nil },
            clock: SystemIngestLeaseClock(), watches: NativeFolderWatchFactory(), fileSystem: NativeFolderFileSystem(),
            dispatch: false, memoryPressure: { .normal }, systemLoad: { probe.get() })
        func limit(at ms: Int64) async throws -> Int {
            try await runtime.tick(at: ms)
            return await admission.concurrencyLimit
        }
        var value = try await limit(at: 0)
        XCTAssertEqual(value, 2, "starts at the previous fixed concurrency")
        value = try await limit(at: 1_000)
        XCTAssertEqual(value, 2)
        XCTAssertEqual(probe.reads, 1, "the system probe is sampled at most every 2 s")
        value = try await limit(at: 30_000)
        XCTAssertEqual(value, 6, "an idle machine gets the cap after the hold")
        probe.set(.init(cores: 12, loadMilli: 0, onBattery: true))
        value = try await limit(at: 31_000)
        XCTAssertEqual(value, 6, "not sampled yet")
        value = try await limit(at: 32_000)
        XCTAssertEqual(value, 2, "battery steps down at once")
        probe.set(.init(cores: 12, loadMilli: 12_000))
        value = try await limit(at: 34_000)
        XCTAssertEqual(value, 1, "a busy machine gets one worker")
        probe.set(.init(cores: 12, loadMilli: 0, thermal: .serious))
        value = try await limit(at: 70_000)
        XCTAssertEqual(value, 1, "serious thermal state never raises")
    }

    /// Without a system probe (tests, headless tools) the limit stays at the cap.
    func testRuntimeWithoutProbeKeepsTheCap() async throws {
        let admission = IngestionAdmission(maxExtractions: 4, memoryBytes: 1 << 30)
        let store = try await MainActor.run { try NotebookStore(path: .inMemory) }
        let runtime = try FolderIngestionRuntime.make(store: store, admission: admission, session: { _ in nil },
            clock: SystemIngestLeaseClock(), watches: NativeFolderWatchFactory(), fileSystem: NativeFolderFileSystem(),
            dispatch: false, memoryPressure: { .normal })
        try await runtime.tick(at: 0)
        let limit = await admission.concurrencyLimit
        XCTAssertEqual(limit, 4)
    }
}

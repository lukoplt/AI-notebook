import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private final class CadenceBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private struct CadenceFS: FolderFileSystem {
    func resolve(rootPath: String) throws -> FolderIdentity {
        FolderIdentity(volumeId: "cadence", components: rootPath.split(separator: "/").map(String.init), rootFileId: rootPath)
    }
    func caseSensitive(root: FolderSource) throws -> Bool { true }
    func list(root: FolderSource, directory: String) throws -> [FolderEntry] { [] }
    func stat(root: FolderSource, relativePath: String) throws -> FileStamp { FileStamp(identity: "root", mtimeNs: 0, sizeBytes: 0) }
    func hash(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderRead { throw IngestionError(code: "outsideRoot") }
    func snapshot(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderFileSnapshot { throw IngestionError(code: "outsideRoot") }
}

private final class CadenceClock: IngestLeaseClock, @unchecked Sendable {
    let current = CadenceBox<Int64>(0)
    func now() -> Int64 { current.value }
    func wait(until: Int64) async throws { throw CancellationError() }
}

private final class CadenceWatches: FolderWatchFactory, @unchecked Sendable {
    struct Handle: FolderWatchHandle { func start() throws {}; func stop() {} }
    let callbacks = CadenceBox<[Int64: @Sendable (String) -> Void]>([:])
    func make(folder: FolderSource, onEvent: @escaping @Sendable (String) -> Void) throws -> any FolderWatchHandle {
        callbacks.value[folder.id] = onEvent
        return Handle()
    }
}

/// Periodic reconcile cadence (contract `ingestion-scan-perf-v1` §4, fixture `ingestion-scan-cadence-v1`).
@MainActor
final class FolderScanCadenceTests: XCTestCase {
    func testCadenceFixture() throws {
        let fixture = try SharedFixtures.json("contracts/ingestion-scan-cadence-v1.json")
        XCTAssertEqual(fixture["contract"] as? String, "ingestion-scan-cadence")
        XCTAssertEqual(fixture["periodicReconcileMinutes"] as? Int, RagContractV1.Scan.periodicReconcileMinutes)
        XCTAssertEqual(fixture["watchedVerifyHours"] as? Int, FolderReconciler.watchedVerifyHours)
        XCTAssertEqual((fixture["wakeGapSeconds"] as? NSNumber)?.int64Value, FolderIngestionRuntime.wakeGapSeconds)
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        var counts: [String: Int] = [:]
        for row in cases {
            let input = row["input"] as! [String: Any], name = row["name"] as? String ?? ""
            func time(_ key: String) -> Int64? { (input[key] as? NSNumber)?.int64Value }
            let operation = row["operation"] as! String
            counts[operation, default: 0] += 1
            switch operation {
            case "verify-due":
                XCTAssertEqual(FolderReconciler.verifyDue(startup: input["startup"] as! Bool, watchHealthy: input["watchHealthy"] as! Bool,
                                                          lastFullScanAt: time("lastFullScanAt"), lastRequestedAt: time("lastRequestedAt"),
                                                          now: time("now")!), row["expected"] as? Bool, name)
            case "unreadable-file":
                break // replayed through the scanner by FolderScanUnreadableTests
            case "wake-gap":
                XCTAssertEqual(FolderIngestionRuntime.suspendedBetween(previous: time("previous")!, now: time("now")!),
                               row["expected"] as? Bool, name)
            default:
                XCTFail("unknown operation \(operation)")
            }
        }
        XCTAssertEqual(counts, ["verify-due": 13, "wake-gap": 6, "unreadable-file": 8])
    }

    private func queuedScans(_ store: NotebookStore) throws -> [String] {
        try store.runOnDatabase { db in
            let queued = try String.fetchAll(db, sql: "SELECT target FROM ingest_jobs WHERE kind='scan' AND state='queued' ORDER BY target")
            try db.execute(sql: "UPDATE ingest_jobs SET state='done' WHERE kind='scan' AND state='queued'")
            return queued
        }
    }

    func testHealthyWatchStretchesPeriodicRescan() async throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "c").id)
        var ids: [Int64] = []
        for (root, watch) in [("/healthy", true), ("/unhealthy", true), ("/manual", false)] {
            ids.append(try store.createFolder(notebookId: notebook, draft: FolderDraft(rootPath: root, displayName: root,
                includeExts: ["md"], ignoreGlobs: [], limitsJSON: "{}", encodingFallback: "cp1250", watchEnabled: watch),
                identity: CadenceFS(), now: 0).id)
        }
        let healthy = ids[0], unhealthy = ids[1]
        let clock = CadenceClock()
        let reconciler = FolderReconciler(store: store, clock: clock, watchHealthy: { $0 == healthy }, requestScan: { id, verify in
            _ = try await MainActor.run { try store.requestFolderScan(folderId: id, verifyAll: verify, now: clock.now()) }
        })
        try await reconciler.start()
        XCTAssertEqual(try queuedScans(store), ["folder:\(healthy)", "folder:\(unhealthy)"], "startup scans every watched folder")
        try await reconciler.reconcile(now: 1800)
        XCTAssertEqual(try queuedScans(store), ["folder:\(unhealthy)"], "a healthy watch skips the 30-minute rescan")
        try await reconciler.reconcile(now: FolderReconciler.watchedVerifyInterval - 1)
        XCTAssertEqual(try queuedScans(store), ["folder:\(unhealthy)"])
        let verify = FolderReconciler.watchedVerifyInterval - 1 + FolderReconciler.interval
        try await reconciler.reconcile(now: verify)
        XCTAssertEqual(try queuedScans(store), ["folder:\(healthy)", "folder:\(unhealthy)"], "re-verified every 6 hours")
        // A completed full scan also counts as verification.
        let later = verify + FolderReconciler.watchedVerifyInterval
        try store.runOnDatabase { try $0.execute(sql: "UPDATE folder_sources SET last_full_scan_at=? WHERE id=?",
                                                  arguments: [later - 60, healthy]) }
        try await reconciler.reconcile(now: later)
        XCTAssertEqual(try queuedScans(store), ["folder:\(unhealthy)"])
        await reconciler.stop()
    }

    func testRuntimeWatchHealthOverflowAndWake() async throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "w").id)
        let folder = try store.createFolder(notebookId: notebook, draft: FolderDraft(rootPath: "/w", displayName: "W",
            includeExts: ["md"], ignoreGlobs: [], limitsJSON: "{}", encodingFallback: "cp1250", watchEnabled: true),
            identity: CadenceFS(), now: 0)
        let watches = CadenceWatches(), ms = CadenceBox<Int64>(1_000)
        let runtime = try FolderIngestionRuntime.make(store: store, admission: IngestionAdmission(), session: { _ in nil },
            clock: CadenceClock(), watches: watches, fileSystem: CadenceFS(), dispatch: false, milliseconds: { ms.value })
        var healthy = await runtime.isWatchHealthy(folderId: folder.id)
        XCTAssertFalse(healthy, "no watch before start")
        try await runtime.start()
        healthy = await runtime.isWatchHealthy(folderId: folder.id)
        XCTAssertTrue(healthy)
        while try await runtime.drainOnce() {} // the startup scan
        XCTAssertEqual(try store.folderSource(id: folder.id).scanState, "idle")
        func scanJobs() throws -> Int { try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM ingest_jobs WHERE kind='scan'")! } }
        let before = try scanJobs()

        // Wake: one debounced stat-only rescan of every watched folder.
        await runtime.systemDidWake()
        for _ in 0..<10_000 where try scanJobs() == before {
            // The finished startup scan releases its schedule asynchronously.
            try await runtime.tick(at: 1_000 + RescanSchedule.maximumCoalesce)
            await Task.yield()
        }
        XCTAssertEqual(try scanJobs(), before + 1)
        let wakeJob = try XCTUnwrap(store.runOnDatabase { try Int64.fetchOne($0, sql: "SELECT max(id) FROM ingest_jobs WHERE kind='scan'") })
        XCTAssertFalse(try store.scanOptions(jobId: wakeJob))

        // Lost events degrade the watch; periodic passes rescan it again.
        let issued = await runtime.token(folderId: folder.id)
        let token = try XCTUnwrap(issued)
        await runtime.receive(folderId: folder.id, token: token, kind: "overflow", at: 2_000)
        healthy = await runtime.isWatchHealthy(folderId: folder.id)
        XCTAssertFalse(healthy)
        await runtime.stop()
    }
}

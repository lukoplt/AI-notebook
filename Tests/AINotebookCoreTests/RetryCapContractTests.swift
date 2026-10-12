import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private final class MutableClock: IngestLeaseClock, @unchecked Sendable {
    private let gate = NSLock()
    private var value: Int64 = 1_000
    var current: Int64 {
        get { gate.lock(); defer { gate.unlock() }; return value }
        set { gate.lock(); value = newValue; gate.unlock() }
    }
    func now() -> Int64 { current }
    func wait(until: Int64) async throws { throw CancellationError() }
}

private struct NoWatches: FolderWatchFactory {
    struct Handle: FolderWatchHandle { func start() throws {} ; func stop() {} }
    func make(folder: FolderSource, onEvent: @escaping @Sendable (String) -> Void) throws -> any FolderWatchHandle { Handle() }
}

private struct FixedIdentity: FolderPathIdentity {
    func resolve(rootPath: String) throws -> FolderIdentity {
        FolderIdentity(volumeId: "v", components: ["docs"], rootFileId: "r")
    }
}

/// Frozen job fixture cases that pinned five attempts for extract jobs, replaced by
/// `ingestion-retry-cap-v1` §1a (its `supersedes` map: whole replacement cases).
/// The frozen files stay byte-identical; consumers swap in exactly the listed cases.
enum RetryCapSupersession {
    static func map() throws -> [String: [String: [String: Any]]] {
        try XCTUnwrap(SharedFixtures.json("contracts/ingestion-retry-cap-v1.json")["supersedes"] as? [String: [String: [String: Any]]])
    }

    /// The case row, or its replacement when the retry cap supersedes it.
    static func apply(_ row: [String: Any], fixture: String) throws -> [String: Any] {
        guard let name = row["name"] as? String, let replacement = try map()[fixture]?[name] else { return row }
        return replacement
    }

    /// The frozen fixture document with every superseded case replaced (for Codable harnesses).
    static func data(_ fixture: String) throws -> Data {
        var root = try SharedFixtures.json("contracts/\(fixture)")
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        root["cases"] = try cases.map { try apply($0, fixture: fixture) }
        return try JSONSerialization.data(withJSONObject: root)
    }
}

/// Shared `ingestion-retry-cap-v1` fixture plus the end-to-end failure budget:
/// a file that fails extraction three times is given up until its content
/// changes or the user retries.
@MainActor
final class RetryCapContractTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
    }

    private func fixture() throws -> [String: Any] {
        let fixture = try SharedFixtures.json("contracts/ingestion-retry-cap-v1.json")
        XCTAssertEqual(fixture["contract"] as? String, "ingestion-retry-cap")
        XCTAssertEqual(fixture["version"] as? Int, 1)
        return fixture
    }

    private func int64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }

    func testConstantsAndMigrationMatchFixture() throws {
        let fixture = try fixture()
        XCTAssertEqual(fixture["failureBudget"] as? Int, ExtractionRetryBudget.failures)
        XCTAssertEqual(fixture["extractMaxAttempts"] as? Int, ExtractionRetryBudget.extractMaxAttempts)
        XCTAssertEqual(fixture["migration"] as? String, "v21_extract_retry_budget")
        XCTAssertEqual((fixture["schemaDDL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       v21Schema.trimmingCharacters(in: .whitespacesAndNewlines))
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        try store.runOnDatabase { db in
            let columns = try Row.fetchAll(db, sql: """
                SELECT name,"notnull",dflt_value,pk FROM pragma_table_info('source_extract_budget') ORDER BY cid
                """).map { "\($0["name"] as String):\($0["notnull"] as Int):\(($0["dflt_value"] as String?) ?? "null"):\($0["pk"] as Int)" }
            XCTAssertEqual(columns, ["source_id:0:null:1", "failures:1:0:0", "content_hash:0:null:0"])
            let keys = try Row.fetchAll(db, sql: "SELECT \"table\",\"from\",on_delete FROM pragma_foreign_key_list('source_extract_budget')")
                .map { "\($0["table"] as String).\($0["from"] as String):\($0["on_delete"] as String)" }
            XCTAssertEqual(keys, ["sources.source_id:CASCADE"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations WHERE identifier='v21_extract_retry_budget'"), 1)
        }
    }

    func testUpgradeFromV18KeepsRowsWithAnEmptyBudget() throws {
        let (store, directory, _) = try V19TestStore.upgradeCopy(configuredKey: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.runOnDatabase { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM source_extract_budget"), 0)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    // MARK: Fixture

    /// Store-level harness of one case: every step runs the production entry point.
    @MainActor
    private final class Harness {
        let store: NotebookStore
        var fence: JobFence?
        var tokens = 0

        init() throws {
            store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
            _ = try store.createNotebook(name: "retry-cap")
            _ = try store.createFolder(notebookId: 1, draft: FolderDraft(rootPath: "/docs", displayName: "Docs",
                includeExts: FolderRules.defaults.includeExts, ignoreGlobs: FolderRules.defaults.ignoreGlobs, limitsJSON: "{}",
                encodingFallback: FolderRules.defaults.encodingFallback, watchEnabled: false), identity: FixedIdentity(), now: 0)
        }

        func token() -> String { tokens += 1; return "lease-\(tokens)" }
        var sourceId: Int64 { 1 }

        func extractJobCount() throws -> Int {
            try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM ingest_jobs WHERE kind='extract'") ?? 0 }
        }

        func observe(at: Int64, mtime: Int64, size: Int64, hash: String, verifyAll: Bool) throws -> [String: Any] {
            let stamp = FileStamp(identity: "file", mtimeNs: mtime, sizeBytes: size)
            let before = try extractJobCount()
            let scan = try store.requestFolderScan(folderId: 1, verifyAll: verifyAll, now: at)
            let lease = token()
            guard try store.claimJob(now: at, leaseToken: lease, id: scan) != nil,
                  let ticket = try store.beginFolderScan(folderId: 1, fence: JobFence(jobId: scan, leaseToken: lease), now: at) else {
                throw StorageV19Error.staleLease
            }
            let known = try store.folderKnownSources(folderId: 1)["a.docx"]
            let read = !FolderScanner.canSkipRead(known, stamp: stamp, verifyAll: verifyAll)
            _ = try store.observeFolderFiles(ticket: ticket, observations: [.file(FolderObservation(relPath: "a.docx", stamp: stamp,
                kind: "eligible", skipReason: nil, contentHash: read ? hash : nil))], now: at)
            XCTAssertTrue(try store.finishFolderScan(ticket: ticket, completion: ScanCompletion(completed: [""], incomplete: [],
                rootUnavailable: false, error: nil), now: at))
            return ["read": read, "queued": try extractJobCount() > before]
        }

        func run(_ step: [String: Any]) throws -> [String: Any] {
            let at = (step["at"] as! NSNumber).int64Value
            switch step["op"] as! String {
            case "observe":
                return try observe(at: at, mtime: (step["mtime"] as! NSNumber).int64Value, size: (step["size"] as! NSNumber).int64Value,
                                   hash: step["hash"] as! String, verifyAll: step["verifyAll"] as! Bool)
            case "loose":
                let raw = (step["rawPath"] as! Bool) ? "/nonexistent/retry-cap/a.txt" : nil
                if (step["url"] as? Bool) == true {
                    _ = try store.createSource(notebookId: 1, type: .web, title: "a", uri: "https://example.org/", rawPath: raw)
                } else {
                    _ = try store.createSource(notebookId: 1, type: .text, title: "a", uri: nil, rawPath: raw)
                }
                return [:]
            case "begin":
                let lease = token()
                fence = try store.beginExtraction(sourceId: sourceId, now: at, leaseToken: lease)
                return [:]
            case "abandon":
                guard let fence else { return ["abandoned": false] }
                self.fence = nil
                return ["abandoned": try store.abandonLooseExtraction(fence: fence, now: at)]
            case "claim":
                let lease = token()
                let job = try store.claimJob(now: at, leaseToken: lease)
                fence = job.map { JobFence(jobId: $0.id, leaseToken: lease) }
                return ["claimed": job != nil]
            case "fail":
                guard let fence else { return ["failed": false] }
                self.fence = nil
                return ["failed": try store.failJob(fence: fence, error: step["code"] as! String, now: at)]
            case "expire":
                return ["recovered": try store.recoverExpiredJobs(now: at)]
            case "requeue":
                return ["requeued": try store.requeueRetryableJobs(now: at)]
            case "publish":
                guard let fence else { return ["published": false] }
                self.fence = nil
                let draft = RevisionDraft(contentHash: step["hash"] as! String, canonicalText: "abc", textFormatVersion: 1, chunkerVersion: 2)
                let metadata = PublicationMetadata(encoding: "utf-8", lang: nil, coverageJSON: nil,
                    descriptorJSON: try SourceDescriptor(title: "a.docx", type: "docx", pageCount: 1, sheetCount: 0, sizeBytes: 3,
                                                         lang: nil).json(),
                    pages: [PageBoundary(page: 1, start: 0, end: 3)])
                guard let request = try store.extractionRequest(sourceId: sourceId) else {
                    // A loose source publishes without folder stat/rule checks.
                    let revision = try store.publishLooseExtraction(sourceId: sourceId, draft: draft, chunks: ScalarChunker.chunk("abc"),
                        metadata: metadata, embeddingSelection: nil, fence: fence, now: at)
                    return ["published": revision != nil]
                }
                let revision = try store.publishFolderExtraction(request: request, draft: draft, chunks: ScalarChunker.chunk("abc"),
                    metadata: metadata, embeddingSelection: nil, fence: fence, now: at)
                return ["published": revision != nil]
            case "retry":
                return ["retried": try store.retryFailedExtraction(sourceId: sourceId, now: at)]
            case "retryAll":
                return ["retried": try store.retryFailedExtractions(notebookId: 1, now: at)]
            case "upgrade":
                return ["requeued": try store.requeueUpgradedExtractions(now: at)]
            case "forget":
                try store.runOnDatabase { db in
                    try db.execute(sql: "DELETE FROM source_extract_budget")
                }
                return [:]
            default:
                throw StorageV19Error.invalidValue
            }
        }

        func snapshot(at: Int64) throws -> [String: Any] {
            let gaveUp = try store.gaveUpSourceIds(notebookId: 1)
            let source: Any = try store.runOnDatabase { db -> Any in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT s.id,s.status,s.error,coalesce(b.failures,0) AS extract_failures
                    FROM sources s LEFT JOIN source_extract_budget b ON b.source_id=s.id
                    """) else { return NSNull() }
                let id: Int64 = row["id"]
                return ["status": row["status"] as String, "error": (row["error"] as String?) ?? NSNull(),
                        "extractFailures": row["extract_failures"] as Int, "gaveUp": gaveUp.contains(id)] as [String: Any]
            }
            let jobs = try store.runOnDatabase { db in
                try Row.fetchAll(db, sql: "SELECT * FROM ingest_jobs WHERE kind='extract' ORDER BY id").map { row -> [String: Any] in
                    let options: String = row["options_json"]
                    return ["state": row["state"] as String, "attempts": row["attempts"] as Int,
                            "nextRetryAt": (row["next_retry_at"] as Int64?).map { NSNumber(value: $0) } ?? NSNull(),
                            "error": (row["error"] as String?) ?? NSNull(),
                            "options": try JSONSerialization.jsonObject(with: Data(options.utf8))]
                }
            }
            let status = try store.indexingStatus(notebookId: 1, now: at)
            return ["source": source, "extractJobs": jobs,
                    "indexing": ["active": status.isActive, "sourceErrors": status.sourceErrors]]
        }
    }

    func testFixtureCases() throws {
        let cases = try XCTUnwrap(try fixture()["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 24)
        for item in cases {
            let name = item["name"] as! String
            let harness = try Harness()
            for (index, row) in (item["steps"] as! [[String: Any]]).enumerated() {
                let step = row["step"] as! [String: Any]
                let label = "\(name) #\(index) \(step["op"] as! String)@\(step["at"]!)"
                let result = try harness.run(step)
                XCTAssertEqual(try json(result), try json(row["result"]!), label)
                let at = (step["at"] as! NSNumber).int64Value
                XCTAssertEqual(try json(harness.snapshot(at: at)), try json(row["expected"]!), label)
            }
        }
    }

    // MARK: End to end

    private func rig() throws -> (NotebookStore, FolderIngestionRuntime, MutableClock, Int64, URL) {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "retry-cap").id)
        let clock = MutableClock()
        let runtime = try FolderIngestionRuntime.make(store: store, admission: IngestionAdmission(),
            session: { _ in nil }, clock: clock, watches: NoWatches(), fileSystem: NativeFolderFileSystem(), dispatch: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retry-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("this is not a zip archive".utf8).write(to: root.appendingPathComponent("broken.docx"))
        directories.append(root)
        return (store, runtime, clock, notebook, root)
    }

    private func drainAll(_ runtime: FolderIngestionRuntime) async throws {
        for _ in 0..<50 where try await runtime.drainOnce() {}
    }

    private func extractAttempts(_ store: NotebookStore) throws -> Int {
        try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT coalesce(sum(attempts),0) FROM ingest_jobs WHERE kind='extract'") ?? 0 }
    }

    /// Runs extraction until nothing is due, making every pending retry due first.
    private func exhaust(_ store: NotebookStore, _ runtime: FolderIngestionRuntime, _ clock: MutableClock) async throws {
        for _ in 0..<6 {
            try await drainAll(runtime)
            clock.current += 1_000
            _ = try store.requeueRetryableJobs(now: clock.current)
        }
        try await drainAll(runtime)
    }

    func testThreeFailuresGiveUpAcrossRescansUntilContentChangesOrRetry() async throws {
        let (store, runtime, clock, notebook, root) = try rig()
        let folder = try await runtime.addFolder(notebookId: notebook, url: root)
        try await exhaust(store, runtime, clock)
        let sourceId = try XCTUnwrap(try store.sources(notebookId: notebook).first?.id)
        XCTAssertEqual(try extractAttempts(store), 3, "three attempts, then given up")
        XCTAssertEqual(try store.gaveUpSourceIds(notebookId: notebook), [sourceId])
        let source = try XCTUnwrap(try store.source(id: sourceId))
        XCTAssertEqual(source.status, .error)
        XCTAssertEqual(source.error, "corruptArchive")
        var status = try await runtime.indexingStatus(notebookId: notebook)
        XCTAssertFalse(status.isActive)
        XCTAssertEqual(status.sourceErrors, 1)

        // Plain scans, Verify all and the periodic reconciliation never try it again.
        for verifyAll in [false, true, false] {
            _ = try await runtime.scanNow(folderId: folder.id, verifyAll: verifyAll)
            try await exhaust(store, runtime, clock)
        }
        try await FolderReconciler(store: store, clock: clock, requestScan: { _, _ in }).reconcile(now: clock.current + 10_000)
        try await exhaust(store, runtime, clock)
        XCTAssertEqual(try extractAttempts(store), 3, "no fourth attempt")
        status = try await runtime.indexingStatus(notebookId: notebook)
        XCTAssertFalse(status.isActive)
        XCTAssertEqual(status.sourceErrors, 1)

        // An explicit retry gives three more attempts.
        let retried = try await runtime.retryFailedSource(sourceId: sourceId)
        XCTAssertTrue(retried)
        try await exhaust(store, runtime, clock)
        XCTAssertEqual(try extractAttempts(store), 6)
        XCTAssertEqual(try store.gaveUpSourceIds(notebookId: notebook), [sourceId])

        // New content resets the budget on the next scan.
        try Data("still not a zip archive, but different bytes".utf8).write(to: root.appendingPathComponent("broken.docx"))
        _ = try await runtime.scanNow(folderId: folder.id, verifyAll: false)
        try await exhaust(store, runtime, clock)
        XCTAssertEqual(try extractAttempts(store), 9)

        // Retry all from the strip's filtered view.
        let count = try await runtime.retryFailedSources(notebookId: notebook)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try store.source(id: sourceId)?.status, .pending)
        status = try await runtime.indexingStatus(notebookId: notebook)
        XCTAssertTrue(status.isActive)
    }

    /// A loose file follows the same rule: the folder worker re-reads it on the automatic retries,
    /// gives up after the third failure, and an explicit retry or re-ingest starts over.
    func testLooseFileGivesUpAfterThreeAttemptsAndRetries() async throws {
        let (store, runtime, clock, notebook, root) = try rig()
        let file = root.appendingPathComponent("broken.docx")
        let ingestion = IngestionService(store: store, leaseClock: clock, folderRuntime: runtime)
        do { _ = try await ingestion.ingestFile(file, into: notebook); XCTFail("a broken file must not publish") } catch {}
        let sourceId = try XCTUnwrap(try store.sources(notebookId: notebook).first?.id)
        XCTAssertNil(try store.source(id: sourceId)?.folderId)
        try await exhaust(store, runtime, clock)
        XCTAssertEqual(try extractAttempts(store), 3, "the foreground attempt and two automatic retries")
        XCTAssertEqual(try store.gaveUpSourceIds(notebookId: notebook), [sourceId])
        XCTAssertEqual(try store.source(id: sourceId)?.error, "corruptArchive")
        let status = try await runtime.indexingStatus(notebookId: notebook)
        XCTAssertFalse(status.isActive)
        XCTAssertEqual(status.sourceErrors, 1)

        let retried = try await runtime.retryFailedSource(sourceId: sourceId)
        XCTAssertTrue(retried)
        try await exhaust(store, runtime, clock)
        XCTAssertEqual(try extractAttempts(store), 6)
        XCTAssertEqual(try store.retryFailedExtractions(notebookId: notebook, now: clock.current), 1, "Retry all covers loose files")

        // A fixed file publishes on the explicit re-ingest and clears the budget.
        try FileManager.default.removeItem(at: file)
        let fixed = root.appendingPathComponent("fixed.md")
        try Data("now readable".utf8).write(to: fixed)
        try store.runOnDatabase { db in
            try db.execute(sql: "UPDATE sources SET raw_path=?,type='markdown' WHERE id=?", arguments: [fixed.path, sourceId])
        }
        try await exhaust(store, runtime, clock)
        XCTAssertEqual(try store.source(id: sourceId)?.status, .ready)
        XCTAssertEqual(try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM source_extract_budget") }, 0)
    }

    /// A loose web source is fetched only by an explicit user action (user decision 2026-10-11):
    /// a failed attempt is never retried automatically, and an explicit Retry fetches exactly once.
    func testLooseWebSourceIsFetchedOnlyOnExplicitRetry() async throws {
        final class Counter: @unchecked Sendable {
            private let gate = NSLock()
            private var value = 0
            func next() -> Int { gate.lock(); defer { value += 1; gate.unlock() }; return value }
            var count: Int { gate.lock(); defer { gate.unlock() }; return value }
        }
        struct FlakyWeb: TextExtractor {
            let calls: Counter
            func extract(from url: URL, kind: SourceType) async throws -> ExtractedText {
                if calls.next() < 1 { throw IngestionError(code: "unexpectedError") }
                return ExtractedText(title: "page", text: "Fetched on the explicit retry.")
            }
        }
        XCTAssertFalse(ExtractionRetryBudget.backgroundWebRetry)
        let calls = Counter()
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "web").id)
        let clock = MutableClock()
        let runtime = try FolderIngestionRuntime.make(store: store, admission: IngestionAdmission(), session: { _ in nil },
            clock: clock, watches: NoWatches(), fileSystem: NativeFolderFileSystem(), dispatch: false,
            web: FlakyWeb(calls: calls))
        let source = try store.createSource(notebookId: notebook, type: .web, title: "example.org",
                                            uri: "https://example.org/", rawPath: nil)
        let sourceId = try XCTUnwrap(source.id)
        // The foreground fetch failed: the job ends without an automatic retry.
        let fence = try store.beginExtraction(sourceId: sourceId, now: clock.current, leaseToken: "foreground")
        XCTAssertTrue(try store.failJob(fence: fence, error: "unexpectedError", now: clock.current))
        XCTAssertNil(try store.job(id: fence.jobId)?.nextRetryAt, "a URL is never retried automatically")
        try await exhaust(store, runtime, clock)
        XCTAssertEqual(calls.count, 0, "no background fetch")
        XCTAssertEqual(try store.source(id: sourceId)?.status, .error)

        // A queued automatic retry of a URL (e.g. a row from before this rule) is abandoned without a fetch.
        let legacy = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(sourceId)", targetRevision: nil),
                                          now: clock.current)
        try await exhaust(store, runtime, clock)
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(try store.job(id: legacy)?.error, ExtractionRetryBudget.retryUnavailable)

        // An explicit Retry fetches once (and fails); the next explicit Retry fetches once and publishes.
        let retried = try await runtime.retryFailedSource(sourceId: sourceId)
        XCTAssertTrue(retried)
        try await exhaust(store, runtime, clock)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(try store.source(id: sourceId)?.status, .error)
        XCTAssertEqual(try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT failures FROM source_extract_budget") }, 2,
                       "each user-initiated attempt counts")
        let retriedAgain = try await runtime.retryFailedSource(sourceId: sourceId)
        XCTAssertTrue(retriedAgain)
        try await exhaust(store, runtime, clock)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(try store.source(id: sourceId)?.status, .ready)
        XCTAssertEqual(try store.chunks(sourceId: sourceId).map(\.text).joined(), "Fetched on the explicit retry.")
    }

    /// A transient failure followed by a publication clears the counter.
    func testTransientFailureThenSuccessClearsTheBudget() async throws {
        let (store, runtime, clock, notebook, root) = try rig()
        try FileManager.default.removeItem(at: root.appendingPathComponent("broken.docx"))
        let file = root.appendingPathComponent("notes.md")
        try Data("hello".utf8).write(to: file)
        _ = try await runtime.addFolder(notebookId: notebook, url: root)
        _ = try await runtime.drainOnce() // scan
        let sourceId = try XCTUnwrap(try store.sources(notebookId: notebook).first?.id)
        // Two failed attempts (e.g. the file was locked), recorded through the fenced queue.
        for _ in 0..<2 {
            let lease = UUID().uuidString
            clock.current += 1_000
            _ = try store.requeueRetryableJobs(now: clock.current)
            let job = try XCTUnwrap(try store.claimJob(now: clock.current, leaseToken: lease))
            XCTAssertTrue(try store.failJob(fence: JobFence(jobId: job.id, leaseToken: lease), error: "unexpectedError", now: clock.current))
        }
        XCTAssertEqual(try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT failures FROM source_extract_budget") }, 2)
        clock.current += 1_000
        _ = try store.requeueRetryableJobs(now: clock.current)
        try await drainAll(runtime)
        XCTAssertEqual(try store.source(id: sourceId)?.status, .ready)
        XCTAssertEqual(try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM source_extract_budget") }, 0,
                       "a publication forgets the budget")
    }
}

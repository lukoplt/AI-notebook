import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private final class Box<Value>: @unchecked Sendable {
    private let gate = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { gate.lock(); defer { gate.unlock() }; return stored }
        set { gate.lock(); stored = newValue; gate.unlock() }
    }
}

private final class FixedClock: IngestLeaseClock, @unchecked Sendable {
    let current = Box<Int64>(1_000)
    func now() -> Int64 { current.value }
    func wait(until: Int64) async throws { throw CancellationError() }
}

private struct QuietWatches: FolderWatchFactory {
    struct Handle: FolderWatchHandle { func start() throws {} ; func stop() {} }
    func make(folder: FolderSource, onEvent: @escaping @Sendable (String) -> Void) throws -> any FolderWatchHandle { Handle() }
}

private struct UnitEmbedder: EmbeddingProducing {
    func embed(model: String, inputs: [String]) async throws -> [[Float]] { inputs.map { _ in [1, 0] } }
}

/// Collects the notebook IDs one store posts for a notification name.
@MainActor
private final class PostLog {
    private(set) var notebooks: [Int64] = []
    nonisolated(unsafe) private var token: NSObjectProtocol?
    init(store: NotebookStore, name: Notification.Name) {
        token = NotificationCenter.default.addObserver(forName: name, object: store, queue: nil) { [weak self] note in
            let id = note.userInfo?["notebookId"] as? Int64
            MainActor.assumeIsolated { if let id { self?.notebooks.append(id) } }
        }
    }
    func take() -> [Int64] { defer { notebooks = [] }; return notebooks }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

/// Shared `ingestion-reextract-v1` fixture plus the end-to-end recovery of
/// folder sources whose extraction failed under an older extractor.
@MainActor
final class ReextractContractTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
    }

    private func fixture() throws -> [String: Any] {
        let fixture = try SharedFixtures.json("contracts/ingestion-reextract-v1.json")
        XCTAssertEqual(fixture["contract"] as? String, "ingestion-reextract")
        XCTAssertEqual(fixture["version"] as? Int, 1)
        return fixture
    }

    private func int64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    func testConstantsMatchFixture() throws {
        let fixture = try fixture()
        XCTAssertEqual(fixture["extractorRevision"] as? Int, ExtractorRevision.current)
        XCTAssertEqual(fixture["optionsKey"] as? String, ExtractorRevision.optionsKey)
        XCTAssertEqual(fixture["retryableCodes"] as? [String], ExtractorRevision.retryableCodes)
        let options = try JSONSerialization.jsonObject(with: Data(ExtractorRevision.optionsJSON.utf8)) as? [String: Any]
        XCTAssertEqual(options?[ExtractorRevision.optionsKey] as? Int, ExtractorRevision.current)
    }

    func testFixtureCases() throws {
        let fixture = try fixture()
        let seed = try XCTUnwrap(fixture["seed"] as? [String: Any])
        let folder = try XCTUnwrap(seed["folder"] as? [String: Any])
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 20)
        for item in cases {
            let name = item["name"] as! String
            let input = item["input"] as! [String: Any], expected = item["expected"] as! [String: Any]
            let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
            let source = input["source"] as! [String: Any]
            let sourceId = int64(source["id"])!
            try store.runOnDatabase { db in
                let date = Date(timeIntervalSince1970: 0)
                try db.execute(sql: "INSERT INTO notebooks(id,name,created_at,updated_at) VALUES(?,'reextract',?,?)",
                               arguments: [int64(seed["notebookId"]), date, date])
                let identity = try json(["volumeId": folder["volumeId"]!, "components": folder["components"]!,
                                         "rootFileId": folder["rootFileId"]!])
                try db.execute(sql: """
                    INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,
                        limits,watch_enabled,created_at) VALUES(?,?,?,?,'Docs',?,?,'{}',0,?)
                    """, arguments: [int64(folder["id"]), int64(folder["notebookId"]), folder["rootPath"] as! String, identity,
                                      try json(FolderRules.defaults.includeExts), try json(FolderRules.defaults.ignoreGlobs), date])
                try db.execute(sql: """
                    INSERT INTO sources(id,notebook_id,type,title,status,error,ingested_at,folder_id,rel_path,availability,
                        eligible,content_hash) VALUES(?,?,'text','a.docx',?,?,?,?,?,?,?,?)
                    """, arguments: [sourceId, int64(source["notebookId"]), source["status"] as! String,
                                      source["error"] as? String, date, int64(source["folderId"]), source["relPath"] as? String,
                                      source["availability"] as! String, source["eligible"] as! Bool,
                                      source["contentHash"] as? String])
                for revision in input["revisions"] as! [[String: Any]] {
                    try db.execute(sql: """
                        INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,
                            chunker_version,created_at) VALUES(?,?,?,?,?,1,2,?)
                        """, arguments: [int64(revision["id"]), int64(revision["sourceId"]), int64(revision["revision"]),
                                          revision["contentHash"] as! String, revision["canonicalText"] as! String, date])
                }
                try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?",
                               arguments: [int64(source["currentRevision"]), int64(source["publishedRevisionId"]), sourceId])
                for job in input["jobs"] as! [[String: Any]] {
                    try db.execute(sql: """
                        INSERT INTO ingest_jobs(id,kind,target,target_revision,attempts,next_retry_at,state,error,options_json)
                        VALUES(?,?,?,?,?,?,?,?,?)
                        """, arguments: [int64(job["id"]), job["kind"] as! String, job["target"] as! String,
                                          int64(job["targetRevision"]), int64(job["attempts"]), int64(job["nextRetryAt"]),
                                          job["state"] as! String, job["error"] as? String, try json(job["options"]!)])
                }
            }
            let maxSeeded = (input["jobs"] as! [[String: Any]]).compactMap { int64($0["id"]) }.max() ?? 0
            let ingestion = PostLog(store: store, name: .folderIngestionDidChange)
            let status = PostLog(store: store, name: .indexingStatusDidChange)
            let count = try store.requeueUpgradedExtractions(now: int64(input["now"])!)
            XCTAssertEqual(count, expected["requeued"] as? Int, name)
            let notified = (expected["notified"] as! [NSNumber]).map(\.int64Value)
            XCTAssertEqual(ingestion.take(), notified, name)
            XCTAssertEqual(status.take(), notified, name)
            let row = try XCTUnwrap(try store.runOnDatabase { try Row.fetchOne($0, sql: "SELECT status,error FROM sources WHERE id=?",
                                                                                arguments: [sourceId]) })
            let expectedSource = expected["source"] as! [String: Any]
            XCTAssertEqual(row["status"] as String, expectedSource["status"] as? String, name)
            XCTAssertEqual(row["error"] as String?, expectedSource["error"] as? String, name)
            let created = try store.runOnDatabase { db in
                try Row.fetchAll(db, sql: "SELECT * FROM ingest_jobs WHERE id>? ORDER BY id", arguments: [maxSeeded])
            }
            guard let newJob = expected["newJob"] as? [String: Any] else {
                XCTAssertEqual(created.count, 0, name)
                continue
            }
            XCTAssertEqual(created.count, 1, name)
            let job = try XCTUnwrap(created.first)
            XCTAssertEqual(job["kind"] as String, newJob["kind"] as? String, name)
            XCTAssertEqual(job["target"] as String, newJob["target"] as? String, name)
            XCTAssertEqual(job["target_revision"] as Int64?, int64(newJob["targetRevision"]), name)
            XCTAssertEqual(job["state"] as String, newJob["state"] as? String, name)
            XCTAssertEqual(job["attempts"] as Int64, int64(newJob["attempts"]), name)
            XCTAssertEqual(job["next_retry_at"] as Int64?, int64(newJob["nextRetryAt"]), name)
            XCTAssertEqual(job["error"] as String?, newJob["error"] as? String, name)
            let options: String = job["options_json"]
            XCTAssertEqual(try json(JSONSerialization.jsonObject(with: Data(options.utf8))), try json(newJob["options"]!), name)
        }
    }

    // MARK: End to end

    private static let selection = EmbeddingSelection(providerId: "local", endpointRevision: "1", model: "m", modelDigest: nil,
        dims: nil, normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")

    private func rig() throws -> (NotebookStore, FolderIngestionRuntime, Int64, URL) {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "reextract").id)
        let session = FolderEmbeddingSession(selection: Self.selection, embedder: UnitEmbedder())
        let runtime = try FolderIngestionRuntime.make(store: store, admission: IngestionAdmission(),
            resolveSession: { _ in .ready(session) }, clock: FixedClock(), watches: QuietWatches(),
            fileSystem: NativeFolderFileSystem(), dispatch: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reextract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Upgraded extractors index files that failed before.\n".utf8).write(to: root.appendingPathComponent("a.md"))
        directories.append(root)
        return (store, runtime, notebook, root)
    }

    /// Adds the folder, runs only its first scan, then records the queued
    /// extraction as a terminal failure of an older extractor (never published).
    private func failedUnderOldExtractor(_ store: NotebookStore, _ runtime: FolderIngestionRuntime, _ notebook: Int64,
                                         _ root: URL, watch: Bool) async throws -> (FolderSource, Int64) {
        let folder = try await runtime.addFolder(notebookId: notebook, url: root)
        if !watch { try await runtime.setWatching(folderId: folder.id, enabled: false) }
        let scanned = try await runtime.drainOnce()
        XCTAssertTrue(scanned, "the first scan")
        let sourceId = try XCTUnwrap(try store.sources(notebookId: notebook).first?.id)
        try store.runOnDatabase { db in
            try db.execute(sql: """
                UPDATE ingest_jobs SET state='failed',attempts=5,next_retry_at=NULL,error='corruptArchive'
                WHERE kind='extract' AND target=?
                """, arguments: ["source:\(sourceId)"])
            try db.execute(sql: "UPDATE sources SET status='error',error='corruptArchive' WHERE id=?", arguments: [sourceId])
        }
        return (folder, sourceId)
    }

    private func drainAll(_ runtime: FolderIngestionRuntime) async throws {
        for _ in 0..<200 where try await runtime.drainOnce() {}
    }

    private func assertRecovered(_ store: NotebookStore, _ runtime: FolderIngestionRuntime, _ notebook: Int64,
                                 _ sourceId: Int64, file: StaticString = #filePath, line: UInt = #line) async throws {
        let source = try XCTUnwrap(try store.source(id: sourceId))
        XCTAssertEqual(source.status, .ready, file: file, line: line)
        XCTAssertNotNil(try store.runOnDatabase { try Int64.fetchOne($0, sql: "SELECT published_revision_id FROM sources WHERE id=?",
                                                                     arguments: [sourceId]) }, file: file, line: line)
        XCTAssertNotNil(try store.activeGeneration(notebookId: notebook), "the re-extracted source was embedded", file: file, line: line)
        let status = try await runtime.indexingStatus(notebookId: notebook)
        XCTAssertEqual(status.phase, .ready, file: file, line: line)
        XCTAssertEqual(status.sourceErrors, 0, file: file, line: line)
    }

    /// A scan never fast-paths a source in `error`: unchanged bytes are
    /// re-hashed and re-extracted by a plain scan and by Verify all.
    func testScanAndVerifyAllReextractErrorSourceWithUnchangedBytes() async throws {
        for verifyAll in [false, true] {
            let (store, runtime, notebook, root) = try rig()
            let (folder, sourceId) = try await failedUnderOldExtractor(store, runtime, notebook, root, watch: true)
            let status = PostLog(store: store, name: .indexingStatusDidChange)
            _ = try await runtime.scanNow(folderId: folder.id, verifyAll: verifyAll)
            let scanned = try await runtime.drainOnce()
            XCTAssertTrue(scanned)
            XCTAssertEqual(try store.source(id: sourceId)?.status, .pending, "verifyAll=\(verifyAll)")
            XCTAssertTrue(status.take().contains(notebook))
            try await drainAll(runtime)
            try await assertRecovered(store, runtime, notebook, sourceId)
        }
    }

    /// Runtime start requeues the old failure even for a folder that is not
    /// watched (no startup scan), posts live updates, and the publication
    /// queues embedding. A failure under the current revision is not requeued again.
    func testStartRequeuesUpgradedFailureOnUnwatchedFolderAndEmbeds() async throws {
        let (store, runtime, notebook, root) = try rig()
        let (folder, sourceId) = try await failedUnderOldExtractor(store, runtime, notebook, root, watch: false)
        let ingestion = PostLog(store: store, name: .folderIngestionDidChange)
        try await runtime.start()
        XCTAssertTrue(ingestion.take().contains(notebook))
        XCTAssertEqual(try store.source(id: sourceId)?.status, .pending)
        let jobs = try store.runOnDatabase { db in
            try Row.fetchAll(db, sql: "SELECT kind,state,options_json FROM ingest_jobs WHERE state='queued' ORDER BY id")
        }
        XCTAssertEqual(jobs.map { $0["kind"] as String }, ["extract"], "no scan for an unwatched folder")
        XCTAssertEqual(jobs.first?["options_json"] as String?, #"{"extractorRevision":2}"#)
        var status = try await runtime.indexingStatus(notebookId: notebook)
        XCTAssertEqual(status.phase, .extracting(done: 0, total: 1))
        try await drainAll(runtime)
        try await assertRecovered(store, runtime, notebook, sourceId)

        // The same failure under the current extractor stays failed on the next reconciliation.
        try store.runOnDatabase { db in
            try db.execute(sql: """
                UPDATE ingest_jobs SET state='failed',attempts=5,next_retry_at=NULL,error='corruptArchive'
                WHERE kind='extract' AND options_json='{"extractorRevision":2}'
                """)
            try db.execute(sql: "UPDATE sources SET status='error',error='corruptArchive' WHERE id=?", arguments: [sourceId])
        }
        XCTAssertEqual(try store.requeueUpgradedExtractions(now: 2_000), 0)
        status = try await runtime.indexingStatus(notebookId: notebook)
        XCTAssertEqual(status.sourceErrors, 1)
        // Verify all remains the explicit retry.
        _ = try await runtime.scanNow(folderId: folder.id, verifyAll: true)
        try await drainAll(runtime)
        XCTAssertEqual(try store.source(id: sourceId)?.status, .ready)
        await runtime.stop()
    }
}

/// `ingestion-reextract-v2` (contract `ingestion-reextract-v1` §7): throttled
/// re-extraction of ready folder spreadsheets published under an older
/// spreadsheet canonical text, plus the end-to-end upgrade to `ingestion-xlsx-v2`.
@MainActor
final class SpreadsheetUpgradeTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
    }

    private func int64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private func fixture() throws -> [String: Any] {
        let fixture = try SharedFixtures.json("contracts/ingestion-reextract-v2.json")
        XCTAssertEqual(fixture["contract"] as? String, "ingestion-reextract")
        XCTAssertEqual(fixture["version"] as? Int, 2)
        return fixture
    }

    func testConstantsMatchFixture() throws {
        let fixture = try fixture()
        XCTAssertEqual(fixture["spreadsheetTextVersion"] as? Int, ExtractorRevision.spreadsheetTextVersion)
        XCTAssertEqual(fixture["spreadsheetOptionsKey"] as? String, ExtractorRevision.spreadsheetOptionsKey)
        XCTAssertEqual(fixture["batchSize"] as? Int, ExtractorRevision.spreadsheetBatchSize)
        XCTAssertEqual(ExtractorRevision.spreadsheetOptionsJSON, #"{"spreadsheetTextVersion":2}"#)
    }

    func testFixtureCases() throws {
        let fixture = try fixture()
        let seed = try XCTUnwrap(fixture["seed"] as? [String: Any])
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 20)
        for item in cases {
            let name = item["name"] as! String
            let input = item["input"] as! [String: Any], expected = item["expected"] as! [String: Any]
            let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
            try store.runOnDatabase { db in
                let date = Date(timeIntervalSince1970: 0)
                for notebook in seed["notebooks"] as! [NSNumber] {
                    try db.execute(sql: "INSERT INTO notebooks(id,name,created_at,updated_at) VALUES(?,'upgrade',?,?)",
                                   arguments: [notebook.int64Value, date, date])
                }
                for folder in seed["folders"] as! [[String: Any]] {
                    let identity = try json(["volumeId": folder["volumeId"]!, "components": folder["components"]!,
                                             "rootFileId": folder["rootFileId"]!])
                    try db.execute(sql: """
                        INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,
                            limits,watch_enabled,created_at) VALUES(?,?,?,?,'Docs',?,?,'{}',0,?)
                        """, arguments: [int64(folder["id"]), int64(folder["notebookId"]), folder["rootPath"] as! String, identity,
                                          try json(FolderRules.defaults.includeExts), try json(FolderRules.defaults.ignoreGlobs), date])
                }
                for source in input["sources"] as! [[String: Any]] {
                    try db.execute(sql: """
                        INSERT INTO sources(id,notebook_id,type,title,status,error,ingested_at,folder_id,rel_path,availability,
                            eligible,content_hash) VALUES(?,?,?,'s',?,?,?,?,?,?,?,?)
                        """, arguments: [int64(source["id"]), int64(source["notebookId"]), source["type"] as! String,
                                          source["status"] as! String, source["error"] as? String, date, int64(source["folderId"]),
                                          source["relPath"] as? String, source["availability"] as! String,
                                          source["eligible"] as! Bool, source["contentHash"] as? String])
                }
                for revision in input["revisions"] as! [[String: Any]] {
                    try db.execute(sql: """
                        INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,
                            chunker_version,created_at) VALUES(?,?,?,?,?,?,2,?)
                        """, arguments: [int64(revision["id"]), int64(revision["sourceId"]), int64(revision["revision"]),
                                          revision["contentHash"] as! String, revision["canonicalText"] as! String,
                                          int64(revision["textFormatVersion"]), date])
                }
                for source in input["sources"] as! [[String: Any]] {
                    try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?",
                                   arguments: [int64(source["currentRevision"]), int64(source["publishedRevisionId"]),
                                               int64(source["id"])])
                }
                for job in input["jobs"] as! [[String: Any]] {
                    try db.execute(sql: """
                        INSERT INTO ingest_jobs(id,kind,target,target_revision,attempts,next_retry_at,state,error,options_json,
                            lease_token,lease_until) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                        """, arguments: [int64(job["id"]), job["kind"] as! String, job["target"] as! String,
                                          int64(job["targetRevision"]), int64(job["attempts"]), int64(job["nextRetryAt"]),
                                          job["state"] as! String, job["error"] as? String, try json(job["options"]!),
                                          job["leaseToken"] as? String, int64(job["leaseUntil"])])
                }
            }
            let maxSeeded = try store.runOnDatabase { try Int64.fetchOne($0, sql: "SELECT coalesce(max(id),0) FROM ingest_jobs") } ?? 0
            let ingestion = PostLog(store: store, name: .folderIngestionDidChange)
            let count = try store.requeueSpreadsheetUpgrades(now: int64(input["now"])!)
            XCTAssertEqual(count, expected["requeued"] as? Int, name)
            XCTAssertEqual(ingestion.take(), (expected["notified"] as! [NSNumber]).map(\.int64Value), name)
            for source in expected["sources"] as! [[String: Any]] {
                let row = try XCTUnwrap(try store.runOnDatabase {
                    try Row.fetchOne($0, sql: "SELECT status,error FROM sources WHERE id=?", arguments: [int64(source["id"])]) })
                XCTAssertEqual(row["status"] as String, source["status"] as? String, name)
                XCTAssertEqual(row["error"] as String?, source["error"] as? String, name)
            }
            let created = try store.runOnDatabase { db in
                try Row.fetchAll(db, sql: "SELECT * FROM ingest_jobs WHERE id>? ORDER BY id", arguments: [maxSeeded])
            }
            let newJobs = expected["newJobs"] as! [[String: Any]]
            XCTAssertEqual(created.count, newJobs.count, name)
            for (job, want) in zip(created, newJobs) {
                XCTAssertEqual(job["kind"] as String, want["kind"] as? String, name)
                XCTAssertEqual(job["target"] as String, want["target"] as? String, name)
                XCTAssertEqual(job["target_revision"] as Int64?, int64(want["targetRevision"]), name)
                XCTAssertEqual(job["state"] as String, want["state"] as? String, name)
                XCTAssertEqual(job["attempts"] as Int64, int64(want["attempts"]), name)
                XCTAssertEqual(job["next_retry_at"] as Int64?, int64(want["nextRetryAt"]), name)
                XCTAssertEqual(job["error"] as String?, want["error"] as? String, name)
                let options: String = job["options_json"]
                XCTAssertEqual(try json(JSONSerialization.jsonObject(with: Data(options.utf8))), try json(want["options"]!), name)
            }
        }
    }

    func testRevisionsRecordTheSpreadsheetTextFormat() throws {
        XCTAssertEqual(FolderExtractionWorker.textFormatVersion(kind: "xlsx"), 2)
        for kind in ["text", "markdown", "pdf", "docx", "pptx", "email"] {
            XCTAssertEqual(FolderExtractionWorker.textFormatVersion(kind: kind), 1, kind)
        }
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "formats").id)
        let source = try store.createSource(notebookId: notebook, type: .xlsx, title: "s", uri: nil, rawPath: nil)
        let sourceId = try XCTUnwrap(source.id)
        for (format, accepted) in [(1, true), (2, true), (0, false), (3, false)] {
            let draft = RevisionDraft(contentHash: "h\(format)", canonicalText: "R1: x", textFormatVersion: format, chunkerVersion: 2)
            do {
                let revision = try store.runOnDatabase { try RevisionJobSQL.insertRevision($0, sourceId: sourceId, draft: draft, now: 1) }
                XCTAssertTrue(accepted, "format \(format)")
                XCTAssertEqual(try store.revision(id: revision.id)?.draft.textFormatVersion, format)
            } catch {
                XCTAssertFalse(accepted, "format \(format): \(error)")
            }
        }
    }

    // MARK: End to end

    private static let selection = EmbeddingSelection(providerId: "local", endpointRevision: "1", model: "m", modelDigest: nil,
        dims: nil, normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")

    /// Ten workbooks published under the v1 spreadsheet text in an unwatched
    /// folder: start queues one batch of eight, every finished upgrade refills
    /// the batch, the old revisions stay searchable until replaced, and the
    /// final revisions carry the v2 text and are embedded.
    func testStartUpgradesPublishedSpreadsheetsInBatches() async throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "upgrade").id)
        let session = FolderEmbeddingSession(selection: Self.selection, embedder: UnitEmbedder())
        let runtime = try FolderIngestionRuntime.make(store: store, admission: IngestionAdmission(),
            resolveSession: { _ in .ready(session) }, clock: FixedClock(), watches: QuietWatches(),
            fileSystem: NativeFolderFileSystem(), dispatch: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xlsx-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directories.append(root)
        let workbook = try SharedFixtures.data("ingestion/workbook.xlsx")
        for index in 0..<10 { try workbook.write(to: root.appendingPathComponent(String(format: "w%02d.xlsx", index))) }
        try Data("Notes stay untouched.\n".utf8).write(to: root.appendingPathComponent("notes.md"))
        let folder = try await runtime.addFolder(notebookId: notebook, url: root)
        try await runtime.setWatching(folderId: folder.id, enabled: false)
        for _ in 0..<200 where try await runtime.drainOnce() {}
        let expected = try XCTUnwrap(SpreadsheetSupersession.map()["ingestion-office-v1.json"]?["workbook-order"]?["text"] as? String)

        // Publish, for every spreadsheet, a revision of the same bytes as the v1 reader produced it.
        let old = "## Zeta\nA1: Příliš\tC1: A😀B"
        let hashes = try store.runOnDatabase { db in
            try Row.fetchAll(db, sql: "SELECT id,content_hash FROM sources WHERE type='xlsx' ORDER BY id")
                .map { ($0["id"] as Int64, $0["content_hash"] as String) }
        }
        var published: [Int64: Int64] = [:]
        for (sourceId, hash) in hashes {
            let revision = try store.commitForegroundRevision(sourceId: sourceId,
                draft: RevisionDraft(contentHash: hash, canonicalText: old, textFormatVersion: 1, chunkerVersion: 2),
                chunks: [RevisionChunkDraft(text: old, tokenCount: 7, pageHint: nil, charStart: 0,
                                            charEnd: old.unicodeScalars.count, lang: nil, langInherited: false)],
                now: 1_000, leaseToken: "v1-\(sourceId)")
            published[sourceId] = revision.id
        }
        for _ in 0..<50 where try await runtime.drainOnce() {}
        XCTAssertEqual(published.count, 10)

        try await runtime.start()
        let queued = try store.runOnDatabase { db in
            try Row.fetchAll(db, sql: "SELECT target,options_json FROM ingest_jobs WHERE kind='extract' AND state='queued' ORDER BY id")
        }
        XCTAssertEqual(queued.count, ExtractorRevision.spreadsheetBatchSize)
        XCTAssertEqual(Set(queued.map { $0["options_json"] as String }), [ExtractorRevision.spreadsheetOptionsJSON])
        let sorted = published.keys.sorted()
        XCTAssertEqual(queued.map { $0["target"] as String }, sorted.prefix(8).map { "source:\($0)" })
        for (sourceId, revision) in published {
            let source = try XCTUnwrap(try store.source(id: sourceId))
            XCTAssertEqual(source.status, .ready, "still searchable while queued")
            XCTAssertEqual(source.publishedRevisionId, revision)
        }

        // One finished upgrade refills the batch with the next source.
        let drained = try await runtime.drainOnce()
        XCTAssertTrue(drained)
        let afterOne = try store.runOnDatabase { db in
            try String.fetchAll(db, sql: "SELECT target FROM ingest_jobs WHERE state='queued' AND options_json=? ORDER BY id",
                                arguments: [ExtractorRevision.spreadsheetOptionsJSON])
        }
        XCTAssertEqual(afterOne.count, 8)
        XCTAssertEqual(afterOne.last, "source:\(sorted[8])")

        for _ in 0..<400 where try await runtime.drainOnce() {}
        for sourceId in sorted {
            let source = try XCTUnwrap(try store.source(id: sourceId))
            XCTAssertEqual(source.status, .ready)
            let revision = try XCTUnwrap(try store.revision(id: XCTUnwrap(source.publishedRevisionId)))
            XCTAssertNotEqual(revision.id, published[sourceId])
            XCTAssertEqual(revision.draft.textFormatVersion, 2)
            XCTAssertEqual(revision.draft.canonicalText, expected)
        }
        XCTAssertEqual(try store.requeueSpreadsheetUpgrades(now: 5_000), 0, "every spreadsheet is current")
        XCTAssertNotNil(try store.activeGeneration(notebookId: notebook))
        let status = try await runtime.indexingStatus(notebookId: notebook)
        XCTAssertEqual(status.phase, .ready)
        XCTAssertEqual(status.sourceErrors, 0)
        await runtime.stop()
    }
}

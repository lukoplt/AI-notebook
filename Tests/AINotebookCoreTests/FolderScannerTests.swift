import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private struct ScanIdentity: FolderPathIdentity {
    func resolve(rootPath: String) throws -> FolderIdentity {
        FolderIdentity(volumeId: "test", components: ["docs"], rootFileId: "root-1")
    }
}

private final class ScanCalls: @unchecked Sendable {
    private let gate = NSLock()
    private var listed: [String] = []
    private var read: [String] = []
    private var cancel = false
    func list(_ path: String) { gate.lock(); defer { gate.unlock() }; listed.append(path) }
    func hash(_ path: String) { gate.lock(); defer { gate.unlock() }; read.append(path) }
    func requestCancel() { gate.lock(); defer { gate.unlock() }; cancel = true }
    var lists: [String] { gate.lock(); defer { gate.unlock() }; return listed }
    var reads: [String] { gate.lock(); defer { gate.unlock() }; return read }
    var cancelled: Bool { gate.lock(); defer { gate.unlock() }; return cancel }
}

private final class FixedClock: IngestLeaseClock, @unchecked Sendable {
    private let gate = NSLock()
    private var value: Int64
    init(_ value: Int64) { self.value = value }
    func set(_ next: Int64) { gate.lock(); defer { gate.unlock() }; value = next }
    func now() -> Int64 { gate.lock(); defer { gate.unlock() }; return value }
    func wait(until: Int64) async throws { throw CancellationError() }
}

private struct UnexpectedFailure: Error {}

private final class NotificationRecorder: @unchecked Sendable {
    private let gate = NSLock()
    private var ids: [Int64] = []
    private var token: NSObjectProtocol?
    func attach(_ store: NotebookStore) {
        detach()
        reset()
        let observer = NotificationCenter.default.addObserver(forName: .folderIngestionDidChange, object: store, queue: nil) { [weak self] note in
            self?.append(note.userInfo?["notebookId"] as? Int64 ?? -1)
        }
        gate.lock(); token = observer; gate.unlock()
    }
    func detach() {
        gate.lock(); let current = token; token = nil; gate.unlock()
        if let current { NotificationCenter.default.removeObserver(current) }
    }
    private func append(_ id: Int64) { gate.lock(); defer { gate.unlock() }; ids.append(id) }
    func reset() { gate.lock(); defer { gate.unlock() }; ids = [] }
    var values: [Int64] { gate.lock(); defer { gate.unlock() }; return ids }
}

/// A scripted filesystem interpreted from fixture listings; it never returns a
/// prepared completion. Directory stamps are synthetic and stable.
private struct ScriptedScanFS: FolderFileSystem {
    var directories: [String: [FolderEntry]] = [:]
    var files: [String: FileStamp] = [:]
    var hashes: [String: (FileStamp, String)] = [:]
    var denied: Set<String> = []
    var broken: Set<String> = []
    var rootOffline = false
    var cancelAfterRootList = false
    var sensitive = true
    let calls: ScanCalls

    static func directoryStamp(_ path: String) -> FileStamp {
        FileStamp(identity: "dir:" + path, mtimeNs: 0, sizeBytes: 0)
    }
    func resolve(rootPath: String) throws -> FolderIdentity { try ScanIdentity().resolve(rootPath: rootPath) }
    func caseSensitive(root: FolderSource) throws -> Bool {
        if rootOffline { throw IngestionError(code: "rootUnavailable") }
        return sensitive
    }
    func list(root: FolderSource, directory: String) throws -> [FolderEntry] {
        calls.list(directory)
        if cancelAfterRootList && directory.isEmpty { calls.requestCancel() }
        if denied.contains(directory) { throw CocoaError(.fileReadNoPermission) }
        return try XCTUnwrap(directories[directory], "unexpected list: \(directory)")
    }
    func stat(root: FolderSource, relativePath: String) throws -> FileStamp {
        if broken.contains(relativePath) { throw UnexpectedFailure() }
        if relativePath.isEmpty || directories[relativePath] != nil || denied.contains(relativePath) {
            return Self.directoryStamp(relativePath)
        }
        return try XCTUnwrap(files[relativePath], "unexpected stat: \(relativePath)")
    }
    func hash(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderRead {
        calls.hash(relativePath)
        let value = try XCTUnwrap(hashes[relativePath], "unexpected read: \(relativePath)")
        return FolderRead(bytes: Data(), stamp: value.0, sha256: value.1)
    }
    func snapshot(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderFileSnapshot {
        XCTFail("scanner must not snapshot file bodies")
        throw UnexpectedFailure()
    }
}

private func int64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
private func stamp(_ value: Any?) -> FileStamp {
    let v = value as! [String: Any]
    return FileStamp(identity: v["identity"] as! String, mtimeNs: int64(v["mtimeNs"])!, sizeBytes: int64(v["sizeBytes"])!)
}
private func json(_ value: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}
private func null(_ value: Any?) -> Any { value ?? NSNull() }

@MainActor
final class FolderScannerTests: XCTestCase {
    private let recorder = NotificationRecorder()
    private var notifications: [Int64] {
        get { recorder.values }
        set { recorder.reset() }
    }

    override func tearDown() async throws {
        recorder.detach()
    }

    private func watch(_ store: NotebookStore) { recorder.attach(store) }

    private func cases(_ file: String, _ operations: Set<String>) throws -> [[String: Any]] {
        let rows = try XCTUnwrap(SharedFixtures.json("contracts/\(file)")["cases"] as? [[String: Any]])
        return rows.filter { operations.contains($0["operation"] as? String ?? "") }
    }

    // MARK: Seeding and projection

    private func makeStore(ignoreGlobs: [String] = FolderRules.defaults.ignoreGlobs, limitsJSON: String = "{}",
                           notebooks: Int = 1, folderNotebook: Int64 = 1) throws -> NotebookStore {
        let store = try NotebookStore(path: .inMemory)
        for index in 1...notebooks {
            XCTAssertEqual(try store.createNotebook(name: "nb\(index)").id, Int64(index))
        }
        let folder = try store.createFolder(notebookId: folderNotebook, draft: FolderDraft(rootPath: "/docs", displayName: "Docs",
            includeExts: FolderRules.defaults.includeExts, ignoreGlobs: ignoreGlobs, limitsJSON: limitsJSON,
            encodingFallback: "cp1250", watchEnabled: true), identity: ScanIdentity(), now: 0)
        XCTAssertEqual(folder.id, 1)
        return store
    }

    private func seed(_ store: NotebookStore, _ state: [String: Any]) throws {
        try store.runOnDatabase { db in
            let folder = state["folder"] as! [String: Any]
            try db.execute(sql: """
                UPDATE folder_sources SET scan_state=?,scan_generation=?,last_full_scan_at=?,last_scan_error=? WHERE id=?
                """, arguments: [folder["scanState"] as! String, int64(folder["scanGeneration"]), int64(folder["lastFullScanAt"]),
                                  folder["lastScanError"] as? String, int64(folder["id"])])
            for source in state["sources"] as! [[String: Any]] {
                try db.execute(sql: """
                    INSERT INTO sources(id,notebook_id,type,title,uri,raw_path,status,error,ingested_at,folder_id,rel_path,
                        mtime,size_bytes,availability,eligible,content_hash) VALUES(?,?,'markdown',?,NULL,NULL,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [int64(source["id"]), int64(source["notebookId"]), source["relPath"] as! String,
                                      source["status"] as! String, source["error"] as? String, Date(timeIntervalSince1970: 0),
                                      int64(source["folderId"]), source["relPath"] as! String, int64(source["mtimeNs"]),
                                      int64(source["sizeBytes"]), source["availability"] as! String,
                                      source["eligible"] as! Bool, source["contentHash"] as? String])
            }
            var ordinals: [Int64: Int] = [:]
            for revision in state["revisions"] as! [[String: Any]] {
                let sourceId = int64(revision["sourceId"])!
                ordinals[sourceId, default: 0] += 1
                try db.execute(sql: """
                    INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,
                        chunker_version,created_at) VALUES(?,?,?,'h',?,1,2,?)
                    """, arguments: [int64(revision["id"]), sourceId, ordinals[sourceId]!,
                                      revision["canonicalText"] as! String, Date(timeIntervalSince1970: 0)])
                for (ord, chunk) in (revision["chunks"] as! [[String: Any]]).enumerated() {
                    try db.execute(sql: """
                        INSERT INTO source_chunks(source_id,revision_id,ord,text,token_count,char_start,char_end)
                        VALUES(?,?,?,?,1,?,?)
                        """, arguments: [sourceId, int64(revision["id"]), ord, chunk["text"] as! String,
                                          int64(chunk["start"]), int64(chunk["end"])])
                }
            }
            for source in state["sources"] as! [[String: Any]] {
                try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?",
                               arguments: [int64(source["currentRevision"]), int64(source["publishedRevisionId"]), int64(source["id"])])
            }
            for job in state["jobs"] as! [[String: Any]] {
                let running = job["state"] as? String == "running"
                try db.execute(sql: """
                    INSERT INTO ingest_jobs(id,kind,target,target_revision,attempts,next_retry_at,state,lease_until,lease_token)
                    VALUES(?,?,?,?,?,?,?,?,?)
                    """, arguments: [int64(job["id"]), job["kind"] as! String, job["target"] as! String,
                                      int64(job["targetRevision"]), int64(job["attempts"]), running ? nil : Int64(0),
                                      job["state"] as! String, int64(job["leaseUntil"]), job["leaseToken"] as? String])
            }
            if (state["jobs"] as! [[String: Any]]).isEmpty {
                // Fixture job IDs are allocated after the canonical scan job 201 even when it is absent.
                try db.execute(sql: "DELETE FROM sqlite_sequence WHERE name='ingest_jobs'")
                try db.execute(sql: "INSERT INTO sqlite_sequence(name,seq) VALUES('ingest_jobs',201)")
            }
            for item in state["inventory"] as! [[String: Any]] {
                try db.execute(sql: """
                    INSERT INTO scan_items(folder_id,rel_path,kind,skip_reason,mtime,size_bytes,seen_generation) VALUES(?,?,?,?,?,?,?)
                    """, arguments: [int64(item["folderId"]), item["relPath"] as! String, item["kind"] as! String,
                                      item["skipReason"] as? String, int64(item["mtimeNs"]), int64(item["sizeBytes"]),
                                      int64(item["seenGeneration"])])
            }
        }
    }

    private func projection(_ store: NotebookStore, reads: Int, lists: [String]) throws -> [String: Any] {
        try store.runOnDatabase { db in
            let folder = try Row.fetchOne(db, sql: "SELECT * FROM folder_sources WHERE id=1")!
            let sources = try Row.fetchAll(db, sql: "SELECT * FROM sources WHERE folder_id IS NOT NULL ORDER BY id").map { row -> [String: Any] in
                let eligible: Bool = row["eligible"]
                return ["id": row["id"] as Int64, "notebookId": row["notebook_id"] as Int64, "folderId": row["folder_id"] as Int64,
                        "relPath": row["rel_path"] as String, "status": row["status"] as String,
                        "availability": row["availability"] as String, "eligible": eligible,
                        "currentRevision": null(row["current_revision"] as Int64?),
                        "publishedRevisionId": null(row["published_revision_id"] as Int64?),
                        "contentHash": null(row["content_hash"] as String?), "mtimeNs": null(row["mtime"] as Int64?),
                        "sizeBytes": null(row["size_bytes"] as Int64?), "error": null(row["error"] as String?)]
            }
            let revisions = try Row.fetchAll(db, sql: "SELECT * FROM source_revisions ORDER BY id").map { row -> [String: Any] in
                let id: Int64 = row["id"]
                let chunks = try Row.fetchAll(db, sql: "SELECT * FROM source_chunks WHERE revision_id=? ORDER BY ord", arguments: [id]).map {
                    ["text": $0["text"] as String, "start": null($0["char_start"] as Int64?), "end": null($0["char_end"] as Int64?)] as [String: Any]
                }
                return ["id": id, "sourceId": row["source_id"] as Int64, "canonicalText": row["canonical_text"] as String, "chunks": chunks]
            }
            let inventory = try Row.fetchAll(db, sql: "SELECT * FROM scan_items ORDER BY CAST(rel_path AS BLOB)").map {
                ["folderId": $0["folder_id"] as Int64, "relPath": $0["rel_path"] as String, "kind": $0["kind"] as String,
                 "skipReason": null($0["skip_reason"] as String?), "mtimeNs": null($0["mtime"] as Int64?),
                 "sizeBytes": null($0["size_bytes"] as Int64?), "seenGeneration": $0["seen_generation"] as Int64] as [String: Any]
            }
            let jobs = try Row.fetchAll(db, sql: "SELECT * FROM ingest_jobs ORDER BY id").map {
                ["id": $0["id"] as Int64, "kind": $0["kind"] as String, "target": $0["target"] as String,
                 "targetRevision": null($0["target_revision"] as Int64?), "state": $0["state"] as String,
                 "attempts": $0["attempts"] as Int64, "leaseToken": null($0["lease_token"] as String?),
                 "leaseUntil": null($0["lease_until"] as Int64?)] as [String: Any]
            }
            return ["folder": ["id": folder["id"] as Int64, "notebookId": folder["notebook_id"] as Int64,
                               "scanState": folder["scan_state"] as String, "scanGeneration": folder["scan_generation"] as Int64,
                               "lastFullScanAt": null(folder["last_full_scan_at"] as Int64?),
                               "lastScanError": null(folder["last_scan_error"] as String?)] as [String: Any],
                    "sources": sources, "revisions": revisions, "inventory": inventory, "jobs": jobs,
                    "readCalls": reads, "listCalls": lists]
        }
    }

    private func storeFor(_ row: [String: Any]) throws -> NotebookStore {
        let input = row["input"] as! [String: Any]
        let limits = int64(input["maxFileBytes"]).map { #"{"maxFileBytes":\#($0)}"# } ?? "{}"
        let store = try makeStore(ignoreGlobs: input["ignoreGlobs"] as? [String] ?? FolderRules.defaults.ignoreGlobs, limitsJSON: limits)
        try seed(store, input["seed"] as! [String: Any])
        return store
    }

    private func ensureClaimed(_ store: NotebookStore, _ event: [String: Any]) throws -> JobFence {
        let id = int64(event["jobId"])!, token = event["leaseToken"] as! String, at = int64(event["at"])!
        if try store.job(id: id) == nil {
            let created = try store.enqueueJob(IngestJobDraft(kind: "scan", target: "folder:\(int64(event["folderId"])!)",
                                                              targetRevision: nil, optionsJSON: #"{"verifyAll":false}"#), now: at)
            XCTAssertEqual(created, id)
            XCTAssertNotNil(try store.claimJob(now: at, leaseToken: token, id: id))
        }
        return JobFence(jobId: id, leaseToken: token)
    }

    private func retrievalIds(_ store: NotebookStore) throws -> (eligible: [Int64], retrieval: [Int64]) {
        try store.runOnDatabase { db in
            (try Int64.fetchAll(db, sql: "SELECT id FROM sources WHERE eligible=1 ORDER BY id"),
             try Int64.fetchAll(db, sql: """
                SELECT id FROM sources WHERE eligible=1 AND availability='present' AND published_revision_id IS NOT NULL ORDER BY id
                """))
        }
    }

    // MARK: Tests

    func testObservedChangeKeepsPublishedSearchable() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "scan")
        let folder = try store.createFolder(notebookId: nb.id!, draft: FolderDraft(
            rootPath: "/docs", displayName: "Docs", includeExts: ["md"], ignoreGlobs: [],
            limitsJSON: "{}", encodingFallback: "cp1250", watchEnabled: true), identity: ScanIdentity(), now: 0)
        let source = try store.createSource(notebookId: nb.id!, type: .markdown, title: "a", uri: nil, rawPath: "/docs/a.md")
        try store.attachSource(sourceId: source.id!, folderId: folder.id, relPath: "a.md")
        _ = try store.commitForegroundRevision(sourceId: source.id!, draft: RevisionDraft(
            contentHash: "old", canonicalText: "old", textFormatVersion: 1, chunkerVersion: 2),
            chunks: ScalarChunker.chunk("old"), now: 0, leaseToken: "initial")
        let id = try store.enqueueJob(IngestJobDraft(kind: "scan", target: "folder:\(folder.id)", targetRevision: nil), now: 1)
        _ = try store.claimJob(now: 1, leaseToken: "scan", id: id)
        let ticket = try XCTUnwrap(store.beginFolderScan(folderId: folder.id, fence: JobFence(jobId: id, leaseToken: "scan"), now: 1))
        let changed = expectation(description: "one committed observation")
        changed.assertForOverFulfill = true
        let observer = NotificationCenter.default.addObserver(forName: .folderIngestionDidChange,
            object: store, queue: nil) { note in
            XCTAssertEqual(note.userInfo?["notebookId"] as? Int64, nb.id!)
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = try store.observeFolderFile(ticket: ticket, observation: FolderObservation(relPath: "a.md",
            stamp: FileStamp(identity: "f", mtimeNs: 2, sizeBytes: 3), kind: "eligible", skipReason: nil, contentHash: "new"), now: 1)
        wait(for: [changed], timeout: 1)
        let coverage = try store.coverage(notebookId: nb.id!, scope: .all)
        XCTAssertEqual(coverage.searchable, 1)
        XCTAssertEqual(coverage.refreshPending, 1)
        XCTAssertEqual(coverage.refreshError, 0)
    }

    /// Steps every scan/rules trace through the store transactions and checks
    /// the exact projection after each event; then replays each scan segment
    /// end to end through FolderScanner with a scripted filesystem.
    func testAllScanTraces() async throws {
        let rows = try cases("ingestion-scan-v1.json", ["scan", "rules"])
        var names = Set<String>()
        let tables = try UnicodeTables.bundled()
        for row in rows {
            let name = row["name"] as! String
            XCTAssertTrue(names.insert(name).inserted)
            try await stepTrace(row, tables: tables)
            if row["operation"] as? String == "scan" { try await replayTrace(row, tables: tables) }
        }
        XCTAssertEqual(names.count, 27)
    }

    private func stepTrace(_ row: [String: Any], tables: UnicodeTables) async throws {
        let name = row["name"] as! String
        let input = row["input"] as! [String: Any]
        let events = input["events"] as! [[String: Any]]
        let verifyAll = input["verifyAll"] as? Bool ?? false
        let store = try storeFor(row)
        watch(store)
        let folder = try store.folderSource(id: 1)
        let classifier = try FolderClassifier(rules: try folder.rules, caseSensitive: true, tables: tables)
        var reads = 0, lists: [String] = []
        var ticket: ScanTicket?
        var deferred: FolderObservation?
        var awaitingRead: String?
        for (index, event) in events.enumerated() {
            let operation = event["operation"] as! String, at = int64(event["at"])!
            let label = "\(name)#\(index) \(operation)"
            if operation != "read", let observation = deferred {
                _ = try store.observeFolderFile(ticket: try XCTUnwrap(ticket), observation: observation, now: at)
                deferred = nil
            }
            let before = notifications.count
            var accepted = true
            switch operation {
            case "list":
                if event["beginScan"] as? Bool == true {
                    let fence = try ensureClaimed(store, event)
                    ticket = try XCTUnwrap(store.beginFolderScan(folderId: int64(event["folderId"])!, fence: fence, now: at), label)
                    XCTAssertEqual(ticket?.generation, int64(event["generation"]), label)
                }
                lists.append(event["directory"] as! String)
            case "deny":
                if event["error"] as? String == "permissionDenied" {
                    lists.append(event["directory"] as! String)
                } else {
                    XCTAssertTrue(try store.finishFolderScan(ticket: try XCTUnwrap(ticket), completion: ScanCompletion(
                        completed: [], incomplete: [""], rootUnavailable: false, error: event["error"] as? String), now: at), label)
                }
            case "stat":
                let path = event["relPath"] as! String, observed = stamp(event["stamp"])
                let next = index + 1 < events.count ? events[index + 1] : [:]
                let nextIsRead = next["operation"] as? String == "read" && next["relPath"] as? String == path
                if let reason = classifier.skipReason(relPath: path, sizeBytes: observed.sizeBytes) {
                    XCTAssertFalse(nextIsRead, "\(label): skipped files are never read")
                    _ = try store.observeFolderFile(ticket: try XCTUnwrap(ticket), observation: FolderObservation(relPath: path,
                        stamp: observed, kind: "skipped", skipReason: reason, contentHash: nil), now: at)
                } else if FolderScanner.canSkipRead(try store.folderKnownSource(folderId: 1, relPath: path), stamp: observed, verifyAll: verifyAll) {
                    XCTAssertFalse(nextIsRead, "\(label): fast path must not read")
                    deferred = FolderObservation(relPath: path, stamp: observed, kind: "eligible", skipReason: nil, contentHash: nil)
                } else {
                    XCTAssertTrue(nextIsRead, "\(label): changed or unverified file must be read")
                    awaitingRead = path
                }
            case "read":
                let path = event["relPath"] as! String
                XCTAssertEqual(awaitingRead, path, label)
                awaitingRead = nil
                reads += 1
                _ = try store.observeFolderFile(ticket: try XCTUnwrap(ticket), observation: FolderObservation(relPath: path,
                    stamp: stamp(event["stamp"]), kind: "eligible", skipReason: nil, contentHash: event["hash"] as? String), now: at)
            case "finish":
                let current = ticket
                let fence = JobFence(jobId: int64(event["jobId"]) ?? current!.fence.jobId,
                                     leaseToken: event["leaseToken"] as? String ?? current!.fence.leaseToken)
                let finishing = ScanTicket(folderId: int64(event["folderId"])!, generation: int64(event["generation"])!, fence: fence)
                accepted = try store.finishFolderScan(ticket: finishing, completion: ScanCompletion(
                    completed: event["completed"] as! [String], incomplete: event["incomplete"] as! [String],
                    rootUnavailable: event["rootUnavailable"] as! Bool, error: nil), now: at)
                XCTAssertEqual(accepted, event["accepted"] as? Bool ?? true, label)
            case "cancel":
                XCTAssertTrue(try store.markFolderScanCancelled(ticket: try XCTUnwrap(ticket), now: at), label)
            case "rootUnavailable":
                let fence = try ensureClaimed(store, event)
                ticket = try XCTUnwrap(store.beginFolderScan(folderId: int64(event["folderId"])!, fence: fence, now: at), label)
                XCTAssertTrue(try store.finishFolderScan(ticket: ticket!, completion: ScanCompletion(
                    completed: [], incomplete: [], rootUnavailable: true, error: event["error"] as? String), now: at), label)
            case "apply-rules":
                let rules = FolderRules(includeExts: event["includeExts"] as! [String], ignoreGlobs: event["ignoreGlobs"] as! [String],
                                        limits: .defaults, encodingFallback: "cp1250")
                let fs = ScriptedScanFS(calls: ScanCalls())
                try await FolderScanner(store: store, fileSystem: fs, tables: tables, clock: FixedClock(at))
                    .applyRules(folderId: int64(event["folderId"])!, rules: rules, now: at)
                let ids = try retrievalIds(store)
                XCTAssertEqual(ids.eligible, (event["eligibleSourceIds"] as! [NSNumber]).map(\.int64Value), label)
                XCTAssertEqual(ids.retrieval, (event["retrievalSourceIds"] as! [NSNumber]).map(\.int64Value), label)
            default:
                XCTFail("unknown trace operation \(operation)")
            }
            if !accepted { XCTAssertEqual(notifications.count, before, "\(label): rejected fence notified") }
            XCTAssertEqual(json(try projection(store, reads: reads, lists: lists)), json(event["expected"]!), label)
        }
        XCTAssertNil(deferred, name)
        XCTAssertEqual(json(try projection(store, reads: reads, lists: lists)), json(row["expected"]!), name)
    }

    /// Runs FolderScanner over each begin-delimited segment of a scan trace.
    private func replayTrace(_ row: [String: Any], tables: UnicodeTables) async throws {
        let name = row["name"] as! String
        let input = row["input"] as! [String: Any]
        let events = input["events"] as! [[String: Any]]
        var segments: [[[String: Any]]] = []
        for event in events {
            if event["beginScan"] as? Bool == true { segments.append([event]) }
            else if !segments.isEmpty { segments[segments.count - 1].append(event) }
        }
        guard !segments.isEmpty else { return } // late-old-generation has no scan of its own
        let store = try storeFor(row)
        let calls = ScanCalls()
        for segment in segments {
            var fs = ScriptedScanFS(calls: calls)
            for event in segment {
                switch event["operation"] as! String {
                case "list":
                    fs.directories[event["directory"] as! String] = (event["entries"] as! [[String: Any]]).map { entry in
                        let path = entry["relPath"] as! String, directory = entry["isDirectory"] as! Bool
                        let entryStamp = directory ? ScriptedScanFS.directoryStamp(path)
                            : segment.first { $0["operation"] as? String == "stat" && $0["relPath"] as? String == path }.map { stamp($0["stamp"]) }!
                        return FolderEntry(relPath: path, isDirectory: directory, isLink: entry["isLink"] as! Bool, stamp: entryStamp)
                    }
                case "stat": fs.files[event["relPath"] as! String] = stamp(event["stamp"])
                case "read": fs.hashes[event["relPath"] as! String] = (stamp(event["stamp"]), event["hash"] as! String)
                case "deny":
                    if event["error"] as? String == "permissionDenied" { fs.denied.insert(event["directory"] as! String) }
                    else { fs.broken.insert(event["directory"] as! String) }
                case "cancel": fs.cancelAfterRootList = true
                case "rootUnavailable": fs.rootOffline = true
                case "finish": break
                case let other: XCTFail("\(name): unexpected replay operation \(other)")
                }
            }
            let begin = segment[0], last = segment[segment.count - 1]
            let fence = try ensureClaimed(store, begin)
            let scripted = fs
            try await FolderScanner(store: store, fileSystem: scripted, tables: tables, clock: FixedClock(int64(last["at"])!))
                .scan(folderId: int64(begin["folderId"])!, verifyAll: input["verifyAll"] as? Bool ?? false, fence: fence,
                      now: int64(begin["at"])!, cancelled: { scripted.calls.cancelled })
            XCTAssertEqual(json(try projection(store, reads: calls.reads.count, lists: calls.lists)),
                           json(last["expected"]!), "\(name) replay")
        }
    }

    func testAllCoverageRows() throws {
        let rows = try cases("ingestion-coverage-v1.json", ["coverage"])
        var names = Set<String>()
        for row in rows {
            let name = row["name"] as! String, i = row["input"] as! [String: Any], e = row["expected"] as! [String: Any]
            XCTAssertTrue(names.insert(name).inserted)
            let store = try makeStore(notebooks: 2, folderNotebook: int64(i["notebookId"])!)
            try store.runOnDatabase { db in
                try db.execute(sql: "UPDATE folder_sources SET scan_state=? WHERE id=1", arguments: [i["scanState"] as! String])
                let relPath = i["relPath"] as! String
                if let sourceId = int64(i["sourceId"]) {
                    try db.execute(sql: """
                        INSERT INTO sources(id,notebook_id,type,title,status,ingested_at,folder_id,rel_path,mtime,size_bytes,availability,eligible)
                        VALUES(?,?,'markdown','a',?,?,1,?,10,5,?,?)
                        """, arguments: [sourceId, int64(i["notebookId"]), i["status"] as! String, Date(timeIntervalSince1970: 0),
                                          relPath, i["availability"] as! String, i["eligible"] as! Bool])
                    let current = int64(i["currentRevision"]), published = int64(i["publishedRevisionId"])
                    let vector = int64(i["activeVectorRevision"])
                    let count = [current, published, vector].compactMap { $0 }.max() ?? 0
                    if count > 0 {
                        for revision in 1...count {
                            try db.execute(sql: """
                                INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                                VALUES(?,?,?,'h','old',1,2,?)
                                """, arguments: [revision, sourceId, revision, Date(timeIntervalSince1970: 0)])
                            try db.execute(sql: """
                                INSERT INTO source_chunks(source_id,revision_id,ord,text,token_count,char_start,char_end) VALUES(?,?,0,'old',1,0,3)
                                """, arguments: [sourceId, revision])
                        }
                    }
                    try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?",
                                   arguments: [current, published, sourceId])
                    if let vector {
                        try db.execute(sql: """
                            INSERT INTO index_generations(id,notebook_id,provider_id,endpoint_revision,model,dims,normalization,
                                query_format_version,doc_format_version,chunker_version,state,created_at,activated_at)
                            VALUES(1,?,'p','e','m',1,'l2','q','d','2','active',?,?)
                            """, arguments: [int64(i["notebookId"]), Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 0)])
                        try db.execute(sql: "INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state) VALUES(1,?,?,'done')",
                                       arguments: [sourceId, vector])
                        try db.execute(sql: """
                            INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding)
                            SELECT id,1,? FROM source_chunks WHERE revision_id=?
                            """, arguments: [Data(repeating: 0, count: 4), vector])
                    }
                }
                if i["hasScanItem"] as? Bool == true {
                    let kind = i["scanKind"] as! String
                    try db.execute(sql: """
                        INSERT INTO scan_items(folder_id,rel_path,kind,skip_reason,mtime,size_bytes,seen_generation) VALUES(1,?,?,?,10,5,0)
                        """, arguments: [relPath, kind, kind == "skipped" ? "ignored" : nil])
                }
            }
            let scope: RetrievalScope
            if let value = i["scope"] {
                scope = try JSONDecoder().decode(RetrievalScope.self, from: JSONSerialization.data(withJSONObject: value))
            } else { scope = .all }
            let c = try store.coverage(notebookId: int64(i["queryNotebookId"]) ?? int64(i["notebookId"])!, scope: scope)
            let actual: [String: Any] = ["searchable": c.searchable, "notSearchable": c.notSearchable, "current": c.current,
                "refreshPending": c.refreshPending, "refreshError": c.refreshError, "skipped": c.skipped,
                "missing": c.missing, "unavailable": c.unavailable, "isLowerBound": c.isLowerBound]
            XCTAssertEqual(json(actual), json(e), name)
            // The retained raw DTO partitions notSearchable; freshness partitions eligible present files.
            XCTAssertEqual(c.pending + c.error, c.notSearchable, name)
            XCTAssertEqual(c.current + c.refreshPending + c.refreshError, c.searchable + c.notSearchable, name)
        }
        XCTAssertEqual(names.count, 19)
    }

    func testRuleChangeRevokesImmediately() async throws {
        let row = try XCTUnwrap(cases("ingestion-scan-v1.json", ["rules"]).first { $0["name"] as? String == "rule-reenable-current" })
        let store = try storeFor(row)
        watch(store)
        let tables = try UnicodeTables.bundled()
        let scanner = FolderScanner(store: store, fileSystem: ScriptedScanFS(calls: ScanCalls()), tables: tables, clock: FixedClock(5))
        XCTAssertEqual(try store.coverage(notebookId: 1, scope: .all).searchable, 1)
        do {
            try await scanner.applyRules(folderId: 1, rules: FolderRules(includeExts: ["md"], ignoreGlobs: ["["],
                limits: .defaults, encodingFallback: "cp1250"), now: 5)
            XCTFail("invalid glob must be rejected before any write")
        } catch { XCTAssertEqual((error as? IngestionError)?.code, "unsupportedSyntax") }
        XCTAssertEqual(notifications, [], "a rejected rule set posts nothing")
        XCTAssertEqual(try store.folderSource(id: 1).draft.ignoreGlobs, FolderRules.defaults.ignoreGlobs)
        try await scanner.applyRules(folderId: 1, rules: FolderRules(includeExts: ["md"], ignoreGlobs: ["*.md"],
            limits: .defaults, encodingFallback: "cp1250"), now: 5)
        XCTAssertEqual(notifications, [1])
        let revoked = try store.coverage(notebookId: 1, scope: .all)
        XCTAssertEqual(revoked.searchable, 0)
        XCTAssertEqual(revoked.skipped, 1)
        XCTAssertEqual(revoked.missing, 0)
        XCTAssertEqual(try retrievalIds(store).retrieval, [])
        XCTAssertEqual(try store.source(id: 101)?.status, .ready)
        let source = try store.runOnDatabase { try Row.fetchOne($0, sql: "SELECT availability,eligible FROM sources WHERE id=101")! }
        XCTAssertEqual(source["availability"] as String, "present", "rules never change availability")
        XCTAssertEqual(try store.folderSource(id: 1).draft.ignoreGlobs, ["*.md"])

        // A file observed after classification rejects the stale dictionary.
        do {
            try store.applyFolderRules(folderId: 1, rules: .defaults, eligibility: [:], now: 6)
            XCTFail("stale eligibility must be rejected")
        } catch { XCTAssertEqual(error as? StorageV19Error, .staleRevision) }

        // Changed limits force re-extraction of eligible current sources.
        try await scanner.applyRules(folderId: 1, rules: FolderRules(includeExts: ["md"], ignoreGlobs: [],
            limits: IngestionLimits(fileBytes: 1000, officeBytes: 1000, textScalars: 1000, pdfPages: 1, chunks: 1, cells: 1),
            encodingFallback: "cp1250"), now: 7)
        let jobs = try store.runOnDatabase { try Row.fetchAll($0, sql: "SELECT kind,state,target FROM ingest_jobs ORDER BY id") }
        XCTAssertEqual(jobs.map { "\($0["kind"] as String):\($0["state"] as String):\($0["target"] as String)" },
                       ["scan:queued:folder:1", "extract:queued:source:101"])
        XCTAssertEqual(try store.coverage(notebookId: 1, scope: .all).refreshPending, 1)
    }

    func testStaleScanCannotFinish() throws {
        let row = try XCTUnwrap(cases("ingestion-scan-v1.json", ["scan"]).first { $0["name"] as? String == "fast-path" })
        let store = try storeFor(row)
        watch(store)
        let fence = JobFence(jobId: 201, leaseToken: "scan-1")
        let ticket = try XCTUnwrap(store.beginFolderScan(folderId: 1, fence: fence, now: 0))
        XCTAssertEqual(notifications, [1])
        let snapshot = json(try projection(store, reads: 0, lists: []))
        notifications = []
        // Expired lease: neither observation nor finish is accepted.
        XCTAssertThrowsError(try store.observeFolderFile(ticket: ticket, observation: FolderObservation(relPath: "a.md",
            stamp: FileStamp(identity: "f", mtimeNs: 99, sizeBytes: 5), kind: "eligible", skipReason: nil, contentHash: "x"), now: 300)) {
            XCTAssertEqual($0 as? StorageV19Error, .staleLease)
        }
        XCTAssertFalse(try store.finishFolderScan(ticket: ticket, completion: ScanCompletion(completed: [""], incomplete: [],
            rootUnavailable: false, error: nil), now: 300))
        XCTAssertNil(try store.beginFolderScan(folderId: 1, fence: JobFence(jobId: 201, leaseToken: "wrong"), now: 1))
        XCTAssertEqual(json(try projection(store, reads: 0, lists: [])), snapshot)
        XCTAssertEqual(notifications, [])

        // After the old lease is reclaimed a new owner advances the generation; the old ticket is dead.
        _ = try store.recoverExpiredJobs(now: 300)
        let next = try store.enqueueJob(IngestJobDraft(kind: "scan", target: "folder:1", targetRevision: nil), now: 300)
        XCTAssertNotNil(try store.claimJob(now: 300, leaseToken: "scan-2", id: next))
        let fresh = try XCTUnwrap(store.beginFolderScan(folderId: 1, fence: JobFence(jobId: next, leaseToken: "scan-2"), now: 300))
        XCTAssertEqual(fresh.generation, 2)
        notifications = []
        XCTAssertFalse(try store.finishFolderScan(ticket: ticket, completion: ScanCompletion(completed: [""], incomplete: [],
            rootUnavailable: false, error: nil), now: 301))
        XCTAssertFalse(try store.markFolderScanCancelled(ticket: ticket, now: 301))
        XCTAssertEqual(notifications, [])
        XCTAssertEqual(try store.folderSource(id: 1).scanState, "scanning")
        XCTAssertTrue(try store.finishFolderScan(ticket: fresh, completion: ScanCompletion(completed: [""], incomplete: [],
            rootUnavailable: false, error: nil), now: 301))
        XCTAssertEqual(try store.source(id: 101).map { _ in true }, true)
    }

    func testPartialAndUnavailable() async throws {
        let walk = try XCTUnwrap(cases("ingestion-scan-v1.json", ["walk"]).first { $0["name"] as? String == "partial-sibling" })
        let input = walk["input"] as! [String: Any]
        let store = try makeStore()
        try store.runOnDatabase { db in
            for (index, seed) in (input["seedSources"] as! [[String: Any]]).enumerated() {
                let id = int64(seed["id"])!
                try db.execute(sql: """
                    INSERT INTO sources(id,notebook_id,type,title,status,ingested_at,folder_id,rel_path,mtime,size_bytes,content_hash)
                    VALUES(?,1,'markdown','x','ready',?,1,?,10,5,'h')
                    """, arguments: [id, Date(timeIntervalSince1970: 0), seed["relPath"] as! String])
                try db.execute(sql: """
                    INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES(?,?,1,'h',?,1,2,?)
                    """, arguments: [index + 1, id, seed["canonicalText"] as! String, Date(timeIntervalSince1970: 0)])
                try db.execute(sql: "INSERT INTO source_chunks(source_id,revision_id,ord,text,token_count,char_start,char_end) VALUES(?,?,0,'old',1,0,3)",
                               arguments: [id, index + 1])
                try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?", arguments: [index + 1, index + 1, id])
            }
        }
        let calls = ScanCalls()
        var fs = ScriptedScanFS(calls: calls)
        let stats = (input["stats"] as! [String: Any]).mapValues { stamp($0) }
        for (directory, entries) in input["directories"] as! [String: [[String: Any]]] {
            fs.directories[directory] = entries.map {
                FolderEntry(relPath: $0["relPath"] as! String, isDirectory: $0["isDirectory"] as! Bool,
                            isLink: $0["isLink"] as! Bool, stamp: ScriptedScanFS.directoryStamp($0["relPath"] as! String))
            }
        }
        XCTAssertEqual(stats.count, 3)
        fs.denied = Set((input["listErrors"] as! [String: String]).keys)
        let tables = try UnicodeTables.bundled()
        let id = try store.enqueueJob(IngestJobDraft(kind: "scan", target: "folder:1", targetRevision: nil), now: 0)
        _ = try store.claimJob(now: 0, leaseToken: "partial", id: id)
        let scripted = fs
        try await FolderScanner(store: store, fileSystem: scripted, tables: tables, clock: FixedClock(3))
            .scan(folderId: 1, verifyAll: false, fence: JobFence(jobId: id, leaseToken: "partial"), now: 0, cancelled: { false })
        let expected = walk["expected"] as! [String: Any]
        XCTAssertEqual(calls.lists, expected["listCalls"] as? [String])
        let missing = try store.runOnDatabase { try Int64.fetchAll($0, sql: "SELECT id FROM sources WHERE availability='missing' ORDER BY id") }
        XCTAssertEqual(missing, (expected["missingSourceIds"] as! [NSNumber]).map(\.int64Value))
        let folder = try store.folderSource(id: 1)
        XCTAssertEqual(folder.scanState, "partial")
        XCTAssertNil(folder.lastFullScanAt)
        XCTAssertTrue(try store.coverage(notebookId: 1, scope: .all).isLowerBound)

        // Root offline: present sources become unavailable; missing ones stay missing.
        var offline = ScriptedScanFS(calls: calls)
        offline.rootOffline = true
        let second = try store.enqueueJob(IngestJobDraft(kind: "scan", target: "folder:1", targetRevision: nil), now: 10)
        _ = try store.claimJob(now: 10, leaseToken: "offline", id: second)
        let off = offline
        try await FolderScanner(store: store, fileSystem: off, tables: tables, clock: FixedClock(11))
            .scan(folderId: 1, verifyAll: false, fence: JobFence(jobId: second, leaseToken: "offline"), now: 10, cancelled: { false })
        let availability = try store.runOnDatabase { try String.fetchAll($0, sql: "SELECT availability FROM sources ORDER BY id") }
        XCTAssertEqual(availability, ["missing", "unavailable", "unavailable"])
        XCTAssertEqual(try store.folderSource(id: 1).scanState, "unavailable")
        XCTAssertEqual(try store.folderSource(id: 1).lastScanError, "rootUnavailable")
        let coverage = try store.coverage(notebookId: 1, scope: .all)
        XCTAssertEqual(coverage.unavailable, 2)
        XCTAssertEqual(coverage.missing, 1)

        // Task cancellation of a running scan marks partial and cancels the job without missing-marking.
        let third = try store.enqueueJob(IngestJobDraft(kind: "scan", target: "folder:1", targetRevision: nil), now: 20)
        _ = try store.claimJob(now: 20, leaseToken: "cancelled", id: third)
        var cancelling = ScriptedScanFS(calls: ScanCalls())
        cancelling.directories = ["": []]
        cancelling.cancelAfterRootList = true
        let cancelFS = cancelling
        try await FolderScanner(store: store, fileSystem: cancelFS, tables: tables, clock: FixedClock(21))
            .scan(folderId: 1, verifyAll: false, fence: JobFence(jobId: third, leaseToken: "cancelled"), now: 20,
                  cancelled: { cancelFS.calls.cancelled })
        XCTAssertEqual(try store.job(id: third)?.state, "cancelled")
        XCTAssertEqual(try store.folderSource(id: 1).scanState, "partial")
        XCTAssertEqual(try store.runOnDatabase { try String.fetchAll($0, sql: "SELECT availability FROM sources ORDER BY id") },
                       ["missing", "unavailable", "unavailable"])
    }

    func testFingerprintFastPath() async throws {
        let row = try XCTUnwrap(cases("ingestion-scan-v1.json", ["scan"]).first { $0["name"] as? String == "fast-path" })
        let tables = try UnicodeTables.bundled()
        for verifyAll in [false, true] {
            let store = try storeFor(row)
            let calls = ScanCalls()
            var fs = ScriptedScanFS(calls: calls)
            let same = FileStamp(identity: "file1", mtimeNs: 10, sizeBytes: 5)
            fs.directories = ["": [FolderEntry(relPath: "a.md", isDirectory: false, isLink: false, stamp: same)]]
            // Same size and mtime, different bytes: only Verify all can discover this replacement.
            fs.hashes = ["a.md": (same, "replaced")]
            let scripted = fs
            try await FolderScanner(store: store, fileSystem: scripted, tables: tables, clock: FixedClock(3))
                .scan(folderId: 1, verifyAll: verifyAll, fence: JobFence(jobId: 201, leaseToken: "scan-1"), now: 0, cancelled: { false })
            XCTAssertEqual(calls.reads, verifyAll ? ["a.md"] : [])
            XCTAssertEqual(try store.source(id: 101)?.status, verifyAll ? .pending : .ready)
            let extracts = try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM ingest_jobs WHERE kind='extract'")! }
            XCTAssertEqual(extracts, verifyAll ? 1 : 0)
        }
    }

    func testRestartPendingWork() async throws {
        let row = try XCTUnwrap(cases("ingestion-scan-v1.json", ["scan"]).first { $0["name"] as? String == "fast-path" })
        let store = try storeFor(row)
        let tables = try UnicodeTables.bundled()
        // A pending source with an orphaned (cancelled) extraction and unchanged metadata.
        try store.runOnDatabase { db in
            try db.execute(sql: "UPDATE sources SET status='pending' WHERE id=101")
            try db.execute(sql: "INSERT INTO ingest_jobs(id,kind,target,target_revision,state) VALUES(150,'extract','source:101',11,'cancelled')")
        }
        let calls = ScanCalls()
        var fs = ScriptedScanFS(calls: calls)
        let same = FileStamp(identity: "file1", mtimeNs: 10, sizeBytes: 5)
        let fresh = FileStamp(identity: "file2", mtimeNs: 20, sizeBytes: 7)
        fs.directories = ["": [FolderEntry(relPath: "a.md", isDirectory: false, isLink: false, stamp: same),
                               FolderEntry(relPath: "new.md", isDirectory: false, isLink: false, stamp: fresh)]]
        fs.hashes = ["a.md": (same, "changed"), "new.md": (fresh, "n1")]
        let scripted = fs
        try await FolderScanner(store: store, fileSystem: scripted, tables: tables, clock: FixedClock(3))
            .scan(folderId: 1, verifyAll: false, fence: JobFence(jobId: 201, leaseToken: "scan-1"), now: 0, cancelled: { false })
        // Metadata equality never suppresses pending work: the file is read and requeued.
        XCTAssertEqual(calls.reads, ["a.md", "new.md"])
        let jobs = try store.runOnDatabase { try Row.fetchAll($0, sql: "SELECT target,target_revision,state FROM ingest_jobs WHERE kind='extract' ORDER BY id") }
        XCTAssertEqual(jobs.map { "\($0["target"] as String):\(($0["target_revision"] as Int64?).map(String.init) ?? "nil"):\($0["state"] as String)" },
                       ["source:101:11:cancelled", "source:101:11:queued", "source:102:nil:queued"])
        // Restarted jobs derive their hash from committed bytes; a new source has none yet.
        XCTAssertEqual(try store.extractionRequest(sourceId: 101)?.hash, "h")
        XCTAssertEqual(try store.extractionRequest(sourceId: 102)?.hash, "")
        XCTAssertEqual(try store.extractionRequest(sourceId: 102)?.relPath, "new.md")
        XCTAssertEqual(try store.extractionRequest(sourceId: 102)?.stamp.sizeBytes, 7)
        XCTAssertNil(try store.source(id: 102).flatMap { _ in try store.runOnDatabase { try String.fetchOne($0, sql: "SELECT content_hash FROM sources WHERE id=102") } })

        // A live observation carries the just-computed hash in memory.
        let next = try store.enqueueJob(IngestJobDraft(kind: "scan", target: "folder:1", targetRevision: nil), now: 3)
        _ = try store.claimJob(now: 3, leaseToken: "scan-x", id: next)
        let ticket = try XCTUnwrap(store.beginFolderScan(folderId: 1, fence: JobFence(jobId: next, leaseToken: "scan-x"), now: 3))
        let request = try store.observeFolderFile(ticket: ticket, observation: FolderObservation(relPath: "third.md",
            stamp: FileStamp(identity: "f3", mtimeNs: 1, sizeBytes: 1), kind: "eligible", skipReason: nil, contentHash: "t3"), now: 3)
        XCTAssertEqual(request?.hash, "t3")
        XCTAssertEqual(request?.rules.includeExts, FolderRules.defaults.includeExts)
        // Reverting to the committed bytes supersedes the pending refresh.
        XCTAssertNil(try store.observeFolderFile(ticket: ticket, observation: FolderObservation(relPath: "a.md",
            stamp: same, kind: "eligible", skipReason: nil, contentHash: "h"), now: 3))
        XCTAssertEqual(try store.source(id: 101)?.status, .ready)
        XCTAssertEqual(try store.runOnDatabase { try Int.fetchOne($0, sql: """
            SELECT count(*) FROM ingest_jobs WHERE target='source:101' AND state='queued'
            """)! }, 0)
    }
}

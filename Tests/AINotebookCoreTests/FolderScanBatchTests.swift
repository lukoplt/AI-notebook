import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

/// Flat in-memory folder; hashes derive from path and mtime.
private struct FlatFS: FolderFileSystem {
    var files: [String: FileStamp]
    var links: Set<String> = []

    static func hash(_ path: String, _ stamp: FileStamp) -> String { "h:\(path):\(stamp.mtimeNs)" }

    func resolve(rootPath: String) throws -> FolderIdentity {
        FolderIdentity(volumeId: "batch", components: ["batch"], rootFileId: "root")
    }
    func caseSensitive(root: FolderSource) throws -> Bool { true }
    func list(root: FolderSource, directory: String) throws -> [FolderEntry] {
        guard directory.isEmpty else { return [] }
        return files.keys.sorted().map { FolderEntry(relPath: $0, isDirectory: false, isLink: links.contains($0), stamp: files[$0]!) }
    }
    func stat(root: FolderSource, relativePath: String) throws -> FileStamp {
        if relativePath.isEmpty { return FileStamp(identity: "root", mtimeNs: 0, sizeBytes: 0) }
        guard let stamp = files[relativePath] else { throw CocoaError(.fileNoSuchFile) }
        return stamp
    }
    func hash(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderRead {
        guard let stamp = files[relativePath] else { throw CocoaError(.fileNoSuchFile) }
        return FolderRead(bytes: Data(), stamp: stamp, sha256: Self.hash(relativePath, stamp))
    }
    func snapshot(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderFileSnapshot {
        throw CocoaError(.featureUnsupported)
    }
}

private struct BatchClock: IngestLeaseClock {
    func now() -> Int64 { 10 }
    func wait(until: Int64) async throws { throw CancellationError() }
}

private final class Tally: @unchecked Sendable {
    private let gate = NSLock()
    private var values: [String: Int] = [:]
    func add(_ key: String) { gate.lock(); values[key, default: 0] += 1; gate.unlock() }
    func reset() { gate.lock(); values = [:]; gate.unlock() }
    subscript(_ key: String) -> Int { gate.lock(); defer { gate.unlock() }; return values[key] ?? 0 }
}

/// Batched scan observations (contract `ingestion-scan-perf-v1` §1–2).
@MainActor
final class FolderScanBatchTests: XCTestCase {
    private var tokens: [NSObjectProtocol] = []

    override func tearDown() async throws {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }

    private func makeStore() throws -> NotebookStore {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        _ = try store.createNotebook(name: "nb")
        _ = try store.createFolder(notebookId: 1, draft: FolderDraft(rootPath: "/batch", displayName: "Batch",
            includeExts: ["md", "txt"], ignoreGlobs: [], limitsJSON: "{}", encodingFallback: "cp1250", watchEnabled: true),
            identity: FlatFS(files: [:]), now: 0)
        return store
    }

    private func files(_ count: Int, mtime: Int64 = 1) -> [String: FileStamp] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { index in
            let path = String(format: "f%04d.%@", index, index % 10 == 9 ? "png" : "md")
            return (path, FileStamp(identity: "id\(index)", mtimeNs: mtime, sizeBytes: Int64(10 + index)))
        })
    }

    private func scan(_ store: NotebookStore, _ fs: FlatFS, token: String, verifyAll: Bool = false) async throws {
        let job = try store.requestFolderScan(folderId: 1, verifyAll: verifyAll, now: 10)
        XCTAssertNotNil(try store.claimJob(now: 10, leaseToken: token, id: job))
        try await FolderScanner(store: store, fileSystem: fs, tables: try UnicodeTables.bundled(), clock: BatchClock())
            .scan(folderId: 1, verifyAll: verifyAll, fence: JobFence(jobId: job, leaseToken: token), now: 10, cancelled: { false })
    }

    /// Marks every folder source ready with a published revision whose hash matches the file.
    private func publishAll(_ store: NotebookStore, _ fs: FlatFS) throws {
        try store.runOnDatabase { db in
            for row in try Row.fetchAll(db, sql: "SELECT id,rel_path FROM sources WHERE folder_id=1") {
                let id: Int64 = row["id"], path: String = row["rel_path"]
                let hash = FlatFS.hash(path, fs.files[path]!)
                try db.execute(sql: """
                    INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES (?,1,?,'',1,2,'2026-10-10 00:00:00.000')
                    """, arguments: [id, hash])
                let revision = db.lastInsertedRowID
                try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=?,status='ready',content_hash=? WHERE id=?",
                               arguments: [revision, revision, hash, id])
            }
            try db.execute(sql: "UPDATE ingest_jobs SET state='done',lease_token=NULL,lease_until=NULL WHERE kind='extract'")
        }
    }

    private func observe(_ store: NotebookStore) -> Tally {
        let tally = Tally()
        for name in [Notification.Name.folderIngestionDidChange, .indexingStatusDidChange] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: store, queue: nil) { note in
                tally.add(note.name.rawValue)
            })
        }
        return tally
    }

    /// Write transactions (BEGIN IMMEDIATE) and statements that modify sources/scan_items rows.
    private func traceWrites(_ store: NotebookStore) throws -> Tally {
        let tally = Tally()
        try store.runOnDatabase { db in
            db.trace { event in
                let sql = event.expandedDescription
                if sql.hasPrefix("BEGIN IMMEDIATE") { tally.add("write") }
                if sql.hasPrefix("UPDATE sources") || sql.hasPrefix("INSERT INTO scan_items") { tally.add("rowWrite") }
            }
        }
        return tally
    }

    func testNoChangeRescanBatchesAndSkipsUnchangedRows() async throws {
        let store = try makeStore()
        let fs = FlatFS(files: files(600))
        try await scan(store, fs, token: "seed")
        try publishAll(store, fs)
        let notes = observe(store)
        let writes = try traceWrites(store)
        try await scan(store, fs, token: "again")

        // request + claim + begin + ceil(600 / 256) batches + finish, never one transaction per file.
        let batches = (600 + FolderScanner.observeBatchSize - 1) / FolderScanner.observeBatchSize
        XCTAssertLessThanOrEqual(writes["write"], 3 + batches + 1)
        XCTAssertEqual(writes["rowWrite"], 0, "unchanged files only bump seen_generation in bulk")
        // Catalog signals only for request, begin and finish; unchanged batches post throttled status signals.
        XCTAssertEqual(notes[Notification.Name.folderIngestionDidChange.rawValue], 3)
        // Every catalog signal carries a status signal; at least one more reports files seen.
        XCTAssertGreaterThanOrEqual(notes[Notification.Name.indexingStatusDidChange.rawValue], 3 + 1)
        let generation = try store.folderSource(id: 1).scanGeneration
        let seen = try store.runOnDatabase {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM scan_items WHERE folder_id=1 AND seen_generation=?", arguments: [generation])!
        }
        XCTAssertEqual(seen, 600)
        XCTAssertEqual(try store.folderSource(id: 1).scanState, "idle")
        XCTAssertEqual(try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM ingest_jobs WHERE state='queued'")! }, 0)
    }

    func testChangedFilesInBatchPostOneCatalogSignalPerBatch() async throws {
        let store = try makeStore()
        var fs = FlatFS(files: files(300))
        try await scan(store, fs, token: "seed")
        try publishAll(store, fs)
        fs.files["f0000.md"] = FileStamp(identity: "id0", mtimeNs: 2, sizeBytes: 10)
        fs.files["f0001.md"] = FileStamp(identity: "id1", mtimeNs: 2, sizeBytes: 11)
        let notes = observe(store)
        try await scan(store, fs, token: "again")
        let queued = try store.runOnDatabase { try String.fetchAll($0, sql: "SELECT target FROM ingest_jobs WHERE kind='extract' AND state='queued'") }
        XCTAssertEqual(queued.count, 2)
        // request + begin + the first batch (contains both changes) + finish.
        XCTAssertEqual(notes[Notification.Name.folderIngestionDidChange.rawValue], 4)
    }

    /// One batch commits exactly what the same observations commit one by one.
    func testBatchMatchesPerFileObservations() async throws {
        func prepared() async throws -> (NotebookStore, ScanTicket) {
            let store = try makeStore()
            let fs = FlatFS(files: files(20))
            try await scan(store, fs, token: "seed")
            try publishAll(store, fs)
            try store.runOnDatabase { db in
                // A pending source: metadata equality must not suppress its work.
                try db.execute(sql: "UPDATE sources SET status='pending' WHERE rel_path='f0003.md'")
            }
            let job = try store.requestFolderScan(folderId: 1, verifyAll: false, now: 10)
            _ = try store.claimJob(now: 10, leaseToken: "t", id: job)
            let ticket = try XCTUnwrap(store.beginFolderScan(folderId: 1, fence: JobFence(jobId: job, leaseToken: "t"), now: 10))
            return (store, ticket)
        }
        let same = FileStamp(identity: "id0", mtimeNs: 1, sizeBytes: 10)
        let observations: [FolderScanObservation] = [
            .file(FolderObservation(relPath: "f0000.md", stamp: same, kind: "eligible", skipReason: nil, contentHash: nil)),
            .file(FolderObservation(relPath: "f0001.md", stamp: FileStamp(identity: "id1", mtimeNs: 5, sizeBytes: 11),
                                    kind: "eligible", skipReason: nil, contentHash: "changed")),
            .file(FolderObservation(relPath: "f0002.md", stamp: FileStamp(identity: "id2", mtimeNs: 1, sizeBytes: 12),
                                    kind: "eligible", skipReason: nil, contentHash: FlatFS.hash("f0002.md", FileStamp(identity: "id2", mtimeNs: 1, sizeBytes: 12)))),
            .file(FolderObservation(relPath: "f0003.md", stamp: FileStamp(identity: "id3", mtimeNs: 1, sizeBytes: 13),
                                    kind: "eligible", skipReason: nil, contentHash: nil)),
            .file(FolderObservation(relPath: "f0004.md", stamp: FileStamp(identity: "id4", mtimeNs: 1, sizeBytes: 14),
                                    kind: "skipped", skipReason: "over_limit", contentHash: nil)),
            .file(FolderObservation(relPath: "f0009.png", stamp: FileStamp(identity: "id9", mtimeNs: 1, sizeBytes: 19),
                                    kind: "skipped", skipReason: "unsupported_ext", contentHash: nil)),
            .file(FolderObservation(relPath: "f0019.png", stamp: FileStamp(identity: "id19", mtimeNs: 3, sizeBytes: 29),
                                    kind: "skipped", skipReason: "unsupported_ext", contentHash: nil)),
            .file(FolderObservation(relPath: "new.md", stamp: FileStamp(identity: "n", mtimeNs: 1, sizeBytes: 1),
                                    kind: "eligible", skipReason: nil, contentHash: "n1")),
            .interiorLink(relPath: "f0005.md", stamp: FileStamp(identity: "l5", mtimeNs: 1, sizeBytes: 0)),
            .interiorLink(relPath: "unknown-link.md", stamp: FileStamp(identity: "l", mtimeNs: 1, sizeBytes: 0)),
        ]
        let (batched, batchTicket) = try await prepared()
        let notes = observe(batched)
        let result = try batched.observeFolderFiles(ticket: batchTicket, observations: observations, now: 11)
        XCTAssertEqual(result, FolderObserveBatchResult(changed: 6, unchanged: 3))
        XCTAssertEqual(notes[Notification.Name.folderIngestionDidChange.rawValue], 1)

        let (single, singleTicket) = try await prepared()
        for item in observations {
            if item.knownOnly {
                try single.observeInteriorLink(ticket: singleTicket, relPath: item.observation.relPath, stamp: item.observation.stamp, now: 11)
            } else {
                _ = try single.observeFolderFile(ticket: singleTicket, observation: item.observation, now: 11)
            }
        }
        XCTAssertEqual(try projection(batched), try projection(single))
    }

    func testStaleBatchCommitsNothingAndPostsNothing() async throws {
        let store = try makeStore()
        let job = try store.requestFolderScan(folderId: 1, verifyAll: false, now: 10)
        _ = try store.claimJob(now: 10, leaseToken: "t", id: job)
        let ticket = try XCTUnwrap(store.beginFolderScan(folderId: 1, fence: JobFence(jobId: job, leaseToken: "t"), now: 10))
        let notes = observe(store)
        let stale = ScanTicket(folderId: 1, generation: ticket.generation, fence: JobFence(jobId: job, leaseToken: "other"))
        XCTAssertThrowsError(try store.observeFolderFiles(ticket: stale, observations: [
            .file(FolderObservation(relPath: "a.md", stamp: FileStamp(identity: "a", mtimeNs: 1, sizeBytes: 1),
                                    kind: "eligible", skipReason: nil, contentHash: "a")),
        ], now: 11)) { XCTAssertEqual($0 as? StorageV19Error, .staleLease) }
        // An invalid observation rejects the whole batch before any write.
        XCTAssertThrowsError(try store.observeFolderFiles(ticket: ticket, observations: [
            .file(FolderObservation(relPath: "ok.md", stamp: FileStamp(identity: "a", mtimeNs: 1, sizeBytes: 1),
                                    kind: "eligible", skipReason: nil, contentHash: "a")),
            .file(FolderObservation(relPath: "../bad.md", stamp: FileStamp(identity: "b", mtimeNs: 1, sizeBytes: 1),
                                    kind: "eligible", skipReason: nil, contentHash: "b")),
        ], now: 11))
        XCTAssertEqual(try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM scan_items")! }, 0)
        XCTAssertEqual(notes[Notification.Name.folderIngestionDidChange.rawValue], 0)
        XCTAssertEqual(notes[Notification.Name.indexingStatusDidChange.rawValue], 0)
        XCTAssertEqual(try store.observeFolderFiles(ticket: ticket, observations: [], now: 11),
                       FolderObserveBatchResult(changed: 0, unchanged: 0))
        XCTAssertEqual(notes[Notification.Name.indexingStatusDidChange.rawValue], 0, "an empty batch posts nothing")
    }

    private func projection(_ store: NotebookStore) throws -> String {
        try store.runOnDatabase { db in
            let sources = try Row.fetchAll(db, sql: """
                SELECT id,rel_path,status,error,availability,eligible,mtime,size_bytes,content_hash,current_revision,published_revision_id
                FROM sources ORDER BY id
                """).map { $0.description }
            let items = try Row.fetchAll(db, sql: "SELECT * FROM scan_items ORDER BY rel_path").map { $0.description }
            let jobs = try Row.fetchAll(db, sql: "SELECT id,kind,target,target_revision,state,next_retry_at FROM ingest_jobs ORDER BY id")
                .map { $0.description }
            return (sources + items + jobs).joined(separator: "\n")
        }
    }
}

import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

/// In-memory tree: `dirs` top-level directories × `subdirs` × `files` files.
/// Hashes are derived from path and mtime, so a changed mtime is changed content.
private struct BenchFS: FolderFileSystem {
    let directories: [String: [FolderEntry]]
    let files: [String: FileStamp]

    static func hash(_ path: String, _ stamp: FileStamp) -> String { "h:\(path):\(stamp.mtimeNs)" }

    func resolve(rootPath: String) throws -> FolderIdentity {
        FolderIdentity(volumeId: "bench", components: ["bench"], rootFileId: "root")
    }
    func caseSensitive(root: FolderSource) throws -> Bool { true }
    func list(root: FolderSource, directory: String) throws -> [FolderEntry] { directories[directory] ?? [] }
    func stat(root: FolderSource, relativePath: String) throws -> FileStamp {
        if relativePath.isEmpty { return FileStamp(identity: "root", mtimeNs: 0, sizeBytes: 0) }
        if directories[relativePath] != nil { return FileStamp(identity: "dir:" + relativePath, mtimeNs: 0, sizeBytes: 0) }
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

    /// `unsupportedEvery`-th file has an unsupported extension; the rest rotate through eligible ones.
    static func make(dirs: Int, subdirs: Int, files perDir: Int, unsupportedEvery: Int,
                     changed: Set<String> = []) -> BenchFS {
        let eligible = ["md", "pdf", "docx", "txt", "xlsx", "eml"], unsupported = ["png", "zip", "exe"]
        var directories: [String: [FolderEntry]] = [:], files: [String: FileStamp] = [:]
        var index = 0
        func dirEntry(_ path: String) -> FolderEntry {
            FolderEntry(relPath: path, isDirectory: true, isLink: false, stamp: FileStamp(identity: "dir:" + path, mtimeNs: 0, sizeBytes: 0))
        }
        directories[""] = (0..<dirs).map { dirEntry(String(format: "d%03d", $0)) }
        for d in 0..<dirs {
            let top = String(format: "d%03d", d)
            directories[top] = (0..<subdirs).map { dirEntry("\(top)/s\($0)") }
            for s in 0..<subdirs {
                let directory = "\(top)/s\(s)"
                directories[directory] = (0..<perDir).map { f -> FolderEntry in
                    index += 1
                    let ext = index % unsupportedEvery == 0 ? unsupported[index % unsupported.count] : eligible[index % eligible.count]
                    let path = "\(directory)/file-\(f).\(ext)"
                    let stamp = FileStamp(identity: "f\(index)", mtimeNs: changed.contains(path) ? 2_000 : 1_000,
                                          sizeBytes: Int64(1_000 + index % 997))
                    files[path] = stamp
                    return FolderEntry(relPath: path, isDirectory: false, isLink: false, stamp: stamp)
                }
            }
        }
        return BenchFS(directories: directories, files: files)
    }
}

private struct BenchClock: IngestLeaseClock {
    func now() -> Int64 { 10 }
    func wait(until: Int64) async throws { try await Task.sleep(nanoseconds: 1_000_000_000) }
}

/// Counts statements and BEGINs (one per store transaction / main-actor store call).
private final class SQLCounter: @unchecked Sendable {
    private let gate = NSLock()
    private var statements = 0, transactions = 0, writes = 0
    /// Off while the emulated status strip reads, so the counts are the scan's own.
    private var isPaused = false
    var paused: Bool {
        get { gate.lock(); defer { gate.unlock() }; return isPaused }
        set { gate.lock(); isPaused = newValue; gate.unlock() }
    }
    func record(_ sql: String) {
        gate.lock(); defer { gate.unlock() }
        guard !isPaused else { return }
        statements += 1
        if sql.hasPrefix("BEGIN") { transactions += 1 }
        if sql.hasPrefix("BEGIN IMMEDIATE") || sql.hasPrefix("BEGIN EXCLUSIVE") { writes += 1 }
    }
    func reset() { gate.lock(); statements = 0; transactions = 0; writes = 0; gate.unlock() }
    var snapshot: (statements: Int, transactions: Int, writes: Int) {
        gate.lock(); defer { gate.unlock() }
        return (statements, transactions, writes)
    }
}

/// Opt-in large-folder rescan benchmark (AINOTEBOOK_SCAN_BENCH=1): a file-backed
/// database with ~8,000 already ingested files (ready + published), then a
/// no-change rescan and a 1 %-changed rescan through the real `FolderScanner`.
/// An observer emulates the status strip: every `indexingStatusDidChange`
/// re-reads the notebook's `IndexingStatus` synchronously on the main actor.
@MainActor
final class FolderScanBenchmarkTests: XCTestCase {
    private func setting(_ name: String, _ fallback: Int) -> Int {
        Int(ProcessInfo.processInfo.environment["AINOTEBOOK_SCAN_BENCH_\(name)"] ?? "") ?? fallback
    }

    func testLargeFolderRescan() async throws {
        guard ProcessInfo.processInfo.environment["AINOTEBOOK_SCAN_BENCH"] == "1" else {
            throw XCTSkip("set AINOTEBOOK_SCAN_BENCH=1 to run the folder rescan benchmark")
        }
        let dirs = setting("DIRS", 40), subdirs = setting("SUBDIRS", 4), perDir = setting("FILES", 50)
        let unsupportedEvery = setting("UNSUPPORTED_EVERY", 20), chunksPerSource = setting("CHUNKS", 8)
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AINOTEBOOK_SCAN_BENCH_DIR"] ?? NSTemporaryDirectory())
        let url = directory.appendingPathComponent("scan-bench-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-journal", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let store = try NotebookStore(path: StorePath(fileURL: url), configuredEmbeddingModelKey: nil)
        let tables = try UnicodeTables.bundled()
        let base = BenchFS.make(dirs: dirs, subdirs: subdirs, files: perDir, unsupportedEvery: unsupportedEvery)
        let notebookId = try XCTUnwrap(store.createNotebook(name: "bench").id)
        let folder = try store.createFolder(notebookId: notebookId, draft: FolderDraft(rootPath: "/bench", displayName: "Bench",
            includeExts: FolderRules.defaults.includeExts, ignoreGlobs: FolderRules.defaults.ignoreGlobs, limitsJSON: "{}",
            encodingFallback: "cp1250", watchEnabled: true), identity: base, now: 0)

        // Initial ingest: the real scanner creates every source, then SQL marks them ready + published.
        try await scan(store, folder: folder.id, fs: base, tables: tables, token: "seed")
        let eligible = try store.runOnDatabase { db -> Int in
            try db.execute(sql: "DROP TRIGGER chunks_ai")
            let rows = try Row.fetchAll(db, sql: "SELECT id,rel_path,mtime FROM sources WHERE folder_id=?", arguments: [folder.id])
            let revision = try db.makeStatement(sql: """
                INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                VALUES (?,1,?,'',1,2,'2026-10-10 00:00:00.000')
                """)
            let publish = try db.makeStatement(sql: """
                UPDATE sources SET current_revision=?,published_revision_id=?,status='ready',content_hash=? WHERE id=?
                """)
            let chunk = try db.makeStatement(sql: """
                INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id,char_start,char_end,lang) VALUES (?,?,?,8,?,?,?,'cs')
                """)
            for row in rows {
                let id: Int64 = row["id"], path: String = row["rel_path"], mtime: Int64 = row["mtime"]
                let hash = BenchFS.hash(path, base.files[path]!)
                XCTAssertEqual(mtime, base.files[path]!.mtimeNs)
                try revision.execute(arguments: [id, hash])
                let revisionId = db.lastInsertedRowID
                try publish.execute(arguments: [revisionId, revisionId, hash, id])
                for ord in 0..<chunksPerSource {
                    try chunk.execute(arguments: [id, ord, "source \(id) chunk \(ord) smlouva faktura report", revisionId, ord * 40, ord * 40 + 40])
                }
            }
            try db.execute(sql: "UPDATE ingest_jobs SET state='done',lease_token=NULL,lease_until=NULL WHERE kind='extract'")
            try db.execute(sql: """
                CREATE TRIGGER chunks_ai AFTER INSERT ON source_chunks BEGIN
                 INSERT INTO chunks_fts(rowid,text,chunk_id) VALUES(new.id,new.text,new.id);
                END
                """)
            return rows.count
        }
        let total = base.files.count
        XCTAssertGreaterThan(eligible, total * 9 / 10)

        let counter = SQLCounter()
        try store.runOnDatabase { db in db.trace { counter.record($0.expandedDescription) } }
        var ingestionNotes = 0, statusNotes = 0, statusReloadNs: UInt64 = 0
        let observers = [
            NotificationCenter.default.addObserver(forName: .folderIngestionDidChange, object: store, queue: nil) { _ in
                MainActor.assumeIsolated { ingestionNotes += 1 }
            },
            NotificationCenter.default.addObserver(forName: .indexingStatusDidChange, object: store, queue: nil) { _ in
                MainActor.assumeIsolated {
                    statusNotes += 1
                    let start = DispatchTime.now().uptimeNanoseconds
                    counter.paused = true
                    _ = try? store.indexingStatus(notebookId: notebookId, now: 10)
                    counter.paused = false
                    statusReloadNs += DispatchTime.now().uptimeNanoseconds - start
                }
            },
        ]
        defer { observers.forEach(NotificationCenter.default.removeObserver) }

        func measure(_ label: String, fs: BenchFS, expectQueued: Int) async throws {
            counter.reset()
            ingestionNotes = 0
            statusNotes = 0
            statusReloadNs = 0
            let before = try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM ingest_jobs WHERE kind='extract' AND state='queued'")! }
            let start = DispatchTime.now().uptimeNanoseconds
            try await scan(store, folder: folder.id, fs: fs, tables: tables, token: label)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            let sql = counter.snapshot
            let queued = try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM ingest_jobs WHERE kind='extract' AND state='queued'")! }
            XCTAssertEqual(queued - before, expectQueued, label)
            XCTAssertEqual(try store.folderSource(id: folder.id).scanState, "idle", label)
            let seen = try store.runOnDatabase { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM scan_items WHERE folder_id=? AND seen_generation=(SELECT scan_generation FROM folder_sources WHERE id=?)",
                                 arguments: [folder.id, folder.id])!
            }
            XCTAssertEqual(seen, total, "\(label): every file is inventoried in the current generation")
            print(String(format: "SCAN-BENCH swift %@ files=%d eligible=%d: %.0f ms, transactions=%d (writes=%d), statements=%d, folderIngestionDidChange=%d, indexingStatusDidChange=%d, status reloads %.0f ms",
                         label, total, eligible, ms, sql.transactions, sql.writes, sql.statements, ingestionNotes, statusNotes,
                         Double(statusReloadNs) / 1e6))
        }

        try await measure("no-change", fs: base, expectQueued: 0)
        let eligiblePaths = try store.runOnDatabase { try String.fetchAll($0, sql: "SELECT rel_path FROM sources ORDER BY id") }
        let changed = Set(stride(from: 0, to: eligiblePaths.count, by: 100).map { eligiblePaths[$0] })
        let modified = BenchFS.make(dirs: dirs, subdirs: subdirs, files: perDir, unsupportedEvery: unsupportedEvery, changed: changed)
        try await measure("changed-1pct", fs: modified, expectQueued: changed.count)
    }

    private func scan(_ store: NotebookStore, folder: Int64, fs: BenchFS, tables: UnicodeTables, token: String) async throws {
        let job = try store.requestFolderScan(folderId: folder, verifyAll: false, now: 10)
        XCTAssertNotNil(try store.claimJob(now: 10, leaseToken: token, id: job))
        try await FolderScanner(store: store, fileSystem: fs, tables: tables, clock: BenchClock())
            .scan(folderId: folder, verifyAll: false, fence: JobFence(jobId: job, leaseToken: token), now: 10, cancelled: { false })
    }
}

import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

/// Counts concurrent `hash` calls and the largest overlap seen.
private final class HashMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var peak = 0
    private(set) var calls = 0
    func enter() { lock.lock(); active += 1; calls += 1; peak = max(peak, active); lock.unlock() }
    func leave() { lock.lock(); active -= 1; lock.unlock() }
    func reset() { lock.lock(); peak = 0; calls = 0; lock.unlock() }
    var snapshot: (peak: Int, calls: Int) { lock.lock(); defer { lock.unlock() }; return (peak, calls) }
}

/// Two-level tree with per-file hash failures: a permission error (its directory
/// becomes incomplete), a file that grew past the limit (`over_limit`), a vanished
/// file (path changed) and an interior link.
private struct TreeFS: FolderFileSystem {
    var directories: [String: [FolderEntry]]
    var files: [String: FileStamp]
    var failures: [String: Error]
    let meter: HashMeter

    func resolve(rootPath: String) throws -> FolderIdentity {
        FolderIdentity(volumeId: "tree", components: ["tree"], rootFileId: "root")
    }
    func caseSensitive(root: FolderSource) throws -> Bool { true }
    func list(root: FolderSource, directory: String) throws -> [FolderEntry] { directories[directory] ?? [] }
    func stat(root: FolderSource, relativePath: String) throws -> FileStamp {
        if relativePath.isEmpty { return FileStamp(identity: "root", mtimeNs: 0, sizeBytes: 0) }
        if directories[relativePath] != nil { return FileStamp(identity: "dir:" + relativePath, mtimeNs: 0, sizeBytes: 0) }
        guard let stamp = files[relativePath] else { throw POSIXError(.ENOENT) }
        return stamp
    }
    func hash(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderRead {
        meter.enter()
        defer { meter.leave() }
        usleep(1_000) // long enough for concurrent hashes to overlap
        if let failure = failures[relativePath] { throw failure }
        guard let stamp = files[relativePath] else { throw POSIXError(.ENOENT) }
        return FolderRead(bytes: Data(), stamp: stamp, sha256: "h:\(relativePath):\(stamp.mtimeNs)")
    }
    func snapshot(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderFileSnapshot {
        throw CocoaError(.featureUnsupported)
    }

    static func make(meter: HashMeter, mtime: (String) -> Int64 = { _ in 1 }) -> TreeFS {
        var directories: [String: [FolderEntry]] = [:], files: [String: FileStamp] = [:]
        func dir(_ path: String) -> FolderEntry {
            FolderEntry(relPath: path, isDirectory: true, isLink: false, stamp: FileStamp(identity: "dir:" + path, mtimeNs: 0, sizeBytes: 0))
        }
        func file(_ path: String, link: Bool = false) -> FolderEntry {
            let stamp = FileStamp(identity: "id:" + path, mtimeNs: mtime(path), sizeBytes: Int64(path.utf8.count))
            if !link { files[path] = stamp }
            return FolderEntry(relPath: path, isDirectory: false, isLink: link, stamp: stamp)
        }
        // Files before and after a subdirectory: look-ahead spans the descent.
        var root: [FolderEntry] = (0..<12).map { (i: Int) -> FolderEntry in file(String(format: "r%02d.md", i)) }
        root.append(dir("a"))
        root.append(dir("b"))
        for i in 12..<20 { root.append(file(String(format: "r%02d.%@", i, i % 4 == 0 ? "png" : "md"))) }
        root.append(file("zlink.md", link: true))
        directories[""] = root
        directories["a"] = (0..<40).map { file(String(format: "a/f%02d.md", $0)) }
        directories["b"] = (0..<40).map { file(String(format: "b/f%02d.txt", $0)) }
        let failures: [String: Error] = [
            "b/f05.txt": CocoaError(.fileReadNoPermission),
            "b/f17.txt": IngestionError(code: "fileLimit"),
            "a/f30.md": POSIXError(.ENOENT),
        ]
        return TreeFS(directories: directories, files: files, failures: failures, meter: meter)
    }
}

private struct TreeClock: IngestLeaseClock {
    func now() -> Int64 { 10 }
    func wait(until: Int64) async throws { throw CancellationError() }
}

/// Parallel look-ahead hashing (contract `ingestion-memory-pressure-v1` addendum A §A.5)
/// commits exactly what the sequential scan committed.
@MainActor
final class FolderScanHashAheadTests: XCTestCase {
    private func makeStore() throws -> NotebookStore {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        _ = try store.createNotebook(name: "nb")
        _ = try store.createFolder(notebookId: 1, draft: FolderDraft(rootPath: "/tree", displayName: "Tree",
            includeExts: ["md", "txt"], ignoreGlobs: [], limitsJSON: "{}", encodingFallback: "cp1250", watchEnabled: true),
            identity: TreeFS.make(meter: HashMeter()), now: 0)
        return store
    }

    private func scan(_ store: NotebookStore, _ fs: TreeFS, width: Int, token: String, verifyAll: Bool) async throws {
        let job = try store.requestFolderScan(folderId: 1, verifyAll: verifyAll, now: 10)
        XCTAssertNotNil(try store.claimJob(now: 10, leaseToken: token, id: job))
        try await FolderScanner(store: store, fileSystem: fs, tables: try UnicodeTables.bundled(), clock: TreeClock(),
                                hashWidth: { width })
            .scan(folderId: 1, verifyAll: verifyAll, fence: JobFence(jobId: job, leaseToken: token), now: 10, cancelled: { false })
    }

    /// Everything a scan decides, independent of row ids and lease tokens.
    private func state(_ store: NotebookStore) throws -> [String] {
        try store.runOnDatabase { db in
            let items = try Row.fetchAll(db, sql: """
                SELECT rel_path,kind,skip_reason,mtime,size_bytes,seen_generation FROM scan_items ORDER BY rel_path
                """).map { "item \($0)" }
            let sources = try Row.fetchAll(db, sql: """
                SELECT rel_path,status,availability,eligible,content_hash,mtime,size_bytes FROM sources ORDER BY rel_path
                """).map { "source \($0)" }
            let jobs = try Row.fetchAll(db, sql: """
                SELECT s.rel_path,j.state FROM ingest_jobs j JOIN sources s ON j.target='source:'||s.id
                WHERE j.kind='extract' ORDER BY s.rel_path,j.id
                """).map { "job \($0)" }
            let folder = try Row.fetchAll(db, sql: "SELECT scan_state,scan_generation,last_scan_error FROM folder_sources").map { "folder \($0)" }
            return items + sources + jobs + folder
        }
    }

    func testParallelHashingCommitsExactlyTheSequentialScan() async throws {
        var results: [[String]] = []
        for width in [1, 4] {
            let meter = HashMeter(), store = try makeStore()
            // First scan (everything new), then Verify all after some files changed, then a stat-only rescan.
            try await scan(store, TreeFS.make(meter: meter), width: width, token: "first", verifyAll: false)
            let first = meter.snapshot
            var changed = TreeFS.make(meter: meter) { $0.hasSuffix("3.md") ? 2 : 1 }
            changed.failures["a/f08.md"] = CocoaError(.fileReadNoPermission)
            changed.directories["b"]?.removeLast(3) // vanished files: missing-marking must agree too
            for path in ["b/f37.txt", "b/f38.txt", "b/f39.txt"] { changed.files[path] = nil }
            try await scan(store, changed, width: width, token: "verify", verifyAll: true)
            try await scan(store, changed, width: width, token: "plain", verifyAll: false)
            XCTAssertGreaterThan(first.calls, 90)
            if width == 1 { XCTAssertEqual(first.peak, 1, "width 1 hashes inline") }
            else { XCTAssertGreaterThan(first.peak, 1, "width \(width) hashes concurrently") }
            XCTAssertLessThanOrEqual(meter.snapshot.peak, width)
            results.append(try state(store))
        }
        XCTAssertEqual(results[0], results[1])
        XCTAssertTrue(results[0].contains { $0.contains("b/f17.txt") && $0.contains("over_limit") }, "fileLimit keeps its meaning")
    }

    func testWidthComesFromTheProviderOncePerScan() async throws {
        let meter = HashMeter(), store = try makeStore()
        let calls = HashMeter()
        let job = try store.requestFolderScan(folderId: 1, verifyAll: false, now: 10)
        XCTAssertNotNil(try store.claimJob(now: 10, leaseToken: "t", id: job))
        try await FolderScanner(store: store, fileSystem: TreeFS.make(meter: meter), tables: try UnicodeTables.bundled(),
                                clock: TreeClock(), hashWidth: { calls.enter(); calls.leave(); return 3 })
            .scan(folderId: 1, verifyAll: false, fence: JobFence(jobId: job, leaseToken: "t"), now: 10, cancelled: { false })
        XCTAssertEqual(calls.snapshot.calls, 1)
        XCTAssertLessThanOrEqual(meter.snapshot.peak, 3)
    }
}

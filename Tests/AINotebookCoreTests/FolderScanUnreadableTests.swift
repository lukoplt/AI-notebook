import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

/// A file that cannot be read during a scan is not observed; only its directory
/// becomes incomplete (contract `ingestion-scan-perf-v1` §5, fixture
/// `ingestion-scan-cadence-v1` operation `unreadable-file`). Windows runs the same cases.
@MainActor
final class FolderScanUnreadableTests: XCTestCase {
    nonisolated private static let treeFiles = ["a.md", "b.md", "sub/b.md", "sub/c.md"]

    private struct Identity: FolderPathIdentity {
        func resolve(rootPath: String) throws -> FolderIdentity {
            FolderIdentity(volumeId: "test", components: ["docs"], rootFileId: "root-1")
        }
    }

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    /// The fixed fixture tree; reading `failing` throws `failure`.
    private struct TreeFS: FolderFileSystem {
        let failing: String
        let failure: Error
        let reads: Reads

        static func stamp(_ path: String) -> FileStamp {
            FileStamp(identity: "id:" + path, mtimeNs: 1, sizeBytes: Int64(path.utf8.count))
        }
        static func file(_ path: String) -> FolderEntry {
            FolderEntry(relPath: path, isDirectory: false, isLink: false, stamp: stamp(path))
        }
        func resolve(rootPath: String) throws -> FolderIdentity { try Identity().resolve(rootPath: rootPath) }
        func caseSensitive(root: FolderSource) throws -> Bool { true }
        func list(root: FolderSource, directory: String) throws -> [FolderEntry] {
            switch directory {
            case "": return [Self.file("a.md"), Self.file("b.md"),
                             FolderEntry(relPath: "sub", isDirectory: true, isLink: false,
                                         stamp: FileStamp(identity: "dir:sub", mtimeNs: 0, sizeBytes: 0))]
            case "sub": return [Self.file("sub/b.md"), Self.file("sub/c.md")]
            default: throw POSIXError(.ENOENT)
            }
        }
        func stat(root: FolderSource, relativePath: String) throws -> FileStamp {
            if relativePath.isEmpty { return FileStamp(identity: "root-1", mtimeNs: 0, sizeBytes: 0) }
            if relativePath == "sub" { return FileStamp(identity: "dir:sub", mtimeNs: 0, sizeBytes: 0) }
            guard FolderScanUnreadableTests.treeFiles.contains(relativePath) else { throw POSIXError(.ENOENT) }
            return Self.stamp(relativePath)
        }
        func hash(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderRead {
            reads.add(relativePath)
            if relativePath == failing { throw failure }
            return FolderRead(bytes: Data(), stamp: Self.stamp(relativePath), sha256: "h:" + relativePath)
        }
        func snapshot(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderFileSnapshot {
            XCTFail("scanner must not snapshot file bodies")
            throw CocoaError(.featureUnsupported)
        }
    }

    private struct Clock: IngestLeaseClock {
        func now() -> Int64 { 10 }
        func wait(until: Int64) async throws { throw CancellationError() }
    }

    private static func failure(_ error: String) -> Error {
        switch error {
        case "permissionDenied": return CocoaError(.fileReadNoPermission)
        case "vanished": return POSIXError(.ENOENT)
        case "changedDuringRead": return IngestionError(code: "changedDuringExtraction")
        case "becameLink": return IngestionError(code: "interiorLink")
        default: preconditionFailure("unknown error \(error)")
        }
    }

    private func scan(known: [String], failing: String, failure: Error) async throws -> (NotebookStore, Reads) {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "nb").id)
        let folder = try store.createFolder(notebookId: notebook, draft: FolderDraft(
            rootPath: "/docs", displayName: "Docs", includeExts: ["md"], ignoreGlobs: [],
            limitsJSON: "{}", encodingFallback: "cp1250", watchEnabled: true), identity: Identity(), now: 0)
        for path in known {
            let source = try store.createSource(notebookId: notebook, type: .markdown, title: path, uri: nil, rawPath: nil)
            try store.attachSource(sourceId: source.id!, folderId: folder.id, relPath: path)
            _ = try store.commitForegroundRevision(sourceId: source.id!, draft: RevisionDraft(
                contentHash: "h", canonicalText: "old", textFormatVersion: 1, chunkerVersion: 2),
                chunks: ScalarChunker.chunk("old"), now: 0, leaseToken: "seed")
        }
        let job = try store.requestFolderScan(folderId: folder.id, verifyAll: false, now: 10)
        XCTAssertNotNil(try store.claimJob(now: 10, leaseToken: "scan", id: job))
        let reads = Reads()
        try await FolderScanner(store: store, fileSystem: TreeFS(failing: failing, failure: failure, reads: reads),
                                tables: try UnicodeTables.bundled(), clock: Clock())
            .scan(folderId: folder.id, verifyAll: false, fence: JobFence(jobId: job, leaseToken: "scan"), now: 10, cancelled: { false })
        return (store, reads)
    }

    /// The fixture projection: folder state, this scan's inventory, sources and queued extractions.
    private func projection(_ store: NotebookStore) throws -> [String: Any] {
        try store.runOnDatabase { db in
            let folder = try Row.fetchOne(db, sql: "SELECT scan_state, scan_generation, last_scan_error FROM folder_sources")!
            let generation: Int64 = folder["scan_generation"]
            return [
                "folder": ["scanState": folder["scan_state"] as String,
                           "lastScanError": (folder["last_scan_error"] as String?) ?? NSNull()] as [String: Any],
                "inventory": try String.fetchAll(db, sql: "SELECT rel_path FROM scan_items WHERE seen_generation=? ORDER BY rel_path",
                                                 arguments: [generation]),
                "queuedExtracts": try String.fetchAll(db, sql: """
                    SELECT s.rel_path FROM ingest_jobs j JOIN sources s ON j.target='source:'||s.id
                    WHERE j.kind='extract' AND j.state='queued' ORDER BY s.rel_path
                    """),
                "sources": try Row.fetchAll(db, sql: "SELECT rel_path, status, availability, eligible FROM sources ORDER BY rel_path").map {
                    ["relPath": $0["rel_path"] as String, "status": $0["status"] as String,
                     "availability": $0["availability"] as String, "eligible": ($0["eligible"] as Bool)] as [String: Any]
                },
            ]
        }
    }

    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    func testUnreadableFileFixture() async throws {
        let fixture = try SharedFixtures.json("contracts/ingestion-scan-cadence-v1.json")
        var count = 0
        for row in try XCTUnwrap(fixture["cases"] as? [[String: Any]]) where row["operation"] as? String == "unreadable-file" {
            count += 1
            let name = row["name"] as! String, input = row["input"] as! [String: Any]
            let failing = input["failing"] as! String
            let (store, reads) = try await scan(known: input["known"] as! [String], failing: failing,
                                                failure: Self.failure(input["error"] as! String))
            XCTAssertTrue(reads.all.contains(failing), name)
            XCTAssertEqual(try json(projection(store)), try json(row["expected"]!), name)
        }
        XCTAssertEqual(count, 8)
    }
}

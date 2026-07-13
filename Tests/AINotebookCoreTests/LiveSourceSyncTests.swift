import XCTest
@testable import AINotebookCore

/// Tests Epic E1/E2 change detection: folder sync ingests new files, skips
/// unchanged ones by hash, and re-ingests changed ones.
@MainActor
final class LiveSourceSyncTests: XCTestCase {

    private func tempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testContentHashChangesWithContent() throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.txt")
        try "hello".write(to: f, atomically: true, encoding: .utf8)
        let h1 = try LiveSourceSync.contentHash(of: f)
        try "hello world".write(to: f, atomically: true, encoding: .utf8)
        let h2 = try LiveSourceSync.contentHash(of: f)
        XCTAssertNotEqual(h1, h2)
        XCTAssertEqual(h1.count, 32) // MD5 hex
    }

    func testSyncIngestsThenSkipsUnchangedThenReingestsChanged() async throws {
        let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("doc.txt")
        try "first version".write(to: f, atomically: true, encoding: .utf8)

        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let sync = LiveSourceSync(store: store, ingestion: IngestionService(store: store))

        // First sync: ingests the new file.
        let n1 = try await sync.syncFolder(notebookId: nb.id!, folder: dir)
        XCTAssertEqual(n1, 1)
        XCTAssertEqual(try store.sources(notebookId: nb.id!).count, 1)

        // Second sync, no change: skips.
        let n2 = try await sync.syncFolder(notebookId: nb.id!, folder: dir)
        XCTAssertEqual(n2, 0, "unchanged file must be skipped by hash")
        XCTAssertEqual(try store.sources(notebookId: nb.id!).count, 1, "no duplicate source created")

        // Change the file: re-ingests the same source.
        try "second, longer version of the document".write(to: f, atomically: true, encoding: .utf8)
        let n3 = try await sync.syncFolder(notebookId: nb.id!, folder: dir)
        XCTAssertEqual(n3, 1, "changed file must be re-ingested")
        XCTAssertEqual(try store.sources(notebookId: nb.id!).count, 1, "still one source (re-ingest, not new)")
    }
}

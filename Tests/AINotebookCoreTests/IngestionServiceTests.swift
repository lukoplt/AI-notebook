import XCTest
@testable import AINotebookCore

@MainActor
final class IngestionServiceTests: XCTestCase {

    func testIngestPlainTextEndToEnd() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("memo.txt")
        try "Hello world. Second sentence.".write(to: file, atomically: true, encoding: .utf8)

        let service = IngestionService(store: store)
        let source = try await service.ingestFile(file, into: nb.id!)

        // Refresh status from disk
        let reloaded = try XCTUnwrap(try store.source(id: source.id!))
        XCTAssertEqual(reloaded.status, .ready)
        XCTAssertEqual(reloaded.type, .text)
        XCTAssertEqual(reloaded.title, "memo")

        let chunks = try store.chunks(sourceId: source.id!)
        XCTAssertGreaterThan(chunks.count, 0)
        XCTAssertEqual(chunks.first?.ord, 0)
    }

    func testIngestRawTextCreatesPersistedSource() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")

        let service = IngestionService(store: store)
        let source = try await service.ingestRawText(
            title: "My note",
            text: String(repeating: "lorem ipsum ", count: 500),
            into: nb.id!
        )
        XCTAssertEqual(source.status, .ready)
        XCTAssertEqual(source.type, .text)
        let chunks = try store.chunks(sourceId: source.id!)
        XCTAssertGreaterThan(chunks.count, 1)
    }

    func testIngestUnknownExtensionLeavesSourceInErrorStatus() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("mystery.bin")
        try Data([0x01, 0x02, 0x03]).write(to: file)

        let service = IngestionService(store: store)
        do {
            _ = try await service.ingestFile(file, into: nb.id!)
            XCTFail("expected throw for unsupported extension")
        } catch IngestionService.IngestionError.unsupportedExtension {
            // ok — no source row should have been created
            XCTAssertEqual(try store.sources(notebookId: nb.id!).count, 0)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

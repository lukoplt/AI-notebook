import XCTest
@testable import AINotebookCore

@MainActor
final class NoteIndexerTests: XCTestCase {

    func testIndexCreatesShadowSourceAndChunks() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(
            notebookId: nb.id!, title: "Recipe", bodyMd: "Mix flour and water."
        )

        let indexer = NoteIndexer(store: store)
        try await indexer.index(noteId: n.id!)

        let reloaded = try XCTUnwrap(try store.note(id: n.id!))
        let sourceId = try XCTUnwrap(reloaded.autoSourceId)

        let shadow = try XCTUnwrap(try store.source(id: sourceId))
        XCTAssertEqual(shadow.type, .note)
        XCTAssertEqual(shadow.notebookId, nb.id!)
        XCTAssertEqual(shadow.title, "Recipe")
        XCTAssertEqual(shadow.status, .ready)

        let chunks = try store.chunks(sourceId: sourceId)
        XCTAssertGreaterThan(chunks.count, 0)
        XCTAssertTrue(chunks.first?.text.contains("flour") == true)
    }

    func testReindexReplacesChunks() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(
            notebookId: nb.id!, title: "T", bodyMd: "original"
        )
        let indexer = NoteIndexer(store: store)
        try await indexer.index(noteId: n.id!)

        try store.updateNote(id: n.id!, title: "T", bodyMd: "rewritten body completely")
        try await indexer.index(noteId: n.id!)

        let sourceId = try XCTUnwrap(try store.note(id: n.id!)?.autoSourceId)
        let chunks = try store.chunks(sourceId: sourceId)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].text.contains("rewritten"))
        XCTAssertFalse(chunks[0].text.contains("original"))
    }

    func testEmptyBodyClearsChunksButKeepsShadow() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(
            notebookId: nb.id!, title: "T", bodyMd: "first content"
        )
        let indexer = NoteIndexer(store: store)
        try await indexer.index(noteId: n.id!)

        try store.updateNote(id: n.id!, title: "T", bodyMd: "")
        try await indexer.index(noteId: n.id!)

        let sourceId = try XCTUnwrap(try store.note(id: n.id!)?.autoSourceId)
        XCTAssertNotNil(try store.source(id: sourceId))
        XCTAssertEqual(try store.chunks(sourceId: sourceId).count, 0)
    }

    func testKickHookFiresAfterIndex() async throws {
        final class CapturingKick: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func bump() { lock.lock(); count += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(
            notebookId: nb.id!, title: "T", bodyMd: "x"
        )
        let kick = CapturingKick()
        let indexer = NoteIndexer(store: store, onChunksWritten: { kick.bump() })
        try await indexer.index(noteId: n.id!)
        XCTAssertEqual(kick.value, 1)
    }
}

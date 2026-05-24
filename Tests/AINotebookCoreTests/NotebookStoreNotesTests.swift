import XCTest
@testable import AINotebookCore

@MainActor
final class NotebookStoreNotesTests: XCTestCase {

    func testCreateAndListNotes() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n1 = try store.createNote(
            notebookId: nb.id!, title: "First", bodyMd: "Hello"
        )
        _ = try store.createNote(
            notebookId: nb.id!, title: "Second", bodyMd: "World"
        )
        let list = try store.notes(notebookId: nb.id!)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(Set(list.map(\.title)), ["First", "Second"])
        XCTAssertEqual(n1.origin, .manual)
    }

    func testUpdateNoteBumpsUpdatedAt() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "v1")
        let originalUpdated = n.updatedAt
        Thread.sleep(forTimeInterval: 0.01)
        try store.updateNote(id: n.id!, title: "T2", bodyMd: "v2")
        let reloaded = try XCTUnwrap(store.note(id: n.id!))
        XCTAssertEqual(reloaded.title, "T2")
        XCTAssertEqual(reloaded.bodyMd, "v2")
        XCTAssertGreaterThan(reloaded.updatedAt, originalUpdated)
    }

    func testDeleteNote() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "x")
        try store.deleteNote(id: n.id!)
        XCTAssertNil(try store.note(id: n.id!))
    }

    func testCreateNoteWithTransformationOriginPreservesRef() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(
            notebookId: nb.id!,
            title: "T",
            bodyMd: "x",
            origin: .transformation,
            originRef: 999
        )
        XCTAssertEqual(n.origin, .transformation)
        XCTAssertEqual(n.originRef, 999)
        let reloaded = try XCTUnwrap(store.note(id: n.id!))
        XCTAssertEqual(reloaded.originRef, 999)
    }
}

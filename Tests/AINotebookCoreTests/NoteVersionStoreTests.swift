import XCTest
@testable import AINotebookCore

@MainActor
final class NoteVersionStoreTests: XCTestCase {

    func testUpdateSnapshotsPreviousBody() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "v1")
        try store.updateNote(id: n.id!, title: "T", bodyMd: "v2")
        let versions = try store.noteVersions(noteId: n.id!)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions[0].bodyMd, "v1")
        XCTAssertEqual(versions[0].reason, .autosave)
    }

    func testManualSnapshot() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "v1")
        try store.snapshotNoteVersion(noteId: n.id!, reason: .manual)
        let versions = try store.noteVersions(noteId: n.id!)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions[0].bodyMd, "v1")
        XCTAssertEqual(versions[0].reason, .manual)
    }

    func testRestoreCreatesNewSnapshotAndOverwritesBody() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "v1")
        try store.updateNote(id: n.id!, title: "T", bodyMd: "v2")
        let versions = try store.noteVersions(noteId: n.id!)
        let v1 = try XCTUnwrap(versions.first)
        try store.restoreNoteVersion(versionId: v1.id!)
        let reloaded = try XCTUnwrap(try store.note(id: n.id!))
        XCTAssertEqual(reloaded.bodyMd, "v1")
        let all = try store.noteVersions(noteId: n.id!)
        XCTAssertGreaterThanOrEqual(all.count, 2)
    }

    func testFiftyRowCapPrunesOldest() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "v0")
        for i in 1...60 {
            try store.updateNote(id: n.id!, title: "T", bodyMd: "v\(i)")
        }
        let versions = try store.noteVersions(noteId: n.id!)
        XCTAssertLessThanOrEqual(versions.count, 50)
    }
}

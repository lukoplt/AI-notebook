import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV6Tests: XCTestCase {

    func testV6AddsColumnsToNotes() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let columns: [Row] = try Row.fetchAll(db, sql: "PRAGMA table_info('notes')")
            let names = columns.compactMap { $0["name"] as String? }
            XCTAssertTrue(names.contains("auto_source_id"), "got: \(names)")
            XCTAssertTrue(names.contains("note_uuid"),      "got: \(names)")
        }
    }

    func testCreatedNoteGetsUuid() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "x")
        XCTAssertFalse(n.noteUuid.isEmpty)
        XCTAssertTrue(n.noteUuid.contains("-"))
        XCTAssertEqual(n.noteUuid.count, 36)
    }

    func testAutoSourceIdStartsNil() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "x")
        XCTAssertNil(n.autoSourceId)
    }
}

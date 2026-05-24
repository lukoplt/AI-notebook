import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV8Tests: XCTestCase {

    func testV8CreatesNoteVersionsTable() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let names: [String] = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            XCTAssertTrue(names.contains("note_versions"), "got: \(names)")
        }
    }

    func testNoteVersionsCascadeOnNoteDelete() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "x")
        try store.runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO note_versions(note_id,title,body_md,saved_at,reason) VALUES (?,?,?,?,?)",
                arguments: [n.id!, "T", "old", Date(), "autosave"]
            )
        }
        try store.deleteNote(id: n.id!)
        let count: Int = try store.runOnDatabase { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM note_versions") ?? -1
        }
        XCTAssertEqual(count, 0)
    }
}

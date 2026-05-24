import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV7Tests: XCTestCase {

    func testV7CreatesAttachmentsTable() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let names: [String] = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            XCTAssertTrue(names.contains("attachments"), "got: \(names)")
        }
    }

    func testAttachmentCascadesOnNoteDelete() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "x")
        try store.runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO attachments(note_id,note_uuid,filename,mime,byte_size,created_at) VALUES (?,?,?,?,?,?)",
                arguments: [n.id!, n.noteUuid, "a.png", "image/png", 123, Date()]
            )
        }
        try store.deleteNote(id: n.id!)
        let count: Int = try store.runOnDatabase { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM attachments") ?? -1
        }
        XCTAssertEqual(count, 0)
    }
}

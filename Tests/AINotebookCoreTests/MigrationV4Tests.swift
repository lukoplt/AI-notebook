import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV4Tests: XCTestCase {
    func testV4CreatesSessionAndMessageTables() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let names: [String] = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            XCTAssertTrue(names.contains("chat_sessions"))
            XCTAssertTrue(names.contains("messages"))
        }
    }

    func testCascadeFromNotebookToSessionsToMessages() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        try store.runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO chat_sessions(notebook_id,title,created_at) VALUES (?,?,?)",
                arguments: [nb.id!, "S", Date()]
            )
            let sessionId = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO messages(session_id,role,content,created_at) VALUES (?,?,?,?)",
                arguments: [sessionId, "user", "hi", Date()]
            )
        }
        try store.deleteNotebook(id: nb.id!)
        try store.runOnDatabase { db in
            let sessions: Int = try Int.fetchOne(db, sql: "SELECT count(*) FROM chat_sessions") ?? -1
            let messages: Int = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages")     ?? -1
            XCTAssertEqual(sessions, 0)
            XCTAssertEqual(messages, 0)
        }
    }
}

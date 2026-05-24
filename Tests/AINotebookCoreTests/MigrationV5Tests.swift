import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV5Tests: XCTestCase {

    func testV5CreatesAllTables() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let names: [String] = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            XCTAssertTrue(names.contains("notes"))
            XCTAssertTrue(names.contains("transformations"))
            XCTAssertTrue(names.contains("transformation_runs"))
        }
    }

    func testNotesCascadeFromNotebook() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        try store.runOnDatabase { db in
            try db.execute(
                sql: """
                INSERT INTO notes(notebook_id,title,body_md,origin,created_at,updated_at)
                VALUES (?,?,?,?,?,?)
                """,
                arguments: [nb.id!, "t", "body", "manual", Date(), Date()]
            )
        }
        try store.deleteNotebook(id: nb.id!)
        let count: Int = try store.runOnDatabase { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM notes") ?? -1
        }
        XCTAssertEqual(count, 0)
    }

    func testTransformationRunsHaveNullableSourceAndNoteRefs() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "src", uri: nil, rawPath: nil
        )
        try store.runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO transformations(name,prompt_template,scope,is_builtin) VALUES (?,?,?,?)",
                arguments: ["t", "p", "source", 1]
            )
            let tid = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO transformation_runs(transformation_id,source_id,result_note_id,ran_at) VALUES (?,?,?,?)",
                arguments: [tid, s.id!, nil, Date()]
            )
        }
        try store.deleteSource(id: s.id!)
        let runRow: Row? = try store.runOnDatabase { db in
            try Row.fetchOne(db, sql: "SELECT source_id FROM transformation_runs LIMIT 1")
        }
        XCTAssertNotNil(runRow)
        XCTAssertTrue(runRow!["source_id"] == nil)
    }
}

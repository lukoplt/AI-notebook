import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV9Tests: XCTestCase {

    func testV9AddsDescriptionColumn() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let cols: [Row] = try Row.fetchAll(db, sql: "PRAGMA table_info('transformations')")
            let names = cols.compactMap { $0["name"] as String? }
            XCTAssertTrue(names.contains("description"), "got: \(names)")
        }
    }

    func testExistingRowsGetEmptyStringDefault() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO transformations(name,prompt_template,scope,is_builtin) VALUES (?,?,?,?)",
                arguments: ["Plain", "x", "source", 0]
            )
            let desc: String? = try String.fetchOne(
                db,
                sql: "SELECT description FROM transformations WHERE name = ?",
                arguments: ["Plain"]
            )
            XCTAssertEqual(desc, "")
        }
    }
}

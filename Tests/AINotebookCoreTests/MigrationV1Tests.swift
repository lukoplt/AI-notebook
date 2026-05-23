import XCTest
import GRDB
@testable import AINotebookCore

final class MigrationV1Tests: XCTestCase {
    func testMigrationCreatesNotebooksTable() throws {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        registerMigrationV1(on: &migrator)
        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let exists = try db.tableExists("notebooks")
            XCTAssertTrue(exists, "notebooks table missing")

            let columns = try db.columns(in: "notebooks").map(\.name).sorted()
            XCTAssertEqual(
                columns,
                ["created_at", "description", "id", "name", "updated_at"]
            )
        }
    }

    func testNameIndexExists() throws {
        let dbQueue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        registerMigrationV1(on: &migrator)
        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let indexes = try db.indexes(on: "notebooks").map(\.name)
            XCTAssertTrue(
                indexes.contains("notebooks_name_idx"),
                "expected notebooks_name_idx, got \(indexes)"
            )
        }
    }
}

import XCTest
import GRDB
@testable import AINotebookCore

final class NotebookTests: XCTestCase {
    func testInitDefaultsTimestamps() {
        let n = Notebook(name: "Research")
        XCTAssertNil(n.id)
        XCTAssertEqual(n.name, "Research")
        XCTAssertEqual(n.description, "")
        XCTAssertEqual(n.createdAt, n.updatedAt)
        XCTAssertLessThan(abs(n.createdAt.timeIntervalSinceNow), 1.0)
    }

    func testExplicitFields() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let n = Notebook(
            id: 42,
            name: "Lit Review",
            description: "PhD readings",
            createdAt: now,
            updatedAt: now
        )
        XCTAssertEqual(n.id, 42)
        XCTAssertEqual(n.name, "Lit Review")
        XCTAssertEqual(n.description, "PhD readings")
        XCTAssertEqual(n.createdAt, now)
        XCTAssertEqual(n.updatedAt, now)
    }

    func testTableNameIsNotebooks() {
        XCTAssertEqual(Notebook.databaseTableName, "notebooks")
    }
}

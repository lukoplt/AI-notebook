import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV10Tests: XCTestCase {

    func testV10AddsSummaryColumn() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let cols: [Row] = try Row.fetchAll(db, sql: "PRAGMA table_info('sources')")
            let names = cols.compactMap { $0["name"] as String? }
            XCTAssertTrue(names.contains("summary"), "got: \(names)")
        }
    }

    func testExistingRowsGetNullSummary() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "X", uri: nil, rawPath: nil
        )
        XCTAssertNil(try store.sourceSummary(id: s.id!))
    }

    func testSetSummaryRoundTrips() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "X", uri: nil, rawPath: nil
        )
        try store.setSourceSummary(id: s.id!, text: "A short summary.")
        XCTAssertEqual(try store.sourceSummary(id: s.id!), "A short summary.")
    }
}

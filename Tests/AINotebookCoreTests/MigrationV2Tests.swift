import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV2Tests: XCTestCase {
    func testV2CreatesAllExpectedTables() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let names: [String] = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type IN ('table','index') ORDER BY name"
            )
            XCTAssertTrue(names.contains("sources"),       "sources missing")
            XCTAssertTrue(names.contains("source_chunks"), "source_chunks missing")
            XCTAssertTrue(names.contains("sources_fts"),   "sources_fts missing")
            XCTAssertTrue(names.contains("chunks_fts"),    "chunks_fts missing")
            XCTAssertTrue(names.contains("idx_sources_notebook"), "idx_sources_notebook missing")
            XCTAssertTrue(names.contains("idx_chunks_source"),    "idx_chunks_source missing")
        }
    }

    func testSourcesFtsKeepsInSyncWithSources() throws {
        let store = try NotebookStore(path: .inMemory)
        let notebook = try store.createNotebook(name: "NB")
        try store.runOnDatabase { db in
            try db.execute(
                sql: """
                INSERT INTO sources(notebook_id,type,title,status,ingested_at)
                VALUES (?,?,?,?,?)
                """,
                arguments: [notebook.id!, "text", "Hello world", "ready", Date()]
            )
            let hits: Int = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM sources_fts WHERE sources_fts MATCH 'hello'"
            ) ?? -1
            XCTAssertEqual(hits, 1)
        }
    }
}

import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV3Tests: XCTestCase {
    private func v3Queue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        registerMigrationV1(on: &migrator)
        registerMigrationV2(on: &migrator)
        registerMigrationV3(on: &migrator)
        try migrator.migrate(queue)
        return queue
    }

    private func seed(_ db: Database) throws -> (source: Int64, chunk: Int64) {
        try db.execute(sql: "INSERT INTO notebooks(name,description,created_at,updated_at) VALUES('NB','',?,?)", arguments: [Date(), Date()])
        let notebook = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO sources(notebook_id,type,title,status,ingested_at) VALUES(?,'text','x','pending',?)", arguments: [notebook, Date()])
        let source = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO source_chunks(source_id,ord,text,token_count) VALUES(?,0,'alpha',1)", arguments: [source])
        return (source, db.lastInsertedRowID)
    }

    func testV3CreatesChunkEmbeddingsTable() throws {
        let queue = try v3Queue()
        try queue.read { db in
            let names = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            XCTAssertTrue(names.contains("chunk_embeddings"), "got: \(names)")
        }
    }

    func testInsertEmbeddingThenReadItBack() throws {
        let queue = try v3Queue()
        let bytes = Data(repeating: 0xAB, count: 768 * 4)
        try queue.write { db in
            let ids = try seed(db)
            try db.execute(sql: "INSERT INTO chunk_embeddings(chunk_id,dim,model,embedding) VALUES(?,?,?,?)", arguments: [ids.chunk, 768, "nomic-embed-text", bytes])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_embeddings"), 1)
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT embedding FROM chunk_embeddings WHERE chunk_id=?", arguments: [ids.chunk]), bytes)
        }
    }

    func testCascadeDeleteWhenChunkDeleted() throws {
        let queue = try v3Queue()
        try queue.write { db in
            let ids = try seed(db)
            // v3 allowed malformed vector bytes; this historical test keeps that exact input.
            try db.execute(sql: "INSERT INTO chunk_embeddings(chunk_id,dim,model,embedding) VALUES(?,?,?,?)", arguments: [ids.chunk, 4, "m", Data([0, 0, 0, 0])])
            try db.execute(sql: "DELETE FROM sources WHERE id=?", arguments: [ids.source])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_embeddings"), 0)
        }
    }
}

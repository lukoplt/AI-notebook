import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV3Tests: XCTestCase {
    func testV3CreatesChunkEmbeddingsTable() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let names: [String] = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            XCTAssertTrue(names.contains("chunk_embeddings"), "got: \(names)")
        }
    }

    func testInsertEmbeddingThenReadItBack() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [ChunkDraft(text: "alpha", tokenCount: 1, pageHint: nil)]
        )
        let chunk = try store.chunks(sourceId: s.id!).first!
        let bytes = Data(repeating: 0xAB, count: 768 * 4)
        try store.runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO chunk_embeddings(chunk_id, dim, model, embedding) VALUES (?,?,?,?)",
                arguments: [chunk.id!, 768, "nomic-embed-text", bytes]
            )
        }
        let count: Int = try store.runOnDatabase { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_embeddings") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    func testCascadeDeleteWhenChunkDeleted() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [ChunkDraft(text: "alpha", tokenCount: 1, pageHint: nil)]
        )
        let chunk = try store.chunks(sourceId: s.id!).first!
        try store.runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO chunk_embeddings(chunk_id, dim, model, embedding) VALUES (?,?,?,?)",
                arguments: [chunk.id!, 4, "m", Data([0, 0, 0, 0])]
            )
        }
        try store.deleteSource(id: s.id!)  // cascades to chunks → cascades to embeddings
        let count: Int = try store.runOnDatabase { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_embeddings") ?? -1
        }
        XCTAssertEqual(count, 0)
    }
}

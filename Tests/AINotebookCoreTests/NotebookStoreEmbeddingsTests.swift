import XCTest
@testable import AINotebookCore

@MainActor
final class NotebookStoreEmbeddingsTests: XCTestCase {

    func testStoreAndLoadEmbedding() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [
                ChunkDraft(text: "alpha", tokenCount: 1),
                ChunkDraft(text: "beta",  tokenCount: 1)
            ]
        )
        let chunks = try store.chunks(sourceId: s.id!)
        let v1 = EmbeddingVector(values: [1, 0, 0, 0])
        let v2 = EmbeddingVector(values: [0, 1, 0, 0])
        try store.storeEmbedding(chunkId: chunks[0].id!, model: "m", vector: v1)
        try store.storeEmbedding(chunkId: chunks[1].id!, model: "m", vector: v2)

        let loaded = try store.embeddings(notebookId: nb.id!, model: "m")
        XCTAssertEqual(loaded.count, 2)
        let pairs = Dictionary(uniqueKeysWithValues: loaded.map { ($0.chunkId, $0.vector.values) })
        XCTAssertEqual(pairs[chunks[0].id!], v1.values)
        XCTAssertEqual(pairs[chunks[1].id!], v2.values)
    }

    func testUnembeddedChunksReturnsOnlyMissingForModel() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: (0..<3).map { ChunkDraft(text: "c\($0)", tokenCount: 1) }
        )
        let chunks = try store.chunks(sourceId: s.id!)
        try store.storeEmbedding(
            chunkId: chunks[0].id!,
            model: "m",
            vector: EmbeddingVector(values: [0])
        )
        let pending = try store.unembeddedChunks(model: "m", limit: 100)
        let ids = Set(pending.map(\.id))
        XCTAssertEqual(ids, Set([chunks[1].id!, chunks[2].id!]))
    }

    func testReplaceEmbeddingOverwrites() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [ChunkDraft(text: "a", tokenCount: 1)]
        )
        let chunk = try store.chunks(sourceId: s.id!).first!
        try store.storeEmbedding(
            chunkId: chunk.id!,
            model: "m",
            vector: EmbeddingVector(values: [1, 0])
        )
        try store.storeEmbedding(
            chunkId: chunk.id!,
            model: "m",
            vector: EmbeddingVector(values: [0, 1])
        )
        let loaded = try store.embeddings(notebookId: nb.id!, model: "m")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].vector.values, [0, 1])
    }

    func testDeleteAllEmbeddingsForModelClearsOnlyThatModel() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [ChunkDraft(text: "a", tokenCount: 1)]
        )
        let chunk = try store.chunks(sourceId: s.id!).first!
        try store.storeEmbedding(
            chunkId: chunk.id!, model: "m1", vector: EmbeddingVector(values: [1])
        )
        try store.deleteAllEmbeddings(model: "m1")
        XCTAssertEqual(try store.embeddings(notebookId: nb.id!, model: "m1").count, 0)
    }
}

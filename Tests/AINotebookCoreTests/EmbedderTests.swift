import XCTest
@testable import AINotebookCore

@MainActor
final class EmbedderTests: XCTestCase {

    final class MockEmbeddingClient: EmbeddingProducing, @unchecked Sendable {
        var calls: [[String]] = []
        var dim: Int = 4
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            calls.append(inputs)
            return inputs.map { _ in (0..<self.dim).map { _ in Float.random(in: -1...1) } }
        }
    }

    func testEmbedAllInsertsRowsForEveryChunk() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: (0..<5).map { ChunkDraft(text: "c\($0)", tokenCount: 1) }
        )
        let client = MockEmbeddingClient()
        let embedder = Embedder(store: store, client: client, model: "m", batchSize: 2)
        let count = try await embedder.embedAllPending()
        XCTAssertEqual(count, 5)
        XCTAssertEqual(try store.unembeddedCount(model: "m"), 0)
        XCTAssertEqual(client.calls.count, 3, "should batch 2+2+1")
        XCTAssertEqual(client.calls.map(\.count), [2, 2, 1])
    }

    func testEmbedAllSkipsAlreadyEmbedded() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [
                ChunkDraft(text: "a", tokenCount: 1),
                ChunkDraft(text: "b", tokenCount: 1)
            ]
        )
        let chunks = try store.chunks(sourceId: s.id!)
        try store.storeEmbedding(
            chunkId: chunks[0].id!, model: "m",
            vector: EmbeddingVector(values: [1, 0, 0, 0])
        )

        let client = MockEmbeddingClient()
        let embedder = Embedder(store: store, client: client, model: "m", batchSize: 10)
        let count = try await embedder.embedAllPending()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(client.calls[0], ["b"])
    }
}

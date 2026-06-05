import XCTest
@testable import AINotebookCore

@MainActor
final class RetrieverTests: XCTestCase {

    final class MockEmbeddingClient: EmbeddingProducing, @unchecked Sendable {
        let queryVector: [Float]
        init(queryVector: [Float]) { self.queryVector = queryVector }
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            inputs.map { _ in queryVector }
        }
    }

    func testReturnsTopKByCosineSimilarity() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [
                ChunkDraft(text: "alpha apple",   tokenCount: 2),
                ChunkDraft(text: "beta banana",   tokenCount: 2),
                ChunkDraft(text: "gamma grape",   tokenCount: 2)
            ]
        )
        let chunks = try store.chunks(sourceId: s.id!)
        // 1st chunk vector aligned with query → highest cosine
        try store.storeEmbedding(chunkId: chunks[0].id!, model: "m", vector: EmbeddingVector(values: [1, 0]))
        try store.storeEmbedding(chunkId: chunks[1].id!, model: "m", vector: EmbeddingVector(values: [0, 1]))
        try store.storeEmbedding(chunkId: chunks[2].id!, model: "m", vector: EmbeddingVector(values: [-1, 0]))

        let client = MockEmbeddingClient(queryVector: [1, 0])
        let retriever = Retriever(store: store, client: client, model: "m")
        let hits = try await retriever.search(
            notebookId: nb.id!, query: "doesn't matter — mock", topK: 2
        )
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].chunkId, chunks[0].id!, "highest-cosine chunk first")
    }

    func testFTSAloneSurfacesTextMatchWhenNoEmbedding() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [
                ChunkDraft(text: "the quick brown fox", tokenCount: 4),
                ChunkDraft(text: "lazy dog sleeps",     tokenCount: 3)
            ]
        )
        let chunks = try store.chunks(sourceId: s.id!)
        // No embeddings stored — vector branch finds nothing, FTS branch finds "fox".
        let client = MockEmbeddingClient(queryVector: [0, 0])
        let retriever = Retriever(store: store, client: client, model: "m")
        let hits = try await retriever.search(
            notebookId: nb.id!, query: "fox", topK: 5
        )
        let chunkIds = Set(hits.map(\.chunkId))
        XCTAssertTrue(chunkIds.contains(chunks[0].id!))
    }

    func testRRFRanksFusedAboveSingleSourceMatch() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [
                // Chunk A: matches both vector AND text
                ChunkDraft(text: "fox runs fast",      tokenCount: 3),
                // Chunk B: matches text only
                ChunkDraft(text: "fox sleeps softly",  tokenCount: 3),
                // Chunk C: matches vector only
                ChunkDraft(text: "unrelated greeting", tokenCount: 2)
            ]
        )
        let chunks = try store.chunks(sourceId: s.id!)
        try store.storeEmbedding(chunkId: chunks[0].id!, model: "m", vector: EmbeddingVector(values: [1, 0]))
        try store.storeEmbedding(chunkId: chunks[2].id!, model: "m", vector: EmbeddingVector(values: [0.9, 0.1]))

        let client = MockEmbeddingClient(queryVector: [1, 0])
        let retriever = Retriever(store: store, client: client, model: "m")
        let hits = try await retriever.search(
            notebookId: nb.id!, query: "fox", topK: 3
        )
        XCTAssertEqual(hits.first?.chunkId, chunks[0].id!, "fused hit ranks above single-source hits")
    }

    func testSourceIdsFilterRestrictsToSelectedSources() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let a = try store.createSource(
            notebookId: nb.id!, type: .text, title: "A", uri: nil, rawPath: nil
        )
        let b = try store.createSource(
            notebookId: nb.id!, type: .text, title: "B", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: a.id!, chunks: [ChunkDraft(text: "fox in source A", tokenCount: 4)]
        )
        try store.replaceChunks(
            sourceId: b.id!, chunks: [ChunkDraft(text: "fox in source B", tokenCount: 4)]
        )
        let aChunk = try store.chunks(sourceId: a.id!).first!.id!
        let bChunk = try store.chunks(sourceId: b.id!).first!.id!
        try store.storeEmbedding(chunkId: aChunk, model: "m", vector: EmbeddingVector(values: [1, 0]))
        try store.storeEmbedding(chunkId: bChunk, model: "m", vector: EmbeddingVector(values: [1, 0]))

        let client = MockEmbeddingClient(queryVector: [1, 0])
        let retriever = Retriever(store: store, client: client, model: "m")

        // No filter → both sources surface.
        let allHits = try await retriever.search(
            notebookId: nb.id!, query: "fox", topK: 5
        )
        let allSources = Set(allHits.map(\.sourceId))
        XCTAssertTrue(allSources.contains(a.id!))
        XCTAssertTrue(allSources.contains(b.id!))

        // Filter to A → only A's chunk.
        let filtered = try await retriever.search(
            notebookId: nb.id!, query: "fox", topK: 5, sourceIds: [a.id!]
        )
        XCTAssertEqual(Set(filtered.map(\.sourceId)), [a.id!])
        XCTAssertEqual(Set(filtered.map(\.chunkId)), [aChunk])
    }
}

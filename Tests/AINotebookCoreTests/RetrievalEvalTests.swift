import XCTest
@testable import AINotebookCore

/// Deterministic embedder: each text maps to a basis vector picked by the
/// `topicN` token it contains, so a query and its matching chunk get identical
/// vectors (cosine 1) and unrelated chunks get orthogonal ones.
private struct TopicEmbedder: EmbeddingProducing {
    let dim: Int
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        inputs.map { text in
            var v = [Float](repeating: 0, count: dim)
            for i in 0..<dim where text.contains("topic\(i)") { v[i] = 1 }
            if v.allSatisfy({ $0 == 0 }) { v[0] = 0.0001 } // never all-zero
            return v
        }
    }
}

/// Validates the D2 recall@k harness math against the real retriever using a
/// deterministic embedder, so the eval's arithmetic is trustworthy before it
/// gates D1/D3 decisions.
@MainActor
final class RetrievalEvalTests: XCTestCase {

    func testRecallIsPerfectWhenGoldChunksAreRetrievable() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "Eval")
        let embedder = TopicEmbedder(dim: 8)
        let model = "test-model"

        // One source, one distinct-topic chunk per query.
        let src = try store.createSource(notebookId: nb.id!, type: .text, title: "Corpus", uri: nil, rawPath: nil)
        let drafts = (0..<5).map { ChunkDraft(text: "This passage is about topic\($0) and its details.", tokenCount: 8) }
        try store.replaceChunks(sourceId: src.id!, chunks: drafts)
        let chunks = try store.chunks(sourceId: src.id!)
        for chunk in chunks {
            let vec = try await embedder.embed(model: model, inputs: [chunk.text])[0]
            try store.storeEmbedding(chunkId: chunk.id!, model: model, vector: EmbeddingVector(values: vec))
        }

        let retriever = Retriever(store: store, client: embedder, model: model)
        let queries = chunks.enumerated().map { (i, chunk) in
            EvalQuery(text: "Tell me about topic\(i)", goldChunkIds: [chunk.id!])
        }

        let report = try await RetrievalEval.run(retriever: retriever, notebookId: nb.id!, queries: queries, k: 8)
        XCTAssertEqual(report.meanRecall, 1.0, accuracy: 0.0001, report.summary)
        XCTAssertEqual(report.hitRate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(report.k, 8)
    }

    func testRecallIsZeroWhenGoldChunkIsNotInCorpus() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "Eval")
        let embedder = TopicEmbedder(dim: 8)
        let model = "test-model"
        let src = try store.createSource(notebookId: nb.id!, type: .text, title: "Corpus", uri: nil, rawPath: nil)
        try store.replaceChunks(sourceId: src.id!, chunks: [ChunkDraft(text: "about topic0", tokenCount: 2)])
        let chunk = try store.chunks(sourceId: src.id!).first!
        let vec = try await embedder.embed(model: model, inputs: [chunk.text])[0]
        try store.storeEmbedding(chunkId: chunk.id!, model: model, vector: EmbeddingVector(values: vec))

        let retriever = Retriever(store: store, client: embedder, model: model)
        // Gold id 99999 does not exist, so recall must be 0.
        let report = try await RetrievalEval.run(
            retriever: retriever, notebookId: nb.id!,
            queries: [EvalQuery(text: "topic0", goldChunkIds: [99999])], k: 8)
        XCTAssertEqual(report.meanRecall, 0.0, accuracy: 0.0001)
        XCTAssertFalse(report.perQuery[0].hit)
    }
}

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

/// Embedder whose cosine against the query is dictated by a `score=<x>` marker
/// in the chunk text, so a test can place a gold chunk at an exact rank.
/// Query vectors are `[1, 0]`; a chunk carrying `score=s` embeds as
/// `[s, sqrt(1 - s*s)]`, which is a unit vector whose cosine with `[1, 0]` is
/// exactly `s`.
private struct ScoredEmbedder: EmbeddingProducing {
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        inputs.map { text in
            guard let range = text.range(of: "score="),
                  let s = Float(text[range.upperBound...].prefix(6)) else {
                return [1, 0]
            }
            return [s, (1 - s * s).squareRoot()]
        }
    }
}

/// The eval must be able to fetch a wide candidate window and *then* cut to the
/// production top-k, because that is how the reranker headroom in FR-D2 is
/// measured: a reranker cannot promote a chunk the retriever never fetched.
@MainActor
final class RetrievalEvalFetchWindowTests: XCTestCase {

    /// 20 chunks whose cosine descends 0.99, 0.98, … so rank is fully
    /// determined. No chunk contains the query token, so the FTS branch
    /// contributes nothing and vector rank alone decides the outcome.
    private func makeCorpus() throws -> (NotebookStore, Int64, [SourceChunk]) {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "Fetch window")
        let src = try store.createSource(
            notebookId: nb.id!, type: .text, title: "Corpus", uri: nil, rawPath: nil)
        let drafts = (0..<20).map { i in
            ChunkDraft(text: "passage \(i) score=\(String(format: "%.4f", 0.99 - Float(i) * 0.01))",
                       tokenCount: 4)
        }
        try store.replaceChunks(sourceId: src.id!, chunks: drafts)
        let chunks = try store.chunks(sourceId: src.id!)
        return (store, nb.id!, chunks)
    }

    private func embedAll(_ store: NotebookStore, _ chunks: [SourceChunk]) async throws {
        let embedder = ScoredEmbedder()
        for chunk in chunks {
            let vec = try await embedder.embed(model: "m", inputs: [chunk.text])[0]
            try store.storeEmbedding(chunkId: chunk.id!, model: "m", vector: EmbeddingVector(values: vec))
        }
    }

    func testResultsAreCutToKEvenWhenTheFetchWindowIsWider() async throws {
        let (store, nbId, chunks) = try makeCorpus()
        try await embedAll(store, chunks)
        let retriever = Retriever(store: store, client: ScoredEmbedder(), model: "m")

        // chunks[1] is vector rank 2; chunks[9] is rank 10. Fetch 20 either way,
        // but cut at 3 — so only the first survives.
        let near = try await RetrievalEval.run(
            retriever: retriever, notebookId: nbId,
            queries: [EvalQuery(text: "zzz", goldChunkIds: [chunks[1].id!])], k: 3, fetchK: 20)
        XCTAssertEqual(near.meanRecall, 1.0, accuracy: 0.0001, near.summary)

        let far = try await RetrievalEval.run(
            retriever: retriever, notebookId: nbId,
            queries: [EvalQuery(text: "zzz", goldChunkIds: [chunks[9].id!])], k: 3, fetchK: 20)
        XCTAssertEqual(far.meanRecall, 0.0, accuracy: 0.0001, far.summary)
        XCTAssertEqual(far.k, 3, "the report reports the cut, not the fetch window")
    }

    func testFetchWindowBoundsWhatCanBeRetrievedAtAll() async throws {
        let (store, nbId, chunks) = try makeCorpus()
        try await embedAll(store, chunks)
        let retriever = Retriever(store: store, client: ScoredEmbedder(), model: "m")
        let gold = [EvalQuery(text: "zzz", goldChunkIds: [chunks[14].id!])]

        // Cut is 20 both times; only the fetch window differs. A chunk outside
        // the window cannot appear no matter how generous the cut is.
        let narrow = try await RetrievalEval.run(
            retriever: retriever, notebookId: nbId, queries: gold, k: 20, fetchK: 10)
        XCTAssertEqual(narrow.meanRecall, 0.0, accuracy: 0.0001, narrow.summary)

        let wide = try await RetrievalEval.run(
            retriever: retriever, notebookId: nbId, queries: gold, k: 20, fetchK: 20)
        XCTAssertEqual(wide.meanRecall, 1.0, accuracy: 0.0001, wide.summary)
    }
}

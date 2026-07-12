import XCTest
import GRDB
@testable import AINotebookCore

/// Emits a fixed string as a single streamed token.
private struct FixedChat: ChatStreaming {
    let reply: String
    func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            cont.yield(reply)
            cont.finish()
        }
    }
}

/// Core-layer tests for Epic D1 (contextual enrichment) and Epic E (live source
/// sync bookkeeping, web search parsing) macOS parity.
@MainActor
final class EpicDECoreTests: XCTestCase {

    private func seedSourceWithChunks(_ store: NotebookStore, count: Int) throws -> Int64 {
        let nb = try store.createNotebook(name: "NB")
        let src = try store.createSource(notebookId: nb.id!, type: .text, title: "Doc", uri: nil, rawPath: nil)
        let drafts = (0..<count).map { ChunkDraft(text: "chunk \($0) body", tokenCount: 3) }
        try store.replaceChunks(sourceId: src.id!, chunks: drafts)
        return src.id!
    }

    // MARK: D1 — chunk context

    func testSetChunkContextPersistsAndFeedsEmbeddingText() throws {
        let store = try NotebookStore(path: .inMemory)
        let srcId = try seedSourceWithChunks(store, count: 1)
        let chunk = try store.chunks(sourceId: srcId).first!
        try store.setChunkContext(chunkId: chunk.id!, context: "About photosynthesis.")
        let reloaded = try store.chunks(sourceId: srcId).first!
        XCTAssertEqual(reloaded.context, "About photosynthesis.")
        XCTAssertEqual(reloaded.embeddingText, "About photosynthesis.\n\nchunk 0 body")
    }

    func testEmbeddingTextWithoutContextIsJustText() {
        let c = SourceChunk(sourceId: 1, ord: 0, text: "body", tokenCount: 1)
        XCTAssertEqual(c.embeddingText, "body")
    }

    func testContextualEnricherSetsContextOnEveryChunk() async throws {
        let store = try NotebookStore(path: .inMemory)
        let srcId = try seedSourceWithChunks(store, count: 3)
        let enricher = ContextualEnricher(store: store, chat: FixedChat(reply: "  ctx  "), model: { "m" })
        try await enricher.enrichSource(sourceId: srcId)
        let contexts = try store.chunks(sourceId: srcId).map(\.context)
        XCTAssertEqual(contexts, ["ctx", "ctx", "ctx"], "every chunk gets trimmed context")
    }

    func testEnricherPromptShape() {
        let p = ContextualEnricher.contextPrompt(docPreview: "DOC", chunkText: "CHUNK")
        XCTAssertTrue(p.contains("<document>\nDOC\n</document>"))
        XCTAssertTrue(p.contains("<chunk>\nCHUNK\n</chunk>"))
        XCTAssertTrue(p.contains("1-2 sentences"))
    }

    // MARK: E1/E2 — live source sync

    func testUpdateAndReadSyncInfo() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let src = try store.createSource(notebookId: nb.id!, type: .text, title: "S", uri: nil, rawPath: "/tmp/x.txt")
        XCTAssertNil(try store.sourceContentHash(id: src.id!))
        let when = Date()
        try store.updateSourceSyncInfo(id: src.id!, lastSyncedAt: when, contentHash: "ABC123")
        XCTAssertEqual(try store.sourceContentHash(id: src.id!), "ABC123")
        let reloaded = try store.source(id: src.id!)!
        XCTAssertEqual(reloaded.contentHash, "ABC123")
        XCTAssertNotNil(reloaded.lastSyncedAt)
    }

    // MARK: E3 — web search parsing

    func testWebSearchParseTakesAbstractThenTopicsUpToMax() {
        let doc = DuckDuckGoWebSearch.DdgResponse(
            AbstractText: "Main abstract",
            AbstractURL: "http://a",
            Heading: "Topic",
            RelatedTopics: [
                .init(Text: "Related one", FirstURL: "http://1"),
                .init(Text: "Related two", FirstURL: "http://2"),
                .init(Text: "  ", FirstURL: "http://blank"),
                .init(Text: "Related three", FirstURL: "http://3"),
            ]
        )
        let results = DuckDuckGoWebSearch.parse(doc, query: "q", maxResults: 3)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].title, "Topic")
        XCTAssertEqual(results[0].snippet, "Main abstract")
        XCTAssertEqual(results[1].snippet, "Related one")
        XCTAssertEqual(results[2].snippet, "Related two")
    }

    func testWebSearchContextRendersCitableBlocks() {
        let r = [WebSearchResult(title: "T", snippet: "S", url: "http://u")]
        let ctx = WebSearchContext.render(r)
        XCTAssertTrue(ctx.hasPrefix("WEB SEARCH RESULTS"))
        XCTAssertTrue(ctx.contains("[W1] T"))
        XCTAssertEqual(WebSearchContext.render([]), "")
    }
}

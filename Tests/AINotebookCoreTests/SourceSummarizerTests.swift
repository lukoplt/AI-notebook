import XCTest
@testable import AINotebookCore

@MainActor
final class SourceSummarizerTests: XCTestCase {

    final class MockChatClient: ChatStreaming, @unchecked Sendable {
        var capturedMessages: [[ChatTurn]] = []
        let tokens: [String]
        init(tokens: [String]) { self.tokens = tokens }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            capturedMessages.append(messages)
            let toks = tokens
            return AsyncThrowingStream { continuation in
                Task {
                    for t in toks { continuation.yield(t) }
                    continuation.finish()
                }
            }
        }
    }

    func testSummarizesPersistsAndReturns() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "X", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [
                ChunkDraft(text: "alpha apple", tokenCount: 2),
                ChunkDraft(text: "beta banana", tokenCount: 2)
            ]
        )
        let chat = MockChatClient(tokens: ["This is ", "the summary."])
        let summarizer = SourceSummarizer(store: store, chat: chat, chatModel: "m")

        let summary = try await summarizer.summarize(sourceId: s.id!)
        XCTAssertEqual(summary, "This is the summary.")
        XCTAssertEqual(try store.sourceSummary(id: s.id!), "This is the summary.")
        XCTAssertEqual(chat.capturedMessages.count, 1)
        XCTAssertEqual(chat.capturedMessages[0].first?.role, .user)
    }

    func testNoChunksReturnsEmptyWithoutCallingModel() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "X", uri: nil, rawPath: nil
        )
        let chat = MockChatClient(tokens: ["unused"])
        let summarizer = SourceSummarizer(store: store, chat: chat, chatModel: "m")

        let summary = try await summarizer.summarize(sourceId: s.id!)
        XCTAssertEqual(summary, "")
        XCTAssertTrue(chat.capturedMessages.isEmpty)
        XCTAssertNil(try store.sourceSummary(id: s.id!))
    }
}

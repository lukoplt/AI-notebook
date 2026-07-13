import XCTest
@testable import AINotebookCore

/// Verifies Epic E3 web-search integration in ChatEngine: results are injected
/// as a USER-role turn (never the system prompt) and only when opted in.
@MainActor
final class EpicE3WebSearchChatTests: XCTestCase {

    private final class Emb: EmbeddingProducing, @unchecked Sendable {
        func embed(model: String, inputs: [String]) async throws -> [[Float]] { inputs.map { _ in [1, 0] } }
    }
    private final class Chat: ChatStreaming, @unchecked Sendable {
        var captured: [[ChatTurn]] = []
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            captured.append(messages)
            return AsyncThrowingStream { c in Task { c.yield("ok"); c.finish() } }
        }
    }
    private struct FakeWeb: WebSearch {
        func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
            [WebSearchResult(title: "Wiki", snippet: "Relevant web fact", url: "http://x")]
        }
    }

    private func engine(_ store: NotebookStore, _ chat: Chat, web: WebSearch?) -> ChatEngine {
        ChatEngine(store: store, retriever: Retriever(store: store, client: Emb(), model: "emb"),
                   chat: chat, chatModel: "m", webSearch: web)
    }

    func testWebResultsInjectedAsUserTurnNotSystem() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")
        let chat = Chat()
        let eng = engine(store, chat, web: FakeWeb())

        _ = try await eng.send(sessionId: session.id!, notebookId: nb.id!, userText: "q", useWebSearch: true) { _ in }

        let turns = try XCTUnwrap(chat.captured.first)
        let webTurn = turns.first { $0.content.contains("Relevant web fact") }
        XCTAssertNotNil(webTurn, "web results must be present in the turns")
        XCTAssertEqual(webTurn?.role, .user, "web results must be a user turn, not system")
        let systemTurn = turns.first { $0.role == .system }
        XCTAssertFalse(systemTurn?.content.contains("Relevant web fact") ?? false,
                       "web results must NOT be in the system prompt")
    }

    func testNoWebSearchWhenNotOptedIn() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")
        let chat = Chat()
        let eng = engine(store, chat, web: FakeWeb())

        _ = try await eng.send(sessionId: session.id!, notebookId: nb.id!, userText: "q", useWebSearch: false) { _ in }

        let turns = try XCTUnwrap(chat.captured.first)
        XCTAssertNil(turns.first { $0.content.contains("Relevant web fact") },
                     "no web results when the per-message toggle is off")
    }
}

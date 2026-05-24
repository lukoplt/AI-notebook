import XCTest
@testable import AINotebookCore

@MainActor
final class ChatEngineRetryTests: XCTestCase {

    final class FlakyChat: ChatStreaming, @unchecked Sendable {
        var failuresRemaining: Int
        let tokens: [String]
        var attempts = 0
        init(failuresRemaining: Int, tokens: [String]) {
            self.failuresRemaining = failuresRemaining
            self.tokens = tokens
        }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            attempts += 1
            let shouldFail = failuresRemaining > 0
            if shouldFail { failuresRemaining -= 1 }
            let toks = tokens
            return AsyncThrowingStream { c in
                Task {
                    if shouldFail {
                        c.finish(throwing: URLError(.timedOut))
                        return
                    }
                    for t in toks { c.yield(t) }
                    c.finish()
                }
            }
        }
    }

    final class StaticEmbedder: EmbeddingProducing, @unchecked Sendable {
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            inputs.map { _ in [1, 0] }
        }
    }

    func testRetriesOnceOnTimeoutThenSucceeds() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")

        let chat = FlakyChat(failuresRemaining: 1, tokens: ["ok"])
        let retriever = Retriever(store: store, client: StaticEmbedder(), model: "m")
        let engine = ChatEngine(store: store, retriever: retriever, chat: chat,
                                chatModel: "m", retryAttempts: 1, retryBackoffMillis: 1)

        let msg = try await engine.send(
            sessionId: session.id!, notebookId: nb.id!, userText: "hi"
        ) { _ in }
        XCTAssertEqual(msg.content, "ok")
        XCTAssertEqual(chat.attempts, 2)
    }

    func testGivesUpAfterMaxAttempts() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")

        let chat = FlakyChat(failuresRemaining: 99, tokens: ["ok"])
        let retriever = Retriever(store: store, client: StaticEmbedder(), model: "m")
        let engine = ChatEngine(store: store, retriever: retriever, chat: chat,
                                chatModel: "m", retryAttempts: 2, retryBackoffMillis: 1)

        do {
            _ = try await engine.send(
                sessionId: session.id!, notebookId: nb.id!, userText: "hi"
            ) { _ in }
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(chat.attempts, 3)
        }
    }
}

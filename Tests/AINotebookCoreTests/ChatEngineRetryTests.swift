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

    final class ThrowingChat: ChatStreaming, @unchecked Sendable {
        let error: Error
        var attempts = 0
        init(error: Error) { self.error = error }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            attempts += 1
            let err = error
            return AsyncThrowingStream { c in c.finish(throwing: err) }
        }
    }

    /// Shared fixture: a fresh in-memory store + one chat session in one notebook,
    /// mirroring the store/notebook/session setup inline in the tests below
    /// (this file has no pre-existing shared helper, so it's introduced here).
    private func makeChatFixture() throws -> (store: NotebookStore, sessionId: Int64, notebookId: Int64) {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")
        return (store, session.id!, nb.id!)
    }

    /// Shared fixture: wraps `chat` in a `ChatEngine` with a `StaticEmbedder`-backed
    /// `Retriever`, mirroring the retriever/engine construction inline in the tests
    /// below. `retryAttempts: 2` matches the file's existing `testGivesUpAfterMaxAttempts`
    /// value; `retryBackoffMillis: 1` keeps the suite fast.
    private func makeEngine(store: NotebookStore, chat: ChatStreaming, retryAttempts: Int = 2) -> ChatEngine {
        let retriever = Retriever(store: store, client: StaticEmbedder(), model: "m")
        return ChatEngine(store: store, retriever: retriever, chat: chat,
                           chatModel: "m", retryAttempts: retryAttempts, retryBackoffMillis: 1)
    }

    func testAuthErrorIsNotRetried() async throws {
        let (store, sessionId, notebookId) = try makeChatFixture()
        let chat = ThrowingChat(error: ProviderError.auth("Invalid API key (401)."))
        let engine = makeEngine(store: store, chat: chat)
        do {
            _ = try await engine.send(sessionId: sessionId, notebookId: notebookId, userText: "hi", onToken: { _ in })
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .auth = e else { return XCTFail("expected .auth, got \(e)") }
        }
        XCTAssertEqual(chat.attempts, 1, "401 must not be retried")
    }

    func testConsentRequiredIsNotRetried() async throws {
        let (store, sessionId, notebookId) = try makeChatFixture()
        let chat = ThrowingChat(error: ProviderError.consentRequired)
        let engine = makeEngine(store: store, chat: chat)
        do {
            _ = try await engine.send(sessionId: sessionId, notebookId: notebookId, userText: "hi", onToken: { _ in })
            XCTFail("expected throw")
        } catch let e as ProviderError {
            XCTAssertEqual(e, .consentRequired)
        }
        XCTAssertEqual(chat.attempts, 1, "consentRequired must not be retried — the user must grant consent, retrying cannot help")
    }

    func testRefusalIsNotRetried() async throws {
        let (store, sessionId, notebookId) = try makeChatFixture()
        let chat = ThrowingChat(error: ProviderError.refusal)
        let engine = makeEngine(store: store, chat: chat)
        do {
            _ = try await engine.send(sessionId: sessionId, notebookId: notebookId, userText: "hi", onToken: { _ in })
            XCTFail("expected throw")
        } catch let e as ProviderError {
            XCTAssertEqual(e, .refusal)
        }
        XCTAssertEqual(chat.attempts, 1)
    }

    func testRateLimitRetriesWithServerHint() async throws {
        let (store, sessionId, notebookId) = try makeChatFixture()
        let chat = ThrowingChat(error: ProviderError.rateLimit(retryAfterSeconds: 0.01))
        let engine = makeEngine(store: store, chat: chat)   // retryAttempts: 2
        do {
            _ = try await engine.send(sessionId: sessionId, notebookId: notebookId, userText: "hi", onToken: { _ in })
            XCTFail("expected throw")
        } catch let e as ProviderError {
            XCTAssertEqual(e, .rateLimit(retryAfterSeconds: 0.01))
        }
        XCTAssertEqual(chat.attempts, 3, "initial + 2 retries")
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

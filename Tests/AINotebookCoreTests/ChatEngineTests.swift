import XCTest
@testable import AINotebookCore

@MainActor
final class ChatEngineTests: XCTestCase {

    final class MockEmbeddingClient: EmbeddingProducing, @unchecked Sendable {
        let q: [Float]
        init(q: [Float] = [1, 0]) { self.q = q }
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            inputs.map { _ in q }
        }
    }

    final class MockChatClient: ChatStreaming, @unchecked Sendable {
        var capturedMessages: [[ChatTurn]] = []
        let tokens: [String]
        init(tokens: [String]) { self.tokens = tokens }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            capturedMessages.append(messages)
            let toks = tokens
            return AsyncThrowingStream { continuation in
                Task {
                    for t in toks {
                        continuation.yield(t)
                    }
                    continuation.finish()
                }
            }
        }
    }

    func testEndToEndStreamsTokensThenPersistsMessages() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "src", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [ChunkDraft(text: "the sky is blue", tokenCount: 4)]
        )
        let chunkId = try store.chunks(sourceId: s.id!).first!.id!
        try store.storeEmbedding(
            chunkId: chunkId, model: "emb",
            vector: EmbeddingVector(values: [1, 0])
        )
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")

        let chat = MockChatClient(tokens: ["The sky ", "is blue ", "[1]."])
        let retriever = Retriever(store: store, client: MockEmbeddingClient(), model: "emb")

        let engine = ChatEngine(
            store: store,
            retriever: retriever,
            chat: chat,
            chatModel: "llama-test"
        )

        final class TokenCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [String] = []
            func append(_ s: String) {
                lock.lock(); defer { lock.unlock() }
                items.append(s)
            }
            var snapshot: [String] {
                lock.lock(); defer { lock.unlock() }
                return items
            }
        }
        let collector = TokenCollector()
        let final = try await engine.send(
            sessionId: session.id!,
            notebookId: nb.id!,
            userText: "what colour is the sky?"
        ) { token in
            collector.append(token)
        }
        let streamed = collector.snapshot

        XCTAssertEqual(streamed.joined(), "The sky is blue [1].")
        XCTAssertEqual(final.content, "The sky is blue [1].")
        XCTAssertEqual(final.citations.first?.chunkId, chunkId)

        let persisted = try store.messages(sessionId: session.id!)
        XCTAssertEqual(persisted.count, 2)
        XCTAssertEqual(persisted[0].role, .user)
        XCTAssertEqual(persisted[0].content, "what colour is the sky?")
        XCTAssertEqual(persisted[1].role, .assistant)
        XCTAssertEqual(persisted[1].citations.first?.chunkId, chunkId)

        XCTAssertEqual(chat.capturedMessages.count, 1)
        let sent = chat.capturedMessages[0]
        XCTAssertEqual(sent.first?.role, .system)
        XCTAssertEqual(sent.last?.role, .user)
        XCTAssertEqual(sent.last?.content, "what colour is the sky?")
    }
}

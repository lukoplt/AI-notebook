import XCTest
@testable import AINotebookCore

@MainActor
final class ChatEngineCurrentNoteContextTests: XCTestCase {

    final class CapturingChat: ChatStreaming, @unchecked Sendable {
        var captured: [[ChatTurn]] = []
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            captured.append(messages)
            return AsyncThrowingStream { c in
                Task { c.yield("ok"); c.finish() }
            }
        }
    }
    final class StaticEmbedder: EmbeddingProducing, @unchecked Sendable {
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            inputs.map { _ in [1, 0] }
        }
    }

    func testCurrentNoteContextAppearsInSystemPrompt() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")

        let chat = CapturingChat()
        let retriever = Retriever(store: store, client: StaticEmbedder(), model: "m")
        let engine = ChatEngine(store: store, retriever: retriever, chat: chat, chatModel: "m")

        _ = try await engine.send(
            sessionId: session.id!,
            notebookId: nb.id!,
            userText: "what?",
            currentNoteContent: "Ingredient list: flour 500g, water 300g."
        ) { _ in }

        let systemTurn = try XCTUnwrap(chat.captured.first?.first)
        XCTAssertEqual(systemTurn.role, .system)
        XCTAssertTrue(systemTurn.content.contains("CURRENTLY OPEN NOTE"))
        XCTAssertTrue(systemTurn.content.contains("flour 500g"))
    }

    func testNilCurrentNoteContextLeavesPromptUnchanged() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")

        let chat = CapturingChat()
        let retriever = Retriever(store: store, client: StaticEmbedder(), model: "m")
        let engine = ChatEngine(store: store, retriever: retriever, chat: chat, chatModel: "m")

        _ = try await engine.send(
            sessionId: session.id!,
            notebookId: nb.id!,
            userText: "what?"
        ) { _ in }

        let systemTurn = try XCTUnwrap(chat.captured.first?.first)
        XCTAssertFalse(systemTurn.content.contains("CURRENTLY OPEN NOTE"))
    }
}

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

    func testCurrentNoteContextAppearsOnlyInLabelledUserNoteSection() async throws {
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

        let turns = try XCTUnwrap(chat.captured.first)
        let systemTurn = try XCTUnwrap(turns.first)
        XCTAssertEqual(systemTurn.role, .system)
        XCTAssertFalse(systemTurn.content.contains("flour 500g"), "the open note is data, never system text")
        let finalTurn = try XCTUnwrap(turns.last)
        XCTAssertEqual(finalTurn.role, .user)
        XCTAssertTrue(finalTurn.content.contains(
            "[NOTE — NOT CONTENT OF THE SELECTED FOLDER]\nIngredient list: flour 500g, water 300g.\n[/NOTE — NOT CONTENT OF THE SELECTED FOLDER]"))
        XCTAssertEqual(turns.filter { $0.content.contains("flour 500g") }.count, 1)
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

        let turns = try XCTUnwrap(chat.captured.first)
        XCTAssertFalse(turns.contains { $0.content.contains("NOT CONTENT OF THE SELECTED FOLDER") })
        XCTAssertFalse(turns.contains { $0.content.contains("CURRENTLY OPEN NOTE") })
    }
}

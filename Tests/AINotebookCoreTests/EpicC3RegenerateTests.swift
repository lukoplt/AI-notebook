import XCTest
@testable import AINotebookCore

/// Tests the Epic C3 regenerate path and C1 instructions injection added to
/// ChatEngine.
@MainActor
final class EpicC3RegenerateTests: XCTestCase {

    private final class Emb: EmbeddingProducing, @unchecked Sendable {
        func embed(model: String, inputs: [String]) async throws -> [[Float]] { inputs.map { _ in [1, 0] } }
    }

    private final class Chat: ChatStreaming, @unchecked Sendable {
        var captured: [[ChatTurn]] = []
        var tokens: [String]
        init(_ tokens: [String]) { self.tokens = tokens }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            captured.append(messages)
            let toks = tokens
            return AsyncThrowingStream { c in
                Task { for t in toks { c.yield(t) }; c.finish() }
            }
        }
    }

    private func makeEngine(_ store: NotebookStore, _ chat: Chat, model: String = "m1") -> ChatEngine {
        ChatEngine(store: store, retriever: Retriever(store: store, client: Emb(), model: "emb"), chat: chat, chatModel: model)
    }

    func testRegenerateReplacesLastAssistantAndTagsModel() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")
        let chat = Chat(["first answer"])
        let engine = makeEngine(store, chat)

        _ = try await engine.send(sessionId: session.id!, notebookId: nb.id!, userText: "q") { _ in }
        XCTAssertEqual(try store.messages(sessionId: session.id!).map(\.role), [.user, .assistant])

        chat.tokens = ["second answer"]
        _ = try await engine.regenerate(sessionId: session.id!, notebookId: nb.id!, model: "m2") { _ in }

        let msgs = try store.messages(sessionId: session.id!)
        XCTAssertEqual(msgs.map(\.role), [.user, .assistant], "still one exchange — old answer replaced")
        XCTAssertEqual(msgs.last?.content, "second answer")
        XCTAssertEqual(msgs.last?.model, "m2")
    }

    func testInstructionsReachSystemPrompt() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        try store.updateNotebookInstructions(id: nb.id!, instructions: "Always answer in haiku.")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")
        let chat = Chat(["ok"])
        let engine = makeEngine(store, chat)

        _ = try await engine.send(sessionId: session.id!, notebookId: nb.id!, userText: "q") { _ in }

        let systemTurn = chat.captured.first?.first { $0.role == .system }
        XCTAssertNotNil(systemTurn)
        XCTAssertTrue(systemTurn!.content.contains("NOTEBOOK INSTRUCTIONS:\nAlways answer in haiku."),
                      "system prompt should carry notebook instructions")
    }

    func testRegenerateWithoutUserMessageThrows() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")
        let engine = makeEngine(store, Chat(["x"]))
        do {
            _ = try await engine.regenerate(sessionId: session.id!, notebookId: nb.id!) { _ in }
            XCTFail("expected throw")
        } catch let e as ChatEngineError {
            XCTAssertEqual(e, .noUserMessageToRegenerate)
        }
    }
}

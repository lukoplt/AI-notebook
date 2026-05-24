import XCTest
@testable import AINotebookCore

@MainActor
final class TransformationNotebookScopeTests: XCTestCase {

    final class MockChat: ChatStreaming, @unchecked Sendable {
        var captured: [[ChatTurn]] = []
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            captured.append(messages)
            return AsyncThrowingStream { c in
                Task { c.yield("Summary of all"); c.finish() }
            }
        }
    }

    func testRunNotebookScopeConcatenatesAllSources() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s1 = try store.createSource(notebookId: nb.id!, type: .text, title: "A", uri: nil, rawPath: nil)
        let s2 = try store.createSource(notebookId: nb.id!, type: .text, title: "B", uri: nil, rawPath: nil)
        try store.replaceChunks(sourceId: s1.id!, chunks: [ChunkDraft(text: "A1", tokenCount: 1)])
        try store.replaceChunks(sourceId: s2.id!, chunks: [ChunkDraft(text: "B1", tokenCount: 1)])
        let t = try store.createTransformation(
            name: "Cross", promptTemplate: "ALL:\n{{source_text}}", scope: .notebook, isBuiltin: false
        )

        let chat = MockChat()
        let engine = TransformationEngine(store: store, chat: chat, chatModel: "m")
        let note = try await engine.runNotebookScope(
            transformationId: t.id!, notebookId: nb.id!
        )
        XCTAssertEqual(note.bodyMd, "Summary of all")
        XCTAssertEqual(note.notebookId, nb.id!)
        let userTurn = chat.captured.first?.last
        XCTAssertTrue(userTurn?.content.contains("A1") == true)
        XCTAssertTrue(userTurn?.content.contains("B1") == true)
    }
}

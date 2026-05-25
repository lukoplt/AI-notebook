import XCTest
@testable import AINotebookCore

@MainActor
final class TransformationBatchTests: XCTestCase {

    final class MockChat: ChatStreaming, @unchecked Sendable {
        var calls = 0
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            calls += 1
            return AsyncThrowingStream { c in
                Task { c.yield("ok\(self.calls)"); c.finish() }
            }
        }
    }

    func testRunsTemplateOnEverySourceProducingOneNoteEach() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s1 = try store.createSource(notebookId: nb.id!, type: .text, title: "A", uri: nil, rawPath: nil)
        let s2 = try store.createSource(notebookId: nb.id!, type: .text, title: "B", uri: nil, rawPath: nil)
        let s3 = try store.createSource(notebookId: nb.id!, type: .text, title: "C", uri: nil, rawPath: nil)
        try store.replaceChunks(sourceId: s1.id!, chunks: [ChunkDraft(text: "a", tokenCount: 1)])
        try store.replaceChunks(sourceId: s2.id!, chunks: [ChunkDraft(text: "b", tokenCount: 1)])
        try store.replaceChunks(sourceId: s3.id!, chunks: [ChunkDraft(text: "c", tokenCount: 1)])
        let t = try store.createTransformation(
            name: "Sum", promptTemplate: "X:\n{{source_text}}", scope: .source, isBuiltin: false
        )
        let chat = MockChat()
        let engine = TransformationEngine(store: store, chat: chat, chatModel: "m")

        let notes = try await engine.runOnAllSources(
            transformationId: t.id!, notebookId: nb.id!
        ) { _, _ in }

        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(chat.calls, 3)
        let allNotes = try store.notes(notebookId: nb.id!)
        XCTAssertEqual(allNotes.filter { $0.origin == .transformation }.count, 3)
    }

    func testEmptyNotebookReturnsEmptyArray() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let t = try store.createTransformation(
            name: "Sum", promptTemplate: "{{source_text}}", scope: .source, isBuiltin: false
        )
        let chat = MockChat()
        let engine = TransformationEngine(store: store, chat: chat, chatModel: "m")
        let notes = try await engine.runOnAllSources(
            transformationId: t.id!, notebookId: nb.id!
        ) { _, _ in }
        XCTAssertEqual(notes.count, 0)
    }
}

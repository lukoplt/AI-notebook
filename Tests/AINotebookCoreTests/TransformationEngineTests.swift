import XCTest
@testable import AINotebookCore

@MainActor
final class TransformationEngineTests: XCTestCase {

    final class MockChatClient: ChatStreaming, @unchecked Sendable {
        var captured: [[ChatTurn]] = []
        let tokens: [String]
        init(tokens: [String]) { self.tokens = tokens }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            captured.append(messages)
            let toks = tokens
            return AsyncThrowingStream { c in
                Task {
                    for t in toks { c.yield(t) }
                    c.finish()
                }
            }
        }
    }

    func testRunsTemplateOverSourceAndSavesAsNote() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "Doc", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [
                ChunkDraft(text: "Alpha facts.", tokenCount: 2),
                ChunkDraft(text: "Beta facts.",  tokenCount: 2)
            ]
        )
        let template = try store.createTransformation(
            name: "Sum", promptTemplate: "TEMPLATE:\n{{source_text}}",
            scope: .source, isBuiltin: false
        )

        let chat = MockChatClient(tokens: ["- Alpha\n", "- Beta\n"])
        let engine = TransformationEngine(store: store, chat: chat, chatModel: "m")

        let note = try await engine.run(transformationId: template.id!, sourceId: s.id!)

        XCTAssertEqual(note.origin, .transformation)
        XCTAssertEqual(note.bodyMd, "- Alpha\n- Beta\n")
        XCTAssertTrue(note.title.contains("Sum"))
        XCTAssertEqual(note.notebookId, nb.id!)

        let runs = try store.transformationRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].sourceId, s.id!)
        XCTAssertEqual(runs[0].resultNoteId, note.id)

        XCTAssertEqual(chat.captured.count, 1)
        let userTurn = chat.captured[0].last!
        XCTAssertEqual(userTurn.role, .user)
        XCTAssertTrue(userTurn.content.contains("Alpha facts"))
        XCTAssertTrue(userTurn.content.contains("Beta facts"))
        XCTAssertTrue(userTurn.content.contains("TEMPLATE:"))
    }

    func testRejectsMissingSource() async throws {
        let store = try NotebookStore(path: .inMemory)
        let _ = try store.createNotebook(name: "NB")
        let template = try store.createTransformation(
            name: "T", promptTemplate: "{{source_text}}", scope: .source, isBuiltin: false
        )
        let chat = MockChatClient(tokens: [])
        let engine = TransformationEngine(store: store, chat: chat, chatModel: "m")
        do {
            _ = try await engine.run(transformationId: template.id!, sourceId: 999)
            XCTFail("expected throw")
        } catch TransformationEngine.RunError.sourceNotFound {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

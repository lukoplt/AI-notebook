import XCTest
@testable import AINotebookCore

@MainActor
final class TransformationEngineStreamTests: XCTestCase {

    final class StaggeredChat: ChatStreaming, @unchecked Sendable {
        let tokens: [String]
        init(tokens: [String]) { self.tokens = tokens }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            let toks = tokens
            return AsyncThrowingStream { c in
                Task {
                    for t in toks { c.yield(t) }
                    c.finish()
                }
            }
        }
    }

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

    func testStreamsTokensWhileRunning() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "src", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [ChunkDraft(text: "body", tokenCount: 1)]
        )
        let t = try store.createTransformation(
            name: "X", promptTemplate: "{{source_text}}", scope: .source, isBuiltin: false
        )

        let chat = StaggeredChat(tokens: ["alpha ", "beta ", "gamma"])
        let engine = TransformationEngine(store: store, chat: chat, chatModel: "m")

        let collector = TokenCollector()
        let note = try await engine.run(
            transformationId: t.id!, sourceId: s.id!
        ) { token in
            collector.append(token)
        }
        let received = collector.snapshot
        XCTAssertEqual(received, ["alpha ", "beta ", "gamma"])
        XCTAssertEqual(note.bodyMd, "alpha beta gamma")
    }
}

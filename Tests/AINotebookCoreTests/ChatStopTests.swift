import XCTest
@testable import AINotebookCore

/// UI redesign C1 — the composer Stop button. Cancelling the turn's task stops
/// the stream; the question Core already saved stays, and the app keeps the
/// partial answer with the shared `ChatSessionState` rules through the same
/// commit a complete answer uses (macOS ChatViewModel.keepStoppedAnswer;
/// Windows parity: App.Tests ChatStopTests).
@MainActor
final class ChatStopTests: XCTestCase {

    /// Streams its tokens, then never finishes until the consumer is cancelled.
    final class StallingChat: ChatStreaming, @unchecked Sendable {
        let tokens: [String]
        init(tokens: [String]) { self.tokens = tokens }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            let toks = tokens
            return AsyncThrowingStream { c in
                for t in toks { c.yield(t) }
            }
        }
    }

    final class StaticEmbedder: EmbeddingProducing, @unchecked Sendable {
        func embed(model: String, inputs: [String]) async throws -> [[Float]] { inputs.map { _ in [1, 0] } }
    }

    final class Draft: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        func append(_ token: String) { lock.lock(); value += token; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testStoppedTurnKeepsTheQuestionAndThePartialAnswer() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB").id!
        let sid = try store.createChatSession(notebookId: nb, title: "T").id!
        let engine = ChatEngine(store: store, retriever: Retriever(store: store, client: StaticEmbedder(), model: "m"),
                                chat: StallingChat(tokens: ["Partial ", "answer [1]\n"]), chatModel: "m",
                                retryBackoffMillis: 1)
        let intent = try await engine.captureIntent(sessionId: sid, notebookId: nb, question: "What is it?", scope: .all)
        let handle = try await engine.prepare(intent)
        let draft = Draft()
        let turn = Task {
            try await engine.sendPrepared(handle, expectedKey: handle.key, onToken: { draft.append($0) })
        }
        for _ in 0..<500 where draft.text != "Partial answer [1]\n" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(draft.text, "Partial answer [1]\n")

        turn.cancel() // Stop
        if case .success = await turn.result { XCTFail("a stopped turn must not complete") }
        // Core saved the question when streaming began, and no answer.
        XCTAssertEqual(try store.messages(sessionId: sid).map(\.role), [.user])

        let answer = try XCTUnwrap(ChatSessionState.stoppedAnswer(draft.text, isReplacement: false))
        let saved = try store.commitContextAssistant(
            sessionId: sid, content: answer,
            citations: ChatSessionState.stoppedCitations(answer: answer, citationMap: handle.request.citationMap),
            model: handle.transport.storageModel, replacesAssistantId: nil, replacesUserId: nil, replacementUserText: nil)
        XCTAssertEqual(saved.citations, []) // [1] was not in the (empty) pack
        let history = try store.messages(sessionId: sid)
        XCTAssertEqual(history.map(\.role), [.user, .assistant])
        XCTAssertEqual(history.map(\.content), ["What is it?", "Partial answer [1]"])
    }

    /// Stopped after streaming began but before any token: the question Core
    /// saved is removed (it returns to the composer), so sending it again
    /// stores it once.
    func testStoppedTurnWithoutTokensRemovesItsQuestion() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB").id!
        let sid = try store.createChatSession(notebookId: nb, title: "T").id!
        try store.appendMessage(ChatMessage(sessionId: sid, role: .user, content: "Earlier?"))
        try store.appendMessage(ChatMessage(sessionId: sid, role: .assistant, content: "Earlier."))
        let newestIdBeforeSend = try store.messages(sessionId: sid).compactMap(\.id).max()
        let engine = ChatEngine(store: store, retriever: Retriever(store: store, client: StaticEmbedder(), model: "m"),
                                chat: StallingChat(tokens: []), chatModel: "m", retryBackoffMillis: 1)
        let intent = try await engine.captureIntent(sessionId: sid, notebookId: nb, question: "What is it?", scope: .all)
        let handle = try await engine.prepare(intent)
        let draft = Draft()
        let turn = Task {
            try await engine.sendPrepared(handle, expectedKey: handle.key, onToken: { draft.append($0) })
        }
        for _ in 0..<500 where try store.messages(sessionId: sid).count < 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        turn.cancel() // Stop before any token
        if case .success = await turn.result { XCTFail("a stopped turn must not complete") }
        XCTAssertEqual(draft.text, "")
        XCTAssertNil(ChatSessionState.stoppedAnswer(draft.text, isReplacement: false))
        XCTAssertTrue(ChatSessionState.returnsQuestion(partial: draft.text, isReplacement: false))

        let history = try store.messages(sessionId: sid)
        XCTAssertEqual(history.map(\.content), ["Earlier?", "Earlier.", "What is it?"])
        let orphan = try XCTUnwrap(ChatSessionState.orphanedQuestionId(
            question: "What is it?", messages: history, newestIdBeforeSend: newestIdBeforeSend))
        XCTAssertTrue(try store.deleteUnansweredQuestion(sessionId: sid, messageId: orphan))
        XCTAssertEqual(try store.messages(sessionId: sid).map(\.content), ["Earlier?", "Earlier."])

        // Sending again stores the question once.
        let again = ChatEngine(store: store, retriever: Retriever(store: store, client: StaticEmbedder(), model: "m"),
                               chat: FixedChat(answer: "Done."), chatModel: "m", retryBackoffMillis: 1)
        let resend = try await again.captureIntent(sessionId: sid, notebookId: nb, question: "What is it?", scope: .all)
        let resent = try await again.prepare(resend)
        _ = try await again.sendPrepared(resent, expectedKey: resent.key, onToken: { _ in })
        XCTAssertEqual(try store.messages(sessionId: sid).map(\.content),
                       ["Earlier?", "Earlier.", "What is it?", "Done."])
    }

    func testDeleteUnansweredQuestionOnlyRemovesTheNewestUserRowOfItsSession() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB").id!
        let sid = try store.createChatSession(notebookId: nb, title: "T").id!
        let other = try store.createChatSession(notebookId: nb, title: "U").id!
        let question = try store.appendContextUser(sessionId: sid, text: "Q").id!
        let answer = try store.commitContextAssistant(
            sessionId: sid, content: "A", citations: [], model: "m",
            replacesAssistantId: nil, replacesUserId: nil, replacementUserText: nil).id!
        XCTAssertFalse(try store.deleteUnansweredQuestion(sessionId: sid, messageId: question)) // answered
        XCTAssertFalse(try store.deleteUnansweredQuestion(sessionId: sid, messageId: answer))   // not a user row
        let unanswered = try store.appendContextUser(sessionId: sid, text: "Q2").id!
        XCTAssertFalse(try store.deleteUnansweredQuestion(sessionId: other, messageId: unanswered)) // other session
        XCTAssertFalse(try store.deleteUnansweredQuestion(sessionId: sid, messageId: 9_999))
        XCTAssertEqual(try store.messages(sessionId: sid).map(\.content), ["Q", "A", "Q2"])
        XCTAssertTrue(try store.deleteUnansweredQuestion(sessionId: sid, messageId: unanswered))
        XCTAssertEqual(try store.messages(sessionId: sid).map(\.content), ["Q", "A"])
    }

    /// Streams one complete answer.
    final class FixedChat: ChatStreaming, @unchecked Sendable {
        let answer: String
        init(answer: String) { self.answer = answer }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            let text = answer
            return AsyncThrowingStream { c in
                c.yield(text)
                c.finish()
            }
        }
    }
}

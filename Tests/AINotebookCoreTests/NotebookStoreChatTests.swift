import XCTest
@testable import AINotebookCore

@MainActor
final class NotebookStoreChatTests: XCTestCase {

    func testCreateAndListSessions() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s1 = try store.createChatSession(notebookId: nb.id!, title: "First")
        _ = try store.createChatSession(notebookId: nb.id!, title: "Second")
        let list = try store.chatSessions(notebookId: nb.id!)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(Set(list.map(\.title)), ["First", "Second"])
        XCTAssertEqual(s1.title, "First")
    }

    func testAppendAndFetchMessages() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")
        try store.appendMessage(ChatMessage(
            sessionId: session.id!, role: .user, content: "hello"
        ))
        try store.appendMessage(ChatMessage(
            sessionId: session.id!, role: .assistant, content: "hi [1]",
            citations: [Citation(marker: 1, chunkId: 42, sourceId: 7, snippet: "snip")]
        ))
        let msgs = try store.messages(sessionId: session.id!)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].content, "hello")
        XCTAssertEqual(msgs[1].role, .assistant)
        XCTAssertEqual(msgs[1].citations.count, 1)
        XCTAssertEqual(msgs[1].citations[0].chunkId, 42)
    }

    func testDeleteSessionCascadesMessages() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")
        try store.appendMessage(ChatMessage(sessionId: session.id!, role: .user, content: "x"))
        try store.deleteChatSession(id: session.id!)
        XCTAssertEqual(try store.messages(sessionId: session.id!).count, 0)
    }
}

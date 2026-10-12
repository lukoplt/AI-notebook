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
    // MARK: Rename (UI redesign C1)

    func testRenameTrimsAndPersistsTitle() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "Old")
        let renamed = try store.renameChatSession(id: session.id!, title: "  New title \n")
        XCTAssertEqual(renamed.title, "New title")
        XCTAssertEqual(renamed.id, session.id)
        let stored = try XCTUnwrap(store.chatSessions(notebookId: nb.id!).first)
        XCTAssertEqual(stored.title, "New title")
        XCTAssertEqual(stored.createdAt, renamed.createdAt)
        XCTAssertEqual(stored.createdAt.timeIntervalSince1970, session.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRenameRejectsBlankTitleAndKeepsOldOne() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "Keep")
        XCTAssertThrowsError(try store.renameChatSession(id: session.id!, title: " \n\t ")) { error in
            XCTAssertEqual(error as? StoreError, .invalidChatTitle(" \n\t "))
        }
        XCTAssertEqual(try store.chatSessions(notebookId: nb.id!).map(\.title), ["Keep"])
    }

    func testRenameUnknownSessionThrowsNotFound() throws {
        let store = try NotebookStore(path: .inMemory)
        XCTAssertThrowsError(try store.renameChatSession(id: 4242, title: "x")) { error in
            XCTAssertEqual(error as? StoreError, .chatSessionNotFound(id: 4242))
        }
    }

    func testRenameTouchesOnlyThatSessionAndKeepsMessages() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let first = try store.createChatSession(notebookId: nb.id!, title: "first")
        let second = try store.createChatSession(notebookId: nb.id!, title: "second")
        try store.appendMessage(ChatMessage(sessionId: first.id!, role: .user, content: "q"))
        try store.renameChatSession(id: first.id!, title: "renamed")
        XCTAssertEqual(try store.messages(sessionId: first.id!).map(\.content), ["q"])
        let titles = Dictionary(uniqueKeysWithValues: try store.chatSessions(notebookId: nb.id!).map { ($0.id!, $0.title) })
        XCTAssertEqual(titles, [first.id!: "renamed", second.id!: "second"])
    }
}

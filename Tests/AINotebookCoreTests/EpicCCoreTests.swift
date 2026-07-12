import XCTest
import GRDB
@testable import AINotebookCore

/// Core-layer tests for Epic C macOS parity: per-notebook instructions,
/// source sets, and chat edit/regenerate (message model column).
@MainActor
final class EpicCCoreTests: XCTestCase {

    // MARK: Instructions (FR-C1)

    func testInstructionsRoundTrip() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        XCTAssertEqual(try store.notebookInstructions(id: nb.id!), "")
        try store.updateNotebookInstructions(id: nb.id!, instructions: "Answer in Czech.")
        XCTAssertEqual(try store.notebookInstructions(id: nb.id!), "Answer in Czech.")
    }

    func testSystemPromptPrependsInstructions() {
        let prompt = SystemPrompt.compose(hits: [], notebookInstructions: "  Be terse.  ")
        XCTAssertTrue(prompt.hasPrefix("NOTEBOOK INSTRUCTIONS:\nBe terse."), "got: \(prompt.prefix(60))")
    }

    func testSystemPromptOmitsEmptyInstructions() {
        let prompt = SystemPrompt.compose(hits: [], notebookInstructions: "   ")
        XCTAssertFalse(prompt.contains("NOTEBOOK INSTRUCTIONS"))
    }

    // MARK: Source sets (FR-C2)

    func testSourceSetCrudAndMembers() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s1 = try store.createSource(notebookId: nb.id!, type: .text, title: "S1", uri: nil, rawPath: nil)
        let s2 = try store.createSource(notebookId: nb.id!, type: .text, title: "S2", uri: nil, rawPath: nil)
        let set = try store.createSourceSet(notebookId: nb.id!, name: "Key docs")
        try store.setSourceSetMembers(setId: set.id, sourceIds: [s1.id!, s2.id!])
        XCTAssertEqual(Set(try store.sourceSetMembers(setId: set.id)), Set([s1.id!, s2.id!]))

        try store.setSourceSetMembers(setId: set.id, sourceIds: [s1.id!]) // replace
        XCTAssertEqual(try store.sourceSetMembers(setId: set.id), [s1.id!])

        try store.renameSourceSet(id: set.id, name: "Renamed")
        XCTAssertEqual(try store.sourceSets(notebookId: nb.id!).first?.name, "Renamed")

        try store.deleteSourceSet(id: set.id)
        XCTAssertTrue(try store.sourceSets(notebookId: nb.id!).isEmpty)
    }

    func testDeletingSourceSetCascadesMembers() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s1 = try store.createSource(notebookId: nb.id!, type: .text, title: "S1", uri: nil, rawPath: nil)
        let set = try store.createSourceSet(notebookId: nb.id!, name: "Set")
        try store.setSourceSetMembers(setId: set.id, sourceIds: [s1.id!])
        try store.deleteSourceSet(id: set.id)
        // Members row is gone (FK cascade); querying by the dead set id is empty.
        XCTAssertTrue(try store.sourceSetMembers(setId: set.id).isEmpty)
    }

    // MARK: Edit + regenerate (FR-C3)

    func testAssistantMessageStoresModel() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "C")
        _ = try store.appendAssistantMessage(sessionId: session.id!, content: "hi", citations: [], model: "anthropic-id:claude-sonnet-4-6")
        let msgs = try store.messages(sessionId: session.id!)
        XCTAssertEqual(msgs.first?.model, "anthropic-id:claude-sonnet-4-6")
    }

    func testEditResendDropsLaterMessages() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "C")
        try store.appendMessage(ChatMessage(sessionId: session.id!, role: .user, content: "old question"))
        let userId = try store.messages(sessionId: session.id!).first!.id!
        _ = try store.appendAssistantMessage(sessionId: session.id!, content: "old answer", citations: [])

        // User edits their message and resends: rewrite + drop the stale answer.
        try store.updateMessageContent(id: userId, content: "new question")
        try store.deleteMessagesAfter(sessionId: session.id!, messageId: userId)

        let after = try store.messages(sessionId: session.id!)
        XCTAssertEqual(after.map(\.content), ["new question"])
    }

    func testRegenerateReplacesAssistantMessage() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "C")
        try store.appendMessage(ChatMessage(sessionId: session.id!, role: .user, content: "q"))
        let a1 = try store.appendAssistantMessage(sessionId: session.id!, content: "first", citations: [], model: "m1")
        try store.deleteMessage(id: a1)
        _ = try store.appendAssistantMessage(sessionId: session.id!, content: "second", citations: [], model: "m2")
        let msgs = try store.messages(sessionId: session.id!)
        XCTAssertEqual(msgs.map(\.content), ["q", "second"])
        XCTAssertEqual(msgs.last?.model, "m2")
    }
}

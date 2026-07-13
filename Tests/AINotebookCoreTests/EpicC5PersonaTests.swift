import XCTest
import GRDB
@testable import AINotebookCore

/// Tests Epic C5 personas: CRUD, migration v18, and the persona-instruction
/// override in ChatEngine.
@MainActor
final class EpicC5PersonaTests: XCTestCase {

    func testMigrationV18CreatesPersonasTable() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info('personas')").compactMap { $0["name"] as String? }
            XCTAssertEqual(Set(cols), ["id", "notebook_id", "name", "instructions", "source_set_id", "model", "created_at"])
        }
    }

    func testPersonaCrud() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let set = try store.createSourceSet(notebookId: nb.id!, name: "Docs")
        let p = try store.createPersona(notebookId: nb.id!, name: "Lawyer",
                                        instructions: "Be precise.", sourceSetId: set.id, model: "pid:model")
        XCTAssertEqual(try store.personas(notebookId: nb.id!).count, 1)

        var edited = p
        edited.name = "Senior Lawyer"
        edited.model = nil
        try store.updatePersona(edited)
        let reloaded = try store.personas(notebookId: nb.id!).first!
        XCTAssertEqual(reloaded.name, "Senior Lawyer")
        XCTAssertNil(reloaded.model)
        XCTAssertEqual(reloaded.sourceSetId, set.id)

        try store.deletePersona(id: p.id)
        XCTAssertTrue(try store.personas(notebookId: nb.id!).isEmpty)
    }

    func testDeletingSourceSetNullsPersonaReference() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let set = try store.createSourceSet(notebookId: nb.id!, name: "Docs")
        let p = try store.createPersona(notebookId: nb.id!, name: "P", sourceSetId: set.id)
        try store.deleteSourceSet(id: set.id)
        // ON DELETE SET NULL — persona survives, reference cleared.
        let reloaded = try store.personas(notebookId: nb.id!).first
        XCTAssertEqual(reloaded?.id, p.id)
        XCTAssertNil(reloaded?.sourceSetId)
    }

    // MARK: instruction override in ChatEngine

    private final class Emb: EmbeddingProducing, @unchecked Sendable {
        func embed(model: String, inputs: [String]) async throws -> [[Float]] { inputs.map { _ in [1, 0] } }
    }
    private final class Chat: ChatStreaming, @unchecked Sendable {
        var captured: [[ChatTurn]] = []
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            captured.append(messages)
            return AsyncThrowingStream { c in Task { c.yield("ok"); c.finish() } }
        }
    }

    func testPersonaInstructionsOverrideNotebookInstructions() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        try store.updateNotebookInstructions(id: nb.id!, instructions: "Notebook default.")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")
        let chat = Chat()
        let engine = ChatEngine(store: store, retriever: Retriever(store: store, client: Emb(), model: "emb"),
                                chat: chat, chatModel: "m")

        _ = try await engine.send(sessionId: session.id!, notebookId: nb.id!, userText: "q",
                                  instructionsOverride: "Persona says: be terse.") { _ in }

        let system = chat.captured.first?.first { $0.role == .system }?.content ?? ""
        XCTAssertTrue(system.contains("Persona says: be terse."), "persona override should win")
        XCTAssertFalse(system.contains("Notebook default."), "notebook instructions should be replaced")
    }
}

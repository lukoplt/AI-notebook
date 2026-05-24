import XCTest
@testable import AINotebookCore

@MainActor
final class NotebookStoreTransformationsTests: XCTestCase {

    func testCreateAndListTransformations() throws {
        let store = try NotebookStore(path: .inMemory)
        _ = try store.createTransformation(
            name: "CustomA", promptTemplate: "Summarize:\n{{source_text}}", scope: .source, isBuiltin: false
        )
        _ = try store.createTransformation(
            name: "CustomB", promptTemplate: "Do X", scope: .source, isBuiltin: false
        )
        let nonBuiltin = try store.transformations().filter { !$0.isBuiltin }
        XCTAssertEqual(nonBuiltin.count, 2)
    }

    func testUpdateAndDeleteCustomTransformation() throws {
        let store = try NotebookStore(path: .inMemory)
        let t = try store.createTransformation(
            name: "C", promptTemplate: "old", scope: .source, isBuiltin: false
        )
        try store.updateTransformation(id: t.id!, name: "C2", promptTemplate: "new")
        let reloaded = try XCTUnwrap(store.transformations().first { $0.id == t.id })
        XCTAssertEqual(reloaded.name, "C2")
        XCTAssertEqual(reloaded.promptTemplate, "new")
        try store.deleteTransformation(id: t.id!)
        XCTAssertEqual(try store.transformations().filter { !$0.isBuiltin }.count, 0)
    }

    func testRecordRunCreatesRow() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s  = try store.createSource(notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil)
        let t  = try store.createTransformation(name: "T", promptTemplate: "p", scope: .source, isBuiltin: false)
        let n  = try store.createNote(notebookId: nb.id!, title: "T result", bodyMd: "x")
        let run = try store.recordTransformationRun(
            transformationId: t.id!, sourceId: s.id!, resultNoteId: n.id!
        )
        XCTAssertNotNil(run.id)
        let runs = try store.transformationRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].resultNoteId, n.id)
    }
}

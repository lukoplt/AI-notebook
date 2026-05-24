import XCTest
@testable import AINotebookCore

@MainActor
final class NotebookStoreSourcesTests: XCTestCase {
    func testCreateAndFetchSources() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")

        let s1 = try store.createSource(
            notebookId: nb.id!,
            type: .text,
            title: "Alpha",
            uri: nil,
            rawPath: nil
        )
        let s2 = try store.createSource(
            notebookId: nb.id!,
            type: .pdf,
            title: "Beta",
            uri: nil,
            rawPath: "/tmp/beta.pdf"
        )

        let list = try store.sources(notebookId: nb.id!)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(Set(list.map(\.title)), ["Alpha", "Beta"])
        XCTAssertEqual(s1.status, .pending)
        XCTAssertEqual(s2.status, .pending)
    }

    func testUpdateStatusPersists() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "X", uri: nil, rawPath: nil
        )
        try store.updateSourceStatus(id: s.id!, status: .ready, error: nil)
        let reloaded = try XCTUnwrap(store.source(id: s.id!))
        XCTAssertEqual(reloaded.status, .ready)
        XCTAssertNil(reloaded.error)
    }

    func testUpdateStatusErrorPersists() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "X", uri: nil, rawPath: nil
        )
        try store.updateSourceStatus(id: s.id!, status: .error, error: "boom")
        let reloaded = try XCTUnwrap(store.source(id: s.id!))
        XCTAssertEqual(reloaded.status, .error)
        XCTAssertEqual(reloaded.error, "boom")
    }

    func testReplaceChunksClearsPreviousAndInserts() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "X", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [
                ChunkDraft(text: "one",   tokenCount: 1, pageHint: nil),
                ChunkDraft(text: "two",   tokenCount: 1, pageHint: nil),
                ChunkDraft(text: "three", tokenCount: 1, pageHint: nil)
            ]
        )
        let first = try store.chunks(sourceId: s.id!)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first.map(\.ord), [0, 1, 2])
        XCTAssertEqual(first.map(\.text), ["one", "two", "three"])

        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [ChunkDraft(text: "only", tokenCount: 1, pageHint: nil)]
        )
        let second = try store.chunks(sourceId: s.id!)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].text, "only")
    }

    func testDeleteSourceCascadesChunks() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "X", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [ChunkDraft(text: "x", tokenCount: 1, pageHint: nil)]
        )
        try store.deleteSource(id: s.id!)
        XCTAssertNil(try store.source(id: s.id!))
        XCTAssertEqual(try store.chunks(sourceId: s.id!).count, 0)
    }

    func testCreateRejectsEmptyTitle() {
        do {
            let store = try NotebookStore(path: .inMemory)
            let nb = try store.createNotebook(name: "NB")
            _ = try store.createSource(
                notebookId: nb.id!, type: .text, title: "   ", uri: nil, rawPath: nil
            )
            XCTFail("expected throw")
        } catch StoreError.invalidSourceTitle {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testSourcesExcludesNoteShadowRows() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        _ = try store.createSource(
            notebookId: nb.id!, type: .text, title: "Real",
            uri: nil, rawPath: nil
        )
        _ = try store.createSource(
            notebookId: nb.id!, type: .note, title: "Shadow",
            uri: nil, rawPath: nil
        )
        let visible = try store.sources(notebookId: nb.id!)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.title, "Real")

        let all = try store.sourcesIncludingShadow(notebookId: nb.id!)
        XCTAssertEqual(all.count, 2)
    }
}

import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class NotebookStoreTests: XCTestCase {
    private func makeStore() throws -> NotebookStore {
        try NotebookStore(path: .inMemory)
    }

    func testListEmptyByDefault() throws {
        let store = try makeStore()
        XCTAssertEqual(store.notebooks, [])
    }

    func testCreateAppendsToList() throws {
        let store = try makeStore()
        let created = try store.createNotebook(name: "Research", description: "Lit review")

        XCTAssertNotNil(created.id)
        XCTAssertEqual(created.name, "Research")
        XCTAssertEqual(created.description, "Lit review")
        XCTAssertEqual(store.notebooks.count, 1)
        XCTAssertEqual(store.notebooks.first?.id, created.id)
    }

    func testCreateTrimsName() throws {
        let store = try makeStore()
        let n = try store.createNotebook(name: "  Spaces  ")
        XCTAssertEqual(n.name, "Spaces")
    }

    func testCreateRejectsEmptyName() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.createNotebook(name: "   ")) { error in
            XCTAssertEqual(error as? StoreError, .invalidNotebookName("   "))
        }
        XCTAssertEqual(store.notebooks, [])
    }

    func testRenameUpdatesNameAndTimestamp() throws {
        let store = try makeStore()
        let n = try store.createNotebook(name: "Old")
        let originalUpdatedAt = n.updatedAt
        Thread.sleep(forTimeInterval: 0.02)

        let renamed = try store.renameNotebook(id: n.id!, newName: "New")
        XCTAssertEqual(renamed.name, "New")
        XCTAssertGreaterThan(renamed.updatedAt, originalUpdatedAt)
        XCTAssertEqual(store.notebooks.first?.name, "New")
    }

    func testRenameRejectsEmptyName() throws {
        let store = try makeStore()
        let n = try store.createNotebook(name: "Keep")
        XCTAssertThrowsError(try store.renameNotebook(id: n.id!, newName: "")) { error in
            XCTAssertEqual(error as? StoreError, .invalidNotebookName(""))
        }
    }

    func testRenameUnknownIdThrows() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.renameNotebook(id: 999, newName: "x")) { error in
            XCTAssertEqual(error as? StoreError, .notebookNotFound(id: 999))
        }
    }

    func testDeleteRemovesFromList() throws {
        let store = try makeStore()
        let a = try store.createNotebook(name: "A")
        let b = try store.createNotebook(name: "B")
        try store.deleteNotebook(id: a.id!)
        XCTAssertEqual(store.notebooks.map(\.id), [b.id])
    }

    func testDeleteUnknownIdThrows() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.deleteNotebook(id: 7)) { error in
            XCTAssertEqual(error as? StoreError, .notebookNotFound(id: 7))
        }
    }

    func testListSortedByUpdatedAtDescending() throws {
        let store = try makeStore()
        _ = try store.createNotebook(name: "First")
        Thread.sleep(forTimeInterval: 0.02)
        let second = try store.createNotebook(name: "Second")
        Thread.sleep(forTimeInterval: 0.02)
        let third = try store.createNotebook(name: "Third")

        XCTAssertEqual(store.notebooks.map(\.name), ["Third", "Second", "First"])

        _ = try store.renameNotebook(id: second.id!, newName: "Bumped")
        XCTAssertEqual(store.notebooks.map(\.name), ["Bumped", "Third", "First"])
        _ = third
    }

    func testPersistenceAcrossStoreInstances() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ainotebook-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("db.sqlite")
        let path = StorePath(fileURL: file)

        do {
            let store = try NotebookStore(path: path)
            _ = try store.createNotebook(name: "Persisted")
        }
        let reopened = try NotebookStore(path: path)
        XCTAssertEqual(reopened.notebooks.map(\.name), ["Persisted"])
    }
}

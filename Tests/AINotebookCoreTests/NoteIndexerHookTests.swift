import XCTest
@testable import AINotebookCore

@MainActor
final class NoteIndexerHookTests: XCTestCase {

    func testHookFiresOnCreateAndUpdate() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")

        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var ids: [Int64] = []
            func record(_ id: Int64) {
                lock.lock(); defer { lock.unlock() }
                ids.append(id)
            }
            var snapshot: [Int64] {
                lock.lock(); defer { lock.unlock() }
                return ids
            }
        }
        let counter = Counter()
        store.onNoteSaved = { id in counter.record(id) }

        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "x")
        try store.updateNote(id: n.id!, title: "T2", bodyMd: "y")

        try await Task.sleep(nanoseconds: 100_000_000)

        let recorded = counter.snapshot
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded.first, n.id)
        XCTAssertEqual(recorded.last,  n.id)
    }
}

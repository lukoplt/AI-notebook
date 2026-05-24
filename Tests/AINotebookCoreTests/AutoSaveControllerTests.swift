import XCTest
@testable import AINotebookCore

@MainActor
final class AutoSaveControllerTests: XCTestCase {

    final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var saves: [String] = []
        func record(_ s: String) {
            lock.lock(); defer { lock.unlock() }
            saves.append(s)
        }
        var snapshot: [String] {
            lock.lock(); defer { lock.unlock() }
            return saves
        }
    }

    func testDebouncedSaveFiresAfterIdle() async throws {
        let counter = Counter()
        let controller = AutoSaveController(debounceMillis: 50) { body in
            counter.record(body)
        }
        controller.noteDidChange("v1")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(counter.snapshot, ["v1"])
        XCTAssertEqual(controller.status, .saved)
    }

    func testMultipleQuickChangesCollapseToOneSave() async throws {
        let counter = Counter()
        let controller = AutoSaveController(debounceMillis: 50) { body in
            counter.record(body)
        }
        controller.noteDidChange("a")
        controller.noteDidChange("ab")
        controller.noteDidChange("abc")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(counter.snapshot, ["abc"])
    }

    func testManualSaveBypassesDebounce() async throws {
        let counter = Counter()
        let controller = AutoSaveController(debounceMillis: 5_000) { body in
            counter.record(body)
        }
        controller.noteDidChange("draft")
        controller.manualSave()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(counter.snapshot, ["draft"])
    }

    func testStatusTransitions() async throws {
        let counter = Counter()
        let controller = AutoSaveController(debounceMillis: 30) { body in
            counter.record(body)
        }
        XCTAssertEqual(controller.status, .saved)
        controller.noteDidChange("x")
        XCTAssertEqual(controller.status, .unsaved)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.status, .saved)
    }
}

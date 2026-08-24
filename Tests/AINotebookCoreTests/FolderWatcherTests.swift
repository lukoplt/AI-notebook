import XCTest
@testable import AINotebookCore

/// Epic E1 — the FSEvents watcher behind continuous folder sync. These drive
/// real files through the real event stream, so they poll for the expected
/// state instead of sleeping a fixed amount.
final class FolderWatcherTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Polls until `condition` holds or the timeout expires.
    private func eventually(
        timeout: TimeInterval = 15,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// Thread-safe counter — the watcher calls back on its own queue.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testStartAndStopReportWhetherItIsWatching() throws {
        let watcher = FolderWatcher(folder: dir) {}
        XCTAssertFalse(watcher.isWatching)

        try watcher.start()
        XCTAssertTrue(watcher.isWatching)

        watcher.stop()
        XCTAssertFalse(watcher.isWatching)
    }

    func testStartIsIdempotentAndStopIsSafeBeforeStarting() throws {
        let watcher = FolderWatcher(folder: dir) {}

        watcher.stop()                       // never started
        try watcher.start()
        try watcher.start()                  // second start must not leak a stream
        XCTAssertTrue(watcher.isWatching)

        watcher.stop()
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)
    }

    func testANewFileInTheFolderTriggersAChange() throws {
        let counter = Counter()
        let watcher = FolderWatcher(folder: dir) { counter.increment() }
        try watcher.start()
        defer { watcher.stop() }

        try "hello".write(to: dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        XCTAssertTrue(eventually { counter.count >= 1 }, "watcher never reported the new file")
    }

    func testEditingAFileAlreadyInTheFolderTriggersAChange() throws {
        // The reason this is FSEvents and not a directory DispatchSource: the
        // directory listing does not change when a file is edited in place.
        let file = dir.appendingPathComponent("existing.txt")
        try "before".write(to: file, atomically: true, encoding: .utf8)

        let counter = Counter()
        let watcher = FolderWatcher(folder: dir) { counter.increment() }
        try watcher.start()
        defer { watcher.stop() }

        try "after — substantially different".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertTrue(eventually { counter.count >= 1 }, "watcher never reported the edit")
    }

    func testDeletingAFileTriggersAChange() throws {
        let file = dir.appendingPathComponent("doomed.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        let counter = Counter()
        let watcher = FolderWatcher(folder: dir) { counter.increment() }
        try watcher.start()
        defer { watcher.stop() }

        try FileManager.default.removeItem(at: file)

        XCTAssertTrue(eventually { counter.count >= 1 }, "watcher never reported the deletion")
    }

    func testABurstOfWritesIsCoalescedIntoASingleChange() throws {
        let counter = Counter()
        // Long debounce so the whole burst lands inside one window.
        let watcher = FolderWatcher(folder: dir, latency: 0.05, debounce: 1.5) { counter.increment() }
        try watcher.start()
        defer { watcher.stop() }

        for i in 0..<12 {
            try "body \(i)".write(
                to: dir.appendingPathComponent("file\(i).txt"), atomically: true, encoding: .utf8)
        }

        XCTAssertTrue(eventually { counter.count >= 1 }, "watcher never fired")
        // Re-syncing a folder is expensive; twelve files must not mean twelve
        // full syncs.
        XCTAssertLessThanOrEqual(counter.count, 3, "burst was not coalesced")
    }

    func testNoChangesAreReportedAfterStopping() throws {
        let counter = Counter()
        let watcher = FolderWatcher(folder: dir, latency: 0.05, debounce: 0.1) { counter.increment() }
        try watcher.start()
        watcher.stop()

        try "content".write(to: dir.appendingPathComponent("after.txt"), atomically: true, encoding: .utf8)
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        XCTAssertEqual(counter.count, 0, "watcher fired after stop()")
    }

    func testStopCancelsAChangeStillWaitingOutTheDebounce() throws {
        let counter = Counter()
        let watcher = FolderWatcher(folder: dir, latency: 0.05, debounce: 3) { counter.increment() }
        try watcher.start()

        try "content".write(to: dir.appendingPathComponent("pending.txt"), atomically: true, encoding: .utf8)
        // Let the event arrive, but stop well inside the debounce window.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        watcher.stop()

        RunLoop.current.run(until: Date().addingTimeInterval(3.5))
        XCTAssertEqual(counter.count, 0, "a debounced change survived stop()")
    }
}

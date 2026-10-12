import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private func onMainThread() -> Bool { Thread.isMainThread }

private final class PostCounter: @unchecked Sendable {
    private let gate = NSLock()
    private var main = 0, other = 0
    func record(onMain: Bool) { gate.withLock { if onMain { main += 1 } else { other += 1 } } }
    var counts: (main: Int, other: Int) { gate.withLock { (main, other) } }
}

/// File stores run in WAL mode on a `DatabasePool` (contract `chat-during-scan-v1` §2):
/// reads never wait behind a background write, background store work never
/// runs on the main thread, and backup/restore stay complete and consistent.
@MainActor
final class StoreConcurrencyTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("store-wal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fileStore(_ name: String = "db.sqlite") throws -> NotebookStore {
        try NotebookStore(path: StorePath(fileURL: directory.appendingPathComponent(name)), configuredEmbeddingModelKey: nil)
    }

    func testFileStoreUsesWALPoolWithBoundedJournal() throws {
        let store = try fileStore()
        XCTAssertTrue(store.dbQueue is DatabasePool)
        let mode = try store.dbQueue.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        XCTAssertEqual(mode, "wal")
        let limit = try store.dbQueue.write { try Int.fetchOne($0, sql: "PRAGMA journal_size_limit") }
        XCTAssertEqual(limit, NotebookStore.walSizeLimitBytes)
        // In-memory stores stay a serialized queue.
        XCTAssertTrue(try NotebookStore(path: .inMemory).dbQueue is DatabaseQueue)
    }

    func testExistingRollbackJournalDatabaseIsConvertedAndKept() throws {
        let url = directory.appendingPathComponent("legacy.sqlite")
        do {
            let legacy = try DatabaseQueue(path: url.path)
            try legacy.write { db in
                try db.execute(sql: "PRAGMA journal_mode=DELETE")
                try db.execute(sql: "CREATE TABLE marker(value TEXT)")
            }
            try legacy.close()
        }
        // An app database that was last opened by a rollback-journal build.
        do {
            let old = try fileStore("legacy.sqlite")
            _ = try old.createNotebook(name: "Before WAL")
            try old.dbQueue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
            try old.dbQueue.close()
        }
        let reopened = try fileStore("legacy.sqlite")
        XCTAssertEqual(reopened.notebooks.map(\.name), ["Before WAL"])
        XCTAssertEqual(try reopened.dbQueue.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }, "wal")
    }

    func testReadDoesNotWaitBehindALongBackgroundWrite() throws {
        let store = try fileStore()
        let notebook = try store.createNotebook(name: "Readable")
        let writer = store.dbQueue
        let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? writer.write { db in
                try db.execute(sql: "UPDATE notebooks SET description='busy'")
                started.signal()
                Thread.sleep(forTimeInterval: 0.8)
            }
            finished.signal()
        }
        started.wait()
        let begin = DispatchTime.now().uptimeNanoseconds
        let name = try store.dbQueue.read { try String.fetchOne($0, sql: "SELECT name FROM notebooks WHERE id=?", arguments: [notebook.id]) }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e6
        finished.wait()
        XCTAssertEqual(name, "Readable")
        XCTAssertLessThan(elapsedMs, 400, "a snapshot read must not wait for the 800 ms write transaction")
        // The committed write is visible to the next read.
        XCTAssertEqual(try store.dbQueue.read { try String.fetchOne($0, sql: "SELECT description FROM notebooks") }, "busy")
    }

    func testBackgroundStoreWorkRunsOffTheMainThreadAndNotifiesOnMain() async throws {
        let store = try fileStore()
        let notebookId = try XCTUnwrap(store.createNotebook(name: "Off main").id)
        let posts = PostCounter()
        let observer = NotificationCenter.default.addObserver(forName: .indexingStatusDidChange, object: store, queue: nil) { _ in
            posts.record(onMain: Thread.isMainThread)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let ranOnMain = await Task.detached { () -> Bool in
            store.notifyFolderIngestionChanged(notebookId: notebookId)
            _ = try? store.indexingInputs(notebookId: notebookId, now: 1)
            return onMainThread()
        }.value
        XCTAssertFalse(ranOnMain)
        // The notification hop is enqueued on the main actor.
        for _ in 0..<50 where posts.counts.main == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(posts.counts.main, 1)
        XCTAssertEqual(posts.counts.other, 0)
    }

    func testBackupCapturesWALContentAndRestoreReplacesIt() throws {
        let store = try fileStore()
        _ = try store.createNotebook(name: "Original")
        // Nothing checkpointed yet: the committed row lives only in the -wal file.
        let backup = directory.appendingPathComponent("backup.sqlite")
        try store.backupDatabase(to: backup)
        let copy = try DatabaseQueue(path: backup.path)
        XCTAssertEqual(try copy.read { try String.fetchAll($0, sql: "SELECT name FROM notebooks") }, ["Original"])
        try copy.close()

        _ = try store.createNotebook(name: "AddedLater")
        try store.restoreDatabase(from: backup)
        XCTAssertEqual(store.notebooks.map(\.name), ["Original"])
        // Pool readers see the restored content, and the store stays writable.
        XCTAssertEqual(try store.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM notebooks") }, 1)
        _ = try store.createNotebook(name: "AfterRestore")
        XCTAssertEqual(Set(store.notebooks.map(\.name)), ["Original", "AfterRestore"])
        XCTAssertEqual(try store.dbQueue.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }, "wal")
    }

    func testWALIsTruncatedAfterCheckpoint() throws {
        let store = try fileStore()
        let notebookId = try XCTUnwrap(store.createNotebook(name: "Big").id)
        let blob = String(repeating: "x", count: 1_000_000)
        for index in 0..<100 {
            try store.dbQueue.write { db in
                try db.execute(sql: "UPDATE notebooks SET description=? WHERE id=?", arguments: [blob + "\(index)", notebookId])
            }
        }
        try store.dbQueue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(PASSIVE)") }
        // One more commit after a completed checkpoint resets the log and applies journal_size_limit.
        try store.dbQueue.write { try $0.execute(sql: "UPDATE notebooks SET description='small' WHERE id=?", arguments: [notebookId]) }
        let wal = directory.appendingPathComponent("db.sqlite-wal").path
        let size = (try FileManager.default.attributesOfItem(atPath: wal)[.size] as? Int) ?? 0
        XCTAssertLessThanOrEqual(size, NotebookStore.walSizeLimitBytes)
    }
}

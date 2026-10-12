import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private struct UpgradeIdentity: FolderPathIdentity {
    func resolve(rootPath: String) throws -> FolderIdentity {
        FolderIdentity(volumeId: "test", components: ["docs"], rootFileId: "root-1")
    }
}

/// A flat folder whose files never change between scans.
private struct StaticFolderFS: FolderFileSystem {
    let entries: [FolderEntry]
    func resolve(rootPath: String) throws -> FolderIdentity { try UpgradeIdentity().resolve(rootPath: rootPath) }
    func caseSensitive(root: FolderSource) throws -> Bool { true }
    func list(root: FolderSource, directory: String) throws -> [FolderEntry] { directory.isEmpty ? entries : [] }
    func stat(root: FolderSource, relativePath: String) throws -> FileStamp {
        if relativePath.isEmpty { return FileStamp(identity: "root-1", mtimeNs: 0, sizeBytes: 0) }
        return try XCTUnwrap(entries.first { $0.relPath == relativePath }).stamp
    }
    func hash(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderRead {
        let entry = try XCTUnwrap(entries.first { $0.relPath == relativePath })
        return FolderRead(bytes: Data(), stamp: entry.stamp, sha256: "hash-" + relativePath)
    }
    func snapshot(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderFileSnapshot {
        throw IngestionError(code: "unexpectedError")
    }
}

private struct Clock: IngestLeaseClock {
    let value: Int64
    func now() -> Int64 { value }
    func wait(until: Int64) async throws { throw CancellationError() }
}

/// `ingestion-formats-v1` §3–4: new default include list and the one-time
/// upgrade of folders still on the old default (same cases as Windows).
@MainActor
final class FolderDefaultsUpgradeTests: XCTestCase {
    private func fixture() throws -> [String: Any] { try SharedFixtures.json("contracts/ingestion-formats-v1.json") }

    private func json(_ list: [String]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: list), as: UTF8.self)
    }

    private func insertFolder(_ db: Database, includeExts: String, limits: String = "{}") throws {
        try db.execute(sql: """
            INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,created_at)
            VALUES(1,1,'/docs','{"volumeId":"test","components":["docs"],"rootFileId":"root-1"}','Docs',?,'[]',?,?)
            """, arguments: [includeExts, limits, Date(timeIntervalSince1970: 0)])
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier=?", arguments: [FolderDefaultsUpgrade.marker])
    }

    private func includeExts(_ db: Database) throws -> [String] {
        let raw = try String.fetchOne(db, sql: "SELECT include_exts FROM folder_sources WHERE id=1")!
        return try JSONDecoder().decode([String].self, from: Data(raw.utf8))
    }

    private func scanJobs(_ db: Database) throws -> [Row] {
        try Row.fetchAll(db, sql: "SELECT state,options_json,next_retry_at FROM ingest_jobs WHERE kind='scan' AND target='folder:1'")
    }

    func testDefaultsMatchContract() throws {
        let contract = try fixture()
        XCTAssertEqual(FolderRules.defaults.includeExts, contract["defaultIncludeExts"] as? [String])
        XCTAssertEqual(FolderDefaultsUpgrade.oldDefault, contract["oldDefaultIncludeExts"] as? [String])
        XCTAssertEqual(FolderDefaultsUpgrade.marker, contract["upgradeMarker"] as? String)
        // Every default extension is an includable, detectable format.
        let rules = try FolderRules.defaults.validated(caseSensitive: true, tables: UnicodeTables.bundled())
        XCTAssertEqual(rules.includeExts, FolderRules.defaults.includeExts)
        for ext in rules.includeExts { XCTAssertNotNil(SourceType.detect(filename: "a." + ext), ext) }
    }

    func testUpgradeCases() throws {
        let rows = try XCTUnwrap(fixture()["cases"] as? [[String: Any]]).filter { $0["operation"] as? String == "upgrade" }
        XCTAssertEqual(rows.count, 6)
        for row in rows {
            let name = row["name"] as! String
            let stored = (row["input"] as! [String: Any])["includeExts"] as! [String]
            let expected = (row["expected"] as! [String: Any])["includeExts"] as! [String]
            let store = try NotebookStore(path: .inMemory)
            XCTAssertEqual(try store.createNotebook(name: "n").id, 1)
            try store.runOnDatabase { db in
                try insertFolder(db, includeExts: json(stored))
                let notebooks = try FolderDefaultsUpgrade.apply(db, now: 5)
                XCTAssertEqual(try includeExts(db), expected, name)
                let upgraded = expected != stored
                XCTAssertEqual(notebooks, upgraded ? [1] : [], name)
                XCTAssertEqual(try scanJobs(db).count, upgraded ? 1 : 0, name)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations WHERE identifier=?",
                                                arguments: [FolderDefaultsUpgrade.marker]), 1, name)
            }
        }
    }

    func testUpgradeRunsOnceAndReclassifiesInventory() throws {
        let store = try NotebookStore(path: .inMemory)
        XCTAssertEqual(try store.createNotebook(name: "n").id, 1)
        try store.runOnDatabase { db in
            try insertFolder(db, includeExts: json(FolderDefaultsUpgrade.oldDefault), limits: #"{"maxFileBytes":100}"#)
            for (path, kind, reason, size) in [("a.msg", "skipped", "unsupported_ext", 10), ("b.EML", "skipped", "unsupported_ext", 101),
                                               ("c.xls", "skipped", "unsupported_ext", 10), ("d.md", "eligible", nil, 10),
                                               (".cache/e.msg", "skipped", "ignored", 10), ("f.xlsm", "skipped", "unsupported_ext", 100)] {
                try db.execute(sql: """
                    INSERT INTO scan_items(folder_id,rel_path,kind,skip_reason,mtime,size_bytes,seen_generation) VALUES(1,?,?,?,1,?,0)
                    """, arguments: [path, kind, reason, size])
            }
            try FolderDefaultsUpgrade.apply(db, now: 5)
            let items = try Row.fetchAll(db, sql: "SELECT rel_path,kind,skip_reason FROM scan_items ORDER BY rel_path").map {
                "\($0["rel_path"] as String)|\($0["kind"] as String)|\(($0["skip_reason"] as String?) ?? "-")"
            }
            XCTAssertEqual(items, [".cache/e.msg|skipped|ignored", "a.msg|eligible|-", "b.EML|skipped|over_limit",
                                   "c.xls|skipped|unsupported_ext", "d.md|eligible|-", "f.xlsm|eligible|-"])
            let jobs = try scanJobs(db)
            XCTAssertEqual(jobs.count, 1)
            XCTAssertEqual(jobs[0]["state"] as String, "queued")
            XCTAssertEqual(jobs[0]["options_json"] as String, #"{"verifyAll":false}"#)
            XCTAssertNil(jobs[0]["next_retry_at"] as Int64?)

            // Once per database: a user who restores the old list keeps it.
            try db.execute(sql: "UPDATE folder_sources SET include_exts=? WHERE id=1", arguments: [json(FolderDefaultsUpgrade.oldDefault)])
            XCTAssertEqual(try FolderDefaultsUpgrade.apply(db, now: 6), [])
            XCTAssertEqual(try includeExts(db), FolderDefaultsUpgrade.oldDefault)
            XCTAssertEqual(try scanJobs(db).count, 1)
        }
    }

    /// End to end: a database from the previous release (old default, mail and
    /// macro files skipped as unsupported) is upgraded on open, and the next scan
    /// turns those unchanged files into sources of the right kind.
    func testStoreOpenUpgradesAndNextScanPicksUpSkippedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = StorePath(fileURL: directory.appendingPathComponent("store.sqlite"))
        let stamp = { (name: String) in FileStamp(identity: name, mtimeNs: 7, sizeBytes: 9) }
        let fs = StaticFolderFS(entries: ["a.md", "b.msg", "c.xlsm", "d.eml", "e.xls"].map {
            FolderEntry(relPath: $0, isDirectory: false, isLink: false, stamp: stamp($0))
        })
        let tables = try UnicodeTables.bundled()
        do {
            let store = try NotebookStore(path: path)
            let notebook = try store.createNotebook(name: "mail")
            let folder = try store.createFolder(notebookId: notebook.id!, draft: FolderDraft(rootPath: "/docs", displayName: "Docs",
                includeExts: FolderDefaultsUpgrade.oldDefault, ignoreGlobs: [], limitsJSON: "{}", encodingFallback: "cp1250",
                watchEnabled: false), identity: UpgradeIdentity(), now: 0)
            let id = try store.enqueueJob(IngestJobDraft(kind: "scan", target: "folder:\(folder.id)", targetRevision: nil), now: 1)
            _ = try store.claimJob(now: 1, leaseToken: "old-scan", id: id)
            try await FolderScanner(store: store, fileSystem: fs, tables: tables, clock: Clock(value: 2))
                .scan(folderId: folder.id, verifyAll: false, fence: JobFence(jobId: id, leaseToken: "old-scan"), now: 1, cancelled: { false })
            try store.runOnDatabase { db in
                XCTAssertEqual(try String.fetchAll(db, sql: "SELECT rel_path FROM sources ORDER BY rel_path"), ["a.md"])
                XCTAssertEqual(try String.fetchAll(db, sql: "SELECT rel_path FROM scan_items WHERE skip_reason='unsupported_ext' ORDER BY rel_path"),
                               ["b.msg", "c.xlsm", "d.eml", "e.xls"])
                // A database written by the previous release has no marker.
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier=?", arguments: [FolderDefaultsUpgrade.marker])
                try db.execute(sql: "DELETE FROM ingest_jobs WHERE kind='extract'")
            }
        }
        let store = try NotebookStore(path: path)
        let folder = try store.folderSource(id: 1)
        XCTAssertEqual(folder.draft.includeExts, FolderRules.defaults.includeExts)
        let queued = try store.runOnDatabase { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM ingest_jobs WHERE kind='scan' AND state='queued' ORDER BY id")
        }
        XCTAssertEqual(queued.count, 1)
        _ = try store.claimJob(now: 10, leaseToken: "new-scan", id: queued[0])
        try await FolderScanner(store: store, fileSystem: fs, tables: tables, clock: Clock(value: 11))
            .scan(folderId: 1, verifyAll: false, fence: JobFence(jobId: queued[0], leaseToken: "new-scan"), now: 10, cancelled: { false })
        try store.runOnDatabase { db in
            let sources = try Row.fetchAll(db, sql: "SELECT rel_path,type FROM sources ORDER BY rel_path").map {
                "\($0["rel_path"] as String)|\($0["type"] as String)"
            }
            XCTAssertEqual(sources, ["a.md|markdown", "b.msg|email", "c.xlsm|xlsx", "d.eml|email"])
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT rel_path FROM scan_items WHERE kind='skipped' ORDER BY rel_path"), ["e.xls"])
            XCTAssertEqual(try String.fetchAll(db, sql: """
                SELECT s.rel_path FROM ingest_jobs j JOIN sources s ON j.target='source:' || s.id
                WHERE j.kind='extract' AND j.state='queued' AND s.rel_path<>'a.md' ORDER BY s.rel_path
                """), ["b.msg", "c.xlsm", "d.eml"])
        }
    }
}

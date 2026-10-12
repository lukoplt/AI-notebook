import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private struct FixedFolderIdentity: FolderPathIdentity {
    func resolve(rootPath: String) throws -> FolderIdentity {
        FolderIdentity(volumeId: "chat-scan", components: ["chat-scan"], rootFileId: "root")
    }
}

/// Never called: no generation exists, so retrieval is lexical only.
private struct UnusedEmbedder: EmbeddingProducing {
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        XCTFail("no query embedding without a generation")
        return []
    }
}

/// Contract `chat-during-scan-v1`: a chat turn while a folder check (and the
/// extraction it queues) runs answers from the last published state, and never
/// fails because the check changes the catalog underneath it.
@MainActor
final class ChatDuringScanTests: XCTestCase {
    private var directory: URL?

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private struct Fixture {
        let store: NotebookStore
        let notebookId: Int64
        let sessionId: Int64
        let folderId: Int64
        let engine: ChatEngine
    }

    private func makeFixture(fileBacked: Bool = false) throws -> Fixture {
        let path: StorePath
        if fileBacked {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-scan-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            directory = dir
            path = StorePath(fileURL: dir.appendingPathComponent("db.sqlite"))
        } else {
            path = .inMemory
        }
        let store = try NotebookStore(path: path, configuredEmbeddingModelKey: nil)
        let notebookId = try XCTUnwrap(store.createNotebook(name: "Folder chat").id)
        let sessionId = try XCTUnwrap(store.createChatSession(notebookId: notebookId, title: "chat").id)
        let folder = try store.createFolder(notebookId: notebookId, draft: FolderDraft(rootPath: "/chat-scan", displayName: "Docs",
            includeExts: FolderRules.defaults.includeExts, ignoreGlobs: FolderRules.defaults.ignoreGlobs, limitsJSON: "{}",
            encodingFallback: "cp1250", watchEnabled: false), identity: FixedFolderIdentity(), now: 1)
        let transport = ReleaseTransport(model: PackModel(providerId: "test", model: "chat", runtimeContext: 16_384,
            maxOutputTokens: 1_024, contextWindowKnown: true, providerType: "ollama"), answer: "Answer [1].")
        let retriever = Retriever(store: store, client: UnusedEmbedder(), modelKey: { "none:none" }, cache: VectorMatrixCache())
        let engine = ChatEngine(store: store,
            coordinator: ContextPackCoordinator(data: CompatibilityPackDataSource(store: store, retriever: retriever),
                                                transports: ReleaseTransportFactory(transport: transport)),
            previews: ContextPreviewSession(), chatModel: "chat")
        return Fixture(store: store, notebookId: notebookId, sessionId: sessionId, folderId: folder.id, engine: engine)
    }

    nonisolated private static func stamp(_ path: String, mtime: Int64) -> FileStamp {
        FileStamp(identity: "id:" + path, mtimeNs: mtime, sizeBytes: 100)
    }

    nonisolated static func observation(_ path: String, mtime: Int64, hash: String?) -> FolderScanObservation {
        .file(FolderObservation(relPath: path, stamp: stamp(path, mtime: mtime), kind: "eligible", skipReason: nil, contentHash: hash))
    }

    /// Starts a scan generation owned by a fresh scan job.
    private func beginScan(_ f: Fixture, token: String) throws -> ScanTicket {
        let job = try f.store.requestFolderScan(folderId: f.folderId, verifyAll: false, now: 2)
        _ = try XCTUnwrap(f.store.claimJob(now: 2, leaseToken: token, id: job))
        return try XCTUnwrap(f.store.beginFolderScan(folderId: f.folderId, fence: JobFence(jobId: job, leaseToken: token), now: 2))
    }

    /// Publishes revision text (one chunk per paragraph) for a folder source, as extraction would.
    @discardableResult
    private func publish(_ store: NotebookStore, folderId: Int64, path: String, revision: Int, paragraphs: [String]) throws -> Int64 {
        try store.runOnDatabase { db in
            let sourceId = try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT id FROM sources WHERE folder_id=? AND rel_path=?",
                                                        arguments: [folderId, path]))
            try db.execute(sql: """
                INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                VALUES (?,?,?,?,1,2,'2026-10-11 00:00:00.000')
                """, arguments: [sourceId, revision, "h-\(path)-\(revision)", paragraphs.joined()])
            let revisionId = db.lastInsertedRowID
            var offset = 0
            for (ord, text) in paragraphs.enumerated() {
                let length = text.unicodeScalars.count
                try db.execute(sql: """
                    INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id,char_start,char_end,lang)
                    VALUES (?,?,?,?,?,?,?,'en')
                    """, arguments: [sourceId, ord, text, max(1, length / 4), revisionId, offset, offset + length])
                offset += length
            }
            try db.execute(sql: """
                UPDATE sources SET current_revision=?,published_revision_id=?,status='ready',content_hash=?,error=NULL WHERE id=?
                """, arguments: [revisionId, revisionId, "h-\(path)-\(revision)", sourceId])
            try db.execute(sql: "UPDATE ingest_jobs SET state='done',lease_token=NULL,lease_until=NULL WHERE target=?",
                           arguments: ["source:\(sourceId)"])
            return revisionId
        }
    }

    /// Two indexed files, both mentioning "contract".
    private func seedIndexedFolder(_ f: Fixture) throws -> (alpha: Int64, beta: Int64) {
        let ticket = try beginScan(f, token: "seed")
        _ = try f.store.observeFolderFiles(ticket: ticket, observations: [
            Self.observation("alpha.txt", mtime: 10, hash: "h-alpha.txt-1"),
            Self.observation("beta.txt", mtime: 10, hash: "h-beta.txt-1"),
        ], now: 2)
        XCTAssertTrue(try f.store.finishFolderScan(ticket: ticket,
            completion: ScanCompletion(completed: [""], incomplete: [], rootUnavailable: false, error: nil), now: 3))
        let alpha = try publish(f.store, folderId: f.folderId, path: "alpha.txt", revision: 1,
                                paragraphs: ["Alpha contract signed in March. ", "Alpha payment terms are net thirty."])
        let beta = try publish(f.store, folderId: f.folderId, path: "beta.txt", revision: 1,
                               paragraphs: ["Beta contract draft from April. ", "Beta delivery schedule."])
        return (alpha, beta)
    }

    private func prepareTurn(_ f: Fixture, question: String = "contract") async throws -> PreparedPackHandle {
        let intent = try await f.engine.captureIntent(sessionId: f.sessionId, notebookId: f.notebookId, question: question, scope: .all)
        return try await f.engine.prepare(intent)
    }

    func testChatTurnDuringScanAnswersFromThePreviousPublishedState() async throws {
        let f = try makeFixture()
        let published = try seedIndexedFolder(f)
        let before = try await prepareTurn(f)
        let indexed = try f.store.runOnDatabase {
            try Int64.fetchAll($0, sql: "SELECT id FROM sources WHERE rel_path IN ('alpha.txt','beta.txt') ORDER BY id")
        }
        XCTAssertEqual(before.request.sourceRevisions.map(\.revisionId), [published.alpha, published.beta])

        // The periodic check is half way: beta changed on disk (refresh queued), a new file
        // gamma appeared (not extracted yet), alpha was not reached yet in this generation.
        let ticket = try beginScan(f, token: "check")
        _ = try f.store.observeFolderFiles(ticket: ticket, observations: [
            Self.observation("beta.txt", mtime: 20, hash: "h-beta.txt-2"),
            Self.observation("gamma.txt", mtime: 20, hash: "h-gamma.txt-1"),
        ], now: 4)
        XCTAssertEqual(try f.store.folderSource(id: f.folderId).scanState, "scanning")

        let during = try await prepareTurn(f)
        // Exactly the previously published revisions: the changed file keeps its old revision,
        // the unseen file is not missing yet, the new file contributes no evidence.
        XCTAssertEqual(during.request.sourceRevisions, before.request.sourceRevisions)
        XCTAssertEqual(Set(during.request.citationMap.map(\.sourceId)), Set(indexed))
        XCTAssertEqual(Set(during.request.citationMap.compactMap(\.revisionId)), [published.alpha, published.beta])
        let corpus = during.request.coverage.corpus
        XCTAssertEqual(corpus.searchable, 2)
        XCTAssertEqual(corpus.pending, 1, "the new file is reported as pending, not as evidence")
        XCTAssertEqual(corpus.searchable + corpus.pending + corpus.error, corpus.filesInScope)
        // And it sends: the check's catalog changes did not make the turn stale.
        let fresh = try await f.engine.captureIntent(sessionId: f.sessionId, notebookId: f.notebookId, question: "contract", scope: .all)
        let reply = try await f.engine.sendPrepared(during, expectedKey: PackIntentKey.make(fresh), onToken: { _ in })
        XCTAssertFalse(reply.citations.isEmpty)
        XCTAssertTrue(reply.citations.allSatisfy { $0.revisionId.map { [published.alpha, published.beta].contains($0) } ?? false })

        // Only the finished check marks alpha missing; the next turn no longer cites it.
        XCTAssertTrue(try f.store.finishFolderScan(ticket: ticket,
            completion: ScanCompletion(completed: [""], incomplete: [], rootUnavailable: false, error: nil), now: 5))
        let after = try await prepareTurn(f)
        XCTAssertEqual(after.request.sourceRevisions.map(\.revisionId), [published.beta])
    }

    func testScopeFingerprintIgnoresFilesWithoutEvidence() throws {
        let f = try makeFixture()
        _ = try seedIndexedFolder(f)
        let fingerprint = { try f.store.contextScopeFingerprint(notebookId: f.notebookId, scope: .all) }
        let start = try fingerprint()
        let ticket = try beginScan(f, token: "check")
        _ = try f.store.observeFolderFiles(ticket: ticket, observations: [
            Self.observation("gamma.txt", mtime: 20, hash: "h-gamma.txt-1"),
            Self.observation("beta.txt", mtime: 20, hash: "h-beta.txt-2"),
        ], now: 4)
        XCTAssertEqual(try fingerprint(), start, "a discovered or changed file does not change the evidence")
        try publish(f.store, folderId: f.folderId, path: "gamma.txt", revision: 1, paragraphs: ["Gamma contract. "])
        XCTAssertEqual(try fingerprint(), start, "a first publication only adds evidence")
        // Revocations do change it: the finished check marks the unseen alpha missing.
        XCTAssertTrue(try f.store.finishFolderScan(ticket: ticket,
            completion: ScanCompletion(completed: [""], incomplete: [], rootUnavailable: false, error: nil), now: 5))
        let missing = try fingerprint()
        XCTAssertNotEqual(missing, start, "a source that became missing revokes evidence")
        try f.store.runOnDatabase { try $0.execute(sql: "UPDATE sources SET eligible=0 WHERE rel_path='beta.txt'") }
        XCTAssertNotEqual(try fingerprint(), missing, "an ineligible source revokes evidence")
    }

    func testSendRepreparesWhenEvidenceChangesBetweenCaptureAndSend() async throws {
        let f = try makeFixture()
        _ = try seedIndexedFolder(f)
        let intent = try await f.engine.captureIntent(sessionId: f.sessionId, notebookId: f.notebookId, question: "contract", scope: .all)
        let handle = try await f.engine.prepare(intent)
        // New evidence published after preparation does not make the request stale…
        let ticket = try beginScan(f, token: "check")
        _ = try f.store.observeFolderFiles(ticket: ticket, observations: [Self.observation("gamma.txt", mtime: 20, hash: "h-gamma.txt-1")], now: 4)
        try publish(f.store, folderId: f.folderId, path: "gamma.txt", revision: 1, paragraphs: ["Gamma contract. "])
        let fresh = try await f.engine.captureIntent(sessionId: f.sessionId, notebookId: f.notebookId, question: "contract", scope: .all)
        XCTAssertEqual(PackIntentKey.make(fresh), handle.key)
        // …but a cited file that became ineligible (a rule change) does.
        try f.store.runOnDatabase { try $0.execute(sql: "UPDATE sources SET eligible=0 WHERE rel_path='alpha.txt'") }
        do {
            _ = try await f.engine.sendPrepared(handle, expectedKey: handle.key, onToken: { _ in })
            XCTFail("expected stalePreparedRequest")
        } catch ChatEngineError.stalePreparedRequest {}
        XCTAssertTrue(try f.store.messages(sessionId: f.sessionId).isEmpty, "nothing written for a stale turn")
        // …and the one-call send prepares again from the new snapshot instead of failing.
        let reply = try await f.engine.send(sessionId: f.sessionId, notebookId: f.notebookId, userText: "contract",
                                            scope: .all, onToken: { _ in })
        XCTAssertEqual(reply.role, .assistant)
        XCTAssertEqual(try f.store.messages(sessionId: f.sessionId).count, 2)
    }

    // MARK: Shared fixture (chat-during-scan-v1)

    /// The scope fingerprint of notebook 1 (scope `.all`) seeded with one fixture state.
    private func fixtureFingerprint(_ state: [String: Any]) throws -> String {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebookId = try XCTUnwrap(store.createNotebook(name: "fixture").id)
        try store.runOnDatabase { db in
            for folder in state["folders"] as! [Int] {
                try db.execute(sql: """
                    INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,
                        ignore_globs,limits,encoding_fallback,watch_enabled,created_at)
                    VALUES(?,?,?,?,?,'[]','[]','{}','cp1250',0,'2026-10-11 00:00:00.000')
                    """, arguments: [folder, notebookId, "/f\(folder)",
                                      "{\"volumeId\":\"v\",\"components\":[\"f\(folder)\"],\"rootFileId\":\"r\(folder)\"}", "F\(folder)"])
            }
            for row in state["sources"] as! [[String: Any]] {
                let id = row["id"] as! Int
                try db.execute(sql: """
                    INSERT INTO sources(id,notebook_id,type,title,status,ingested_at,folder_id,rel_path,availability,eligible)
                    VALUES(?,?,'text',?,'ready','2026-10-11 00:00:00.000',?,?,?,?)
                    """, arguments: [id, notebookId, "s\(id)", row["folderId"] as! Int, "s\(id).txt",
                                      row["availability"] as! String, row["eligible"] as! Bool])
                if row["published"] as! Bool {
                    try db.execute(sql: """
                        INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                        VALUES (?,1,'h','t',1,2,'2026-10-11 00:00:00.000')
                        """, arguments: [id])
                    try db.execute(sql: "UPDATE sources SET published_revision_id=?,current_revision=? WHERE id=?",
                                   arguments: [db.lastInsertedRowID, db.lastInsertedRowID, id])
                }
            }
        }
        return try store.contextScopeFingerprint(notebookId: notebookId, scope: .all)
    }

    func testSharedFixture() throws {
        let fixture = try SharedFixtures.json("contracts/chat-during-scan-v1.json")
        XCTAssertEqual(fixture["contract"] as? String, "chat-during-scan")
        XCTAssertEqual(fixture["staleRepreparations"] as? Int, ChatSessionState.staleRepreparations)
        var counts: [String: Int] = [:]
        for row in fixture["cases"] as! [[String: Any]] {
            let name = row["name"] as! String, operation = row["operation"] as! String
            let input = row["input"] as! [String: Any], expected = row["expected"] as! [String: Any]
            counts[operation, default: 0] += 1
            switch operation {
            case "coverage":
                let s = input["snapshot"] as! [String: Any]
                let c = PackCorpusCoverage.normalized(CoverageSnapshot(
                    searchable: s["searchable"] as! Int, pending: s["pending"] as! Int, error: s["error"] as! Int,
                    skipped: s["skipped"] as! Int, missing: s["missing"] as! Int, unavailable: s["unavailable"] as! Int,
                    refreshPending: s["refreshPending"] as! Int, refreshError: s["refreshError"] as! Int,
                    isLowerBound: s["isLowerBound"] as! Bool), pinnedFiles: input["pinnedFiles"] as! Int)
                let actual: [String: Any] = ["filesInScope": c.filesInScope, "searchable": c.searchable, "pending": c.pending,
                    "error": c.error, "skipped": c.skipped, "missing": c.missing, "unavailable": c.unavailable,
                    "refreshPending": c.refreshPending, "refreshError": c.refreshError, "partial": c.partial]
                XCTAssertEqual(actual as NSDictionary, expected as NSDictionary, name)
            case "scope-stale":
                let stale = try fixtureFingerprint(input["before"] as! [String: Any])
                    != fixtureFingerprint(input["after"] as! [String: Any])
                XCTAssertEqual(stale, expected["stale"] as? Bool, name)
            default:
                XCTFail("unknown operation \(operation)")
            }
        }
        XCTAssertEqual(counts, ["coverage": 7, "scope-stale": 11])
    }

    func testCoverageNormalizationKeepsBuilderInvariantsForAnySnapshot() throws {
        let snapshots = [
            CoverageSnapshot(searchable: 0, pending: 0, error: 0, skipped: 0, missing: 0, unavailable: 0,
                             refreshPending: 0, refreshError: 0, isLowerBound: false),
            CoverageSnapshot(searchable: 2, pending: 1, error: 0, skipped: 0, missing: 1, unavailable: 0,
                             refreshPending: 9, refreshError: 7, isLowerBound: true),
            CoverageSnapshot(searchable: -1, pending: -2, error: 1, skipped: -3, missing: 0, unavailable: 0,
                             refreshPending: -1, refreshError: 4, isLowerBound: false),
        ]
        for snapshot in snapshots {
            for pinned in [0, 1, 5] {
                let c = PackCorpusCoverage.normalized(snapshot, pinnedFiles: pinned)
                XCTAssertEqual(c.searchable + c.pending + c.error, c.filesInScope)
                XCTAssertLessThanOrEqual(c.refreshPending + c.refreshError, c.filesInScope)
                XCTAssertGreaterThanOrEqual(c.filesInScope, pinned)
                for n in [c.searchable, c.pending, c.error, c.skipped, c.missing, c.unavailable, c.refreshPending, c.refreshError] {
                    XCTAssertGreaterThanOrEqual(n, 0)
                }
            }
        }
    }

    /// File-backed (WAL pool): scan batches, first publications and missing-marking run on a
    /// background task while turns are sent; every turn completes, none fails with a
    /// ContextPackError or a stale request.
    func testNoChatFailureWhileAFolderCheckRunsConcurrently() async throws {
        let f = try makeFixture(fileBacked: true)
        _ = try seedIndexedFolder(f)
        let store = f.store, folderId = f.folderId
        let ticket = try beginScan(f, token: "check")
        let background = Task.detached { () throws -> Int in
            var published = 0
            for batch in 0..<40 {
                try Task.checkCancellation()
                let paths = (0..<8).map { "batch-\(batch)/file-\($0).txt" }
                _ = try store.observeFolderFiles(ticket: ticket, observations: paths.map {
                    ChatDuringScanTests.observation($0, mtime: 30, hash: "h-\($0)-1")
                }, now: 6)
                if batch % 2 == 0 {
                    // Extraction finishing behind the check: first publications add evidence.
                    _ = try store.runOnDatabase { db -> Int64 in
                        let sourceId = try Int64.fetchOne(db, sql: "SELECT id FROM sources WHERE folder_id=? AND rel_path=?",
                                                          arguments: [folderId, paths[0]])!
                        let text = "Batch \(batch) contract appendix. "
                        try db.execute(sql: """
                            INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                            VALUES (?,1,?,?,1,2,'2026-10-11 00:00:00.000')
                            """, arguments: [sourceId, "h-\(paths[0])-1", text])
                        let revisionId = db.lastInsertedRowID
                        try db.execute(sql: """
                            INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id,char_start,char_end,lang)
                            VALUES (?,0,?,8,?,0,?,'en')
                            """, arguments: [sourceId, text, revisionId, text.unicodeScalars.count])
                        try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=?,status='ready' WHERE id=?",
                                       arguments: [revisionId, revisionId, sourceId])
                        return revisionId
                    }
                    published += 1
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            _ = try store.finishFolderScan(ticket: ticket,
                completion: ScanCompletion(completed: [""], incomplete: [], rootUnavailable: false, error: nil), now: 7)
            return published
        }
        var failures: [String] = []
        for turn in 0..<12 {
            do {
                _ = try await f.engine.send(sessionId: f.sessionId, notebookId: f.notebookId,
                                            userText: "contract question \(turn)", scope: .all, onToken: { _ in })
            } catch {
                failures.append(String(describing: error))
            }
        }
        let published = try await background.value
        XCTAssertGreaterThan(published, 0)
        XCTAssertEqual(failures, [], "no turn fails while the check runs")
        XCTAssertEqual(try f.store.messages(sessionId: f.sessionId).count, 24)
    }
}

import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private final class Shared<Value>: @unchecked Sendable {
    private let gate = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { gate.lock(); defer { gate.unlock() }; return stored }
        set { gate.lock(); stored = newValue; gate.unlock() }
    }
}

private final class StepClock: IngestLeaseClock, @unchecked Sendable {
    let current = Shared<Int64>(1_000)
    func now() -> Int64 { current.value }
    func wait(until: Int64) async throws { throw CancellationError() }
}

private struct SilentWatches: FolderWatchFactory {
    struct Handle: FolderWatchHandle { func start() throws {} ; func stop() {} }
    func make(folder: FolderSource, onEvent: @escaping @Sendable (String) -> Void) throws -> any FolderWatchHandle { Handle() }
}

/// Returns [1, 0] per input, or throws while `failing`.
private final class ScriptedEmbedder: EmbeddingProducing, @unchecked Sendable {
    let failing = Shared(false)
    let calls = Shared(0)
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        calls.value += 1
        if failing.value { throw IngestionError(code: "providerUnreachable") }
        return inputs.map { _ in [1, 0] }
    }
}

/// Collects `indexingStatusDidChange` notebook IDs posted by one store.
@MainActor
private final class ChangeLog {
    private(set) var notebooks: [Int64] = []
    nonisolated(unsafe) private var token: NSObjectProtocol?
    init(store: NotebookStore) {
        token = NotificationCenter.default.addObserver(forName: .indexingStatusDidChange, object: store, queue: nil) { [weak self] note in
            let id = note.userInfo?["notebookId"] as? Int64
            MainActor.assumeIsolated { if let id { self?.notebooks.append(id) } }
        }
    }
    func take() -> [Int64] { defer { notebooks = [] }; return notebooks }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

@MainActor
final class IndexingStatusStoreTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
    }

    private func folderWithFile() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Indexing progress keeps the user informed.\n".utf8).write(to: root.appendingPathComponent("a.md"))
        directories.append(root)
        return root
    }

    private static let selection = EmbeddingSelection(providerId: "local", endpointRevision: "1", model: "m", modelDigest: nil,
        dims: nil, normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")

    private struct Rig {
        let store: NotebookStore
        let runtime: FolderIngestionRuntime
        let notebook: Int64
        let clock: StepClock
        let embedder: ScriptedEmbedder
        let available: Shared<EmbeddingAvailability>
    }

    /// dispatch: false — the test drains jobs explicitly.
    private func rig(_ availability: EmbeddingAvailability = .noProvider) throws -> Rig {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "idx").id)
        let clock = StepClock(), embedder = ScriptedEmbedder(), available = Shared(availability)
        let session = FolderEmbeddingSession(selection: Self.selection, embedder: embedder)
        let runtime = try FolderIngestionRuntime.make(store: store, admission: IngestionAdmission(), resolveSession: { _ in
            available.value == .ready ? .ready(session) : .unavailable(available.value)
        }, clock: clock, watches: SilentWatches(), fileSystem: NativeFolderFileSystem(), dispatch: false)
        return Rig(store: store, runtime: runtime, notebook: notebook, clock: clock, embedder: embedder, available: available)
    }

    private func drainAll(_ runtime: FolderIngestionRuntime) async throws {
        for _ in 0..<200 where try await runtime.drainOnce() {}
    }

    // MARK: Live updates

    func testClaimFailRequeueRecoverAndCompletePostChanges() throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "n").id)
        let other = try XCTUnwrap(store.createNotebook(name: "o").id)
        let log = ChangeLog(store: store)
        let options = try Self.selection.optionsJSON(copyExisting: true)
        let job = try store.enqueueJob(IngestJobDraft(kind: "embed", target: "notebook:\(notebook)", targetRevision: nil,
                                                      optionsJSON: options), now: 0)
        _ = log.take()
        XCTAssertNotNil(try store.claimJob(now: 0, leaseToken: "a", id: job))
        XCTAssertEqual(log.take(), [notebook], "claim")
        XCTAssertTrue(try store.failJob(fence: JobFence(jobId: job, leaseToken: "a"), error: "providerUnreachable", now: 1))
        XCTAssertEqual(log.take(), [notebook], "fail")
        XCTAssertEqual(try store.requeueRetryableJobs(now: 0), 0)
        XCTAssertEqual(log.take(), [], "nothing due, nothing posted")
        XCTAssertEqual(try store.requeueRetryableJobs(now: 10_000), 1)
        XCTAssertEqual(log.take(), [notebook], "requeue")
        XCTAssertNotNil(try store.claimJob(now: 10_000, leaseToken: "b", id: job))
        _ = log.take()
        XCTAssertEqual(try store.recoverExpiredJobs(now: 20_000), 1)
        XCTAssertEqual(log.take(), [notebook], "lease recovery")
        let second = try XCTUnwrap(store.claimJob(now: 99_999, leaseToken: "c", id: job))
        _ = log.take()
        XCTAssertTrue(try store.completeEmptyBootstrap(fence: JobFence(jobId: second.id, leaseToken: "c"), now: 99_999))
        XCTAssertEqual(log.take(), [notebook], "empty bootstrap")
        // Owned-extraction cancellation and user cancellation.
        let source = try store.createSource(notebookId: other, type: .text, title: "t", uri: nil, rawPath: nil)
        let extract = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(source.id!)", targetRevision: nil), now: 0)
        _ = try store.claimJob(now: 100_000, leaseToken: "d", id: extract)
        _ = log.take()
        XCTAssertTrue(try store.cancelOwnedExtraction(fence: JobFence(jobId: extract, leaseToken: "d"), now: 100_000))
        XCTAssertEqual(log.take(), [other], "owned cancel")
        let queued = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(source.id!)", targetRevision: nil), now: 0)
        _ = log.take()
        XCTAssertTrue(try store.cancelIngestJob(id: queued, fence: nil, now: 100_000))
        XCTAssertEqual(log.take(), [other], "user cancel")
        XCTAssertFalse(try store.failJob(fence: JobFence(jobId: queued, leaseToken: "zzz"), error: "x", now: 100_000))
        XCTAssertEqual(log.take(), [], "a rejected fence posts nothing")
    }

    // MARK: Store inputs

    func testStoreStatusFollowsEmbedJob() async throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "s").id)
        XCTAssertEqual(try store.indexingStatus(notebookId: notebook, now: 0).phase, .empty)
        _ = try await IngestionService(store: store, plain: PlainTextExtractor())
            .ingestRawText(title: "t", text: "hello indexing world", into: notebook)
        XCTAssertTrue(try store.notebookNeedsEmbedding(notebookId: notebook))
        XCTAssertEqual(try store.indexingStatus(notebookId: notebook, now: 0).phase, .lexicalOnly)
        XCTAssertEqual(try store.indexingStatus(notebookId: notebook, now: 0, availability: .noModel).phase,
                       .blocked(.noEmbeddingModel))
        XCTAssertEqual(try store.indexingStatus(notebookId: notebook, now: 0, runtimeError: "unexpectedError").phase,
                       .blocked(.runtimeFailed(code: "unexpectedError")))
        let job = try store.requestEmbeddingBuild(notebookId: notebook, selection: Self.selection, copyExisting: true, now: 0)
        XCTAssertTrue(try store.hasUnfinishedEmbedJob(notebookId: notebook))
        XCTAssertEqual(try store.indexingStatus(notebookId: notebook, now: 0).phase, .embedding(done: nil, total: nil, preparing: true))
        _ = try store.claimJob(now: 0, leaseToken: "t", id: job)
        XCTAssertTrue(try store.failEmbeddingJob(fence: JobFence(jobId: job, leaseToken: "t"), error: "providerUnreachable", now: 10))
        XCTAssertEqual(try store.indexingStatus(notebookId: notebook, now: 10).phase,
                       .retrying(IndexingRetry(code: "providerUnreachable", retryAt: 70, attempt: 1, retryInSeconds: 60)))
        XCTAssertTrue(try store.expediteEmbedRetry(notebookId: notebook, now: 10))
        XCTAssertEqual(try store.job(id: job)?.state, "queued")
        XCTAssertEqual(try store.indexingStatus(notebookId: notebook, now: 10).phase, .embedding(done: nil, total: nil, preparing: true))
        XCTAssertFalse(try store.expediteEmbedRetry(notebookId: notebook, now: 10), "nothing waiting any more")
        let inputs = try store.indexingInputs(notebookId: notebook, now: 10)
        XCTAssertEqual(inputs.sourcesTotal, 1)
        XCTAssertEqual(inputs.sourcesReady, 1)
        XCTAssertEqual(inputs.embedJob?.attempts, 1)
        XCTAssertThrowsError(try store.indexingInputs(notebookId: 9_999, now: 0))
    }

    // MARK: Runtime behaviour

    func testScanNowOnUnchangedFolderBuildsMissingIndex() async throws {
        let rig = try rig(.noProvider)
        let folder = try await rig.runtime.addFolder(notebookId: rig.notebook, url: try folderWithFile())
        try await drainAll(rig.runtime)
        // Published without an embed job: no session existed.
        XCTAssertFalse(try rig.store.hasUnfinishedEmbedJob(notebookId: rig.notebook))
        var status = try await rig.runtime.indexingStatus(notebookId: rig.notebook)
        XCTAssertEqual(status.phase, .blocked(.noEmbeddingModel))
        let embeddingAvailability = await rig.runtime.embeddingAvailability(notebookId: rig.notebook)
        XCTAssertEqual(embeddingAvailability, .noProvider)
        let first = await rig.runtime.lastScanOutcome(folderId: folder.id)
        XCTAssertEqual(first?.changedFiles, 1)
        XCTAssertEqual(first?.filesSeen, 1)

        rig.available.value = .ready
        status = try await rig.runtime.indexingStatus(notebookId: rig.notebook)
        XCTAssertEqual(status.phase, .lexicalOnly)
        // Scan now on the unchanged folder: fast path, no publication, yet the index gets built.
        _ = try await rig.runtime.scanNow(folderId: folder.id, verifyAll: false)
        let scanned = try await rig.runtime.drainOnce()
        XCTAssertTrue(scanned, "the scan")
        let unchanged = await rig.runtime.lastScanOutcome(folderId: folder.id)
        XCTAssertEqual(unchanged?.changedFiles, 0)
        XCTAssertEqual(unchanged?.filesSeen, 1)
        XCTAssertTrue(try rig.store.hasUnfinishedEmbedJob(notebookId: rig.notebook))
        status = try await rig.runtime.indexingStatus(notebookId: rig.notebook)
        XCTAssertEqual(status.phase, .embedding(done: nil, total: nil, preparing: true))
        try await drainAll(rig.runtime)
        XCTAssertNotNil(try rig.store.activeGeneration(notebookId: rig.notebook))
        status = try await rig.runtime.indexingStatus(notebookId: rig.notebook)
        XCTAssertEqual(status.phase, .ready)
        XCTAssertFalse(status.isActive)
        // A further unchanged scan requests nothing.
        _ = try await rig.runtime.scanNow(folderId: folder.id, verifyAll: false)
        try await drainAll(rig.runtime)
        XCTAssertFalse(try rig.store.hasUnfinishedEmbedJob(notebookId: rig.notebook))
    }

    func testRetryNowExpeditesWaitingJobAndRebuildsAfterTerminalFailure() async throws {
        let rig = try rig(.ready)
        rig.embedder.failing.value = true
        _ = try await rig.runtime.addFolder(notebookId: rig.notebook, url: try folderWithFile())
        try await drainAll(rig.runtime)
        var status = try await rig.runtime.indexingStatus(notebookId: rig.notebook)
        guard case .retrying(let retry) = status.phase else { return XCTFail("expected retrying, got \(status.phase)") }
        XCTAssertEqual(retry.code, "providerUnreachable")
        XCTAssertEqual(retry.attempt, 1)
        XCTAssertGreaterThan(retry.retryInSeconds, 0)
        rig.embedder.failing.value = false
        try await rig.runtime.retryIndexingNow(notebookId: rig.notebook)
        status = try await rig.runtime.indexingStatus(notebookId: rig.notebook)
        XCTAssertEqual(status.phase, .embedding(done: nil, total: nil, preparing: true))
        try await drainAll(rig.runtime)
        status = try await rig.runtime.indexingStatus(notebookId: rig.notebook)
        XCTAssertEqual(status.phase, .ready)

        // Terminal failure: retry queues a fresh build.
        let store = rig.store, notebook = rig.notebook
        let failed = try store.requestEmbeddingBuild(notebookId: notebook, selection: Self.selection, copyExisting: true, now: 0)
        try store.runOnDatabase { db in
            try db.execute(sql: "UPDATE ingest_jobs SET state='failed',attempts=5,error='providerHttp500' WHERE id=?", arguments: [failed])
            try db.execute(sql: "UPDATE index_generations SET state='retired' WHERE notebook_id=?", arguments: [notebook])
        }
        status = try await rig.runtime.indexingStatus(notebookId: notebook)
        XCTAssertEqual(status.phase, .blocked(.indexFailed(code: "providerHttp500")))
        try await rig.runtime.retryIndexingNow(notebookId: notebook)
        XCTAssertTrue(try store.hasUnfinishedEmbedJob(notebookId: notebook))
        try await drainAll(rig.runtime)
        status = try await rig.runtime.indexingStatus(notebookId: notebook)
        XCTAssertEqual(status.phase, .ready)
    }

    /// A source whose current revision never published (legacy stuck `pending`) defers
    /// activation; the build attempt must end instead of spinning on the main actor.
    func testUnpublishableSourceDefersActivationWithoutSpinning() async throws {
        let rig = try rig(.ready)
        let store = rig.store, notebook = rig.notebook
        _ = try await IngestionService(store: store, plain: PlainTextExtractor())
            .ingestRawText(title: "t", text: "published text", into: notebook)
        let stuck = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: "stuck", uri: nil, rawPath: nil).id)
        try store.runOnDatabase { db in
            try db.execute(sql: """
                INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                VALUES(?,1,'h','',1,2,?)
                """, arguments: [stuck, Date(timeIntervalSince1970: 0)])
            try db.execute(sql: "UPDATE sources SET current_revision=? WHERE id=?", arguments: [db.lastInsertedRowID, stuck])
        }
        try await rig.runtime.retryIndexingNow(notebookId: notebook)
        let runtime = rig.runtime
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { for _ in 0..<50 where (try? await runtime.drainOnce()) == true {}; return true }
            group.addTask { try? await Task.sleep(for: .seconds(20)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(finished, "the deferred build must not spin")
        XCTAssertNil(try store.activeGeneration(notebookId: notebook), "activation waits for the unpublished source")
    }

    func testExtractionPublishesWhenCredentialCannotBeLoaded() async throws {
        let rig = try rig(.credentialUnavailable)
        _ = try await rig.runtime.addFolder(notebookId: rig.notebook, url: try folderWithFile())
        try await drainAll(rig.runtime)
        let sources = try rig.store.sources(notebookId: rig.notebook)
        XCTAssertEqual(sources.map(\.status), [.ready], "a credential error never fails extraction")
        XCTAssertFalse(try rig.store.hasUnfinishedEmbedJob(notebookId: rig.notebook))
        let status = try await rig.runtime.indexingStatus(notebookId: rig.notebook)
        XCTAssertEqual(status.phase, .blocked(.credentialUnavailable))
        XCTAssertEqual(status.sourceErrors, 0)
    }

    func testExtractionWorkerToleratesThrowingSelection() async throws {
        struct KeychainDown: Error {}
        let nothing = try await FolderExtractionWorker.publishableSelection(1) { _ in throw KeychainDown() }
        XCTAssertNil(nothing)
        do {
            _ = try await FolderExtractionWorker.publishableSelection(1) { _ in throw CancellationError() }
            XCTFail("cancellation propagates")
        } catch is CancellationError {}
    }

    func testStartFailureIsExposedAndRetried() async throws {
        let rig = try rig(.ready)
        let store = rig.store, notebook = rig.notebook
        try store.runOnDatabase { db in
            try db.execute(sql: """
                INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,watch_enabled,created_at)
                VALUES(7,?,'/broken','{','B','["md"]','[]','{}',1,?)
                """, arguments: [notebook, Date(timeIntervalSince1970: 0)])
        }
        do {
            try await rig.runtime.start()
            XCTFail("a corrupt folder row fails the start")
        } catch {}
        let startError = await rig.runtime.startError
        XCTAssertEqual(startError, "unexpectedError")
        var status = try await rig.runtime.indexingStatus(notebookId: notebook)
        XCTAssertEqual(status.phase, .blocked(.runtimeFailed(code: "unexpectedError")))
        // Repair and retry: the start succeeds and the error clears.
        let identity = try JSONEncoder().encode(FolderIdentity(volumeId: "v", components: ["broken"], rootFileId: "b"))
        try store.runOnDatabase { db in
            try db.execute(sql: "UPDATE folder_sources SET path_identity=? WHERE id=7", arguments: [String(decoding: identity, as: UTF8.self)])
        }
        try await rig.runtime.retryIndexingNow(notebookId: notebook)
        let cleared = await rig.runtime.startError
        XCTAssertNil(cleared)
        status = try await rig.runtime.indexingStatus(notebookId: notebook)
        XCTAssertEqual(status.phase, .scanning(filesSeen: nil), "the startup scan is queued")
        await rig.runtime.stop()
    }
}

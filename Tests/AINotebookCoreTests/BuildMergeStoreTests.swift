import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private struct MergeClock: IngestLeaseClock {
    func now() -> Int64 { 2 }
    func wait(until: Int64) async throws { try await Task.sleep(nanoseconds: 1_000_000) }
}

/// Answers a 3-dimensional vector per input; runs `hook` (once) before the given call number.
private final class HookedEmbedder: EmbeddingProducing, @unchecked Sendable {
    private let gate = NSLock()
    private var count = 0
    private let hookAt: Int
    private let hook: @Sendable () async throws -> Void
    init(hookAt: Int, hook: @escaping @Sendable () async throws -> Void) {
        self.hookAt = hookAt
        self.hook = hook
    }
    var calls: Int { gate.withLock { count } }
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        let call = gate.withLock { count += 1; return count }
        if call == hookAt { try await hook() }
        return inputs.map { [Float($0.unicodeScalars.count + 1), 1, 2] }
    }
}

private struct NoWatches: FolderWatchFactory {
    struct Handle: FolderWatchHandle { func start() throws {} ; func stop() {} }
    func make(folder: FolderSource, onEvent: @escaping @Sendable (String) -> Void) throws -> any FolderWatchHandle { Handle() }
}

/// `ingestion-build-merge-v1` and `indexing-status-v1` §8 through the real store, coordinator and runtime.
@MainActor
final class BuildMergeStoreTests: XCTestCase {
    /// A raw provider: dimensions unknown until the first response.
    static let raw = EmbeddingSelection(providerId: "ollama", endpointRevision: "e1", model: "nomic-embed-text", modelDigest: nil,
        dims: nil, normalization: "l2", queryFormatVersion: "2", docFormatVersion: "2", chunkerVersion: "2")
    static let identity = GenerationIdentity(providerId: "ollama", endpointRevision: "e1", model: "nomic-embed-text",
        modelDigest: nil, dims: 3, normalization: "l2", queryFormatVersion: "2", docFormatVersion: "2", chunkerVersion: "2")

    private func store(sources: Int) throws -> (NotebookStore, Int64) {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "merge").id)
        try EmbeddingPlanContractTests.seed(store, notebookId: notebook, sources: (1...max(1, sources)).prefix(sources).map {
            ["id": $0, "type": "text", "chunks": ["chunk text \($0)"]]
        })
        return (store, notebook)
    }

    private func bootstrap(_ store: NotebookStore, _ notebook: Int64, copyExisting: Bool = true) throws -> Int64 {
        try store.enqueueJob(IngestJobDraft(kind: "embed", target: "notebook:\(notebook)", targetRevision: nil,
                                            optionsJSON: try Self.raw.optionsJSON(copyExisting: copyExisting)), now: 1)
    }

    private func generationCount(_ store: NotebookStore, _ notebook: Int64) throws -> Int {
        try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM index_generations WHERE notebook_id=?",
                                                    arguments: [notebook]) ?? 0 }
    }

    nonisolated private static func unfinishedEmbedJobs(_ store: NotebookStore) throws -> [String] {
        try store.runOnDatabase { try String.fetchAll($0, sql: """
            SELECT target FROM ingest_jobs WHERE kind='embed' AND (state IN ('queued','running','paused')
              OR (state='failed' AND attempts<5 AND next_retry_at IS NOT NULL)) ORDER BY id
            """) }
    }

    private func coordinator(_ store: NotebookStore, embedder: any EmbeddingProducing, batchSize: Int = 1) -> FolderIndexCoordinator {
        let selection = Self.raw
        return FolderIndexCoordinator(store: store, admission: IngestionAdmission(), clock: MergeClock(),
            session: { _ in FolderEmbeddingSession(selection: selection, embedder: embedder) },
            selectedSelection: { _ in selection }, batchSize: batchSize)
    }

    /// Runs one embed job to its end through the real coordinator.
    private func run(_ store: NotebookStore, _ coordinator: FolderIndexCoordinator, jobId: Int64, lease: String) async throws {
        let job = try XCTUnwrap(store.claimJob(now: 2, leaseToken: lease, id: jobId))
        try await coordinator.execute(job: job, fence: JobFence(jobId: jobId, leaseToken: lease))
    }

    // MARK: indexing-status-v1 §8

    /// The reported database: generation 1 building with its running job, a bootstrap queued behind it.
    func testRunningBuildIsNotHiddenByQueuedBootstrap() throws {
        let (store, notebook) = try store(sources: 2)
        let generation = try store.requestReindex(notebookId: notebook, identity: Self.identity, now: 1)
        let jobId = try XCTUnwrap(try store.generationProgress(notebookId: notebook).jobId)
        _ = try XCTUnwrap(store.claimJob(now: 2, leaseToken: "build", id: jobId))
        _ = try bootstrap(store, notebook)
        XCTAssertEqual(try store.indexingStatus(notebookId: notebook, now: 2).phase,
                       .embedding(done: 0, total: 2, preparing: false))
        let progress = try store.generationProgress(notebookId: notebook)
        XCTAssertFalse(progress.preparing)
        XCTAssertEqual(progress.jobId, jobId, "discard targets the running build")
        XCTAssertEqual(progress.generationId, generation)
    }

    /// After a restart the build job is queued again; the newer bootstrap still reports the build's progress.
    func testQueuedBootstrapReportsBuildingGenerationProgress() throws {
        let (store, notebook) = try store(sources: 2)
        _ = try store.requestReindex(notebookId: notebook, identity: Self.identity, now: 1)
        _ = try bootstrap(store, notebook)
        XCTAssertEqual(try store.indexingStatus(notebookId: notebook, now: 2).phase,
                       .embedding(done: 0, total: 2, preparing: false))
        XCTAssertFalse(try store.generationProgress(notebookId: notebook).preparing)
    }

    func testBootstrapWithoutGenerationStillPrepares() throws {
        let (store, notebook) = try store(sources: 1)
        _ = try store.requestEmbeddingBuild(notebookId: notebook, selection: Self.raw, copyExisting: true, now: 1)
        XCTAssertEqual(try store.indexingStatus(notebookId: notebook, now: 2).phase, .embedding(done: nil, total: nil, preparing: true))
        XCTAssertTrue(try store.generationProgress(notebookId: notebook).preparing)
    }

    // MARK: ingestion-build-merge-v1 §2–3

    func testRawBuildRequestJoinsBuildingGeneration() throws {
        let (store, notebook) = try store(sources: 2)
        _ = try store.requestReindex(notebookId: notebook, identity: Self.identity, now: 1)
        let jobId = try XCTUnwrap(try store.generationProgress(notebookId: notebook).jobId)
        _ = try XCTUnwrap(store.claimJob(now: 2, leaseToken: "build", id: jobId))
        XCTAssertEqual(try store.requestEmbeddingBuild(notebookId: notebook, selection: Self.raw, copyExisting: true, now: 2), jobId)
        XCTAssertEqual(try Self.unfinishedEmbedJobs(store), ["generation:\(try XCTUnwrap(store.generationProgress(notebookId: notebook).generationId))"])
        XCTAssertEqual(try generationCount(store, notebook), 1)
    }

    func testGenerationJobSupersedesQueuedBootstraps() throws {
        let (store, notebook) = try store(sources: 2)
        let early = try bootstrap(store, notebook)
        let reindex = try bootstrap(store, notebook, copyExisting: false)
        let generation = try store.requestReindex(notebookId: notebook, identity: Self.identity, now: 1)
        XCTAssertEqual(try store.job(id: early)?.state, "done", "an incremental bootstrap completes as a no-op")
        XCTAssertNil(try store.job(id: early)?.error)
        XCTAssertEqual(try store.job(id: reindex)?.state, "queued", "an explicit re-index bootstrap is kept")
        XCTAssertEqual(try Self.unfinishedEmbedJobs(store), ["notebook:\(notebook)", "generation:\(generation)"])
    }

    func testRawBuildRequestBesideActiveSpaceSkipsBootstrap() async throws {
        let (store, notebook) = try store(sources: 2)
        let coordinator = coordinator(store, embedder: HookedEmbedder(hookAt: 0) {})
        try await run(store, coordinator, jobId: try store.requestEmbeddingBuild(notebookId: notebook, selection: Self.raw,
                                                                                copyExisting: true, now: 1), lease: "first")
        let active = try XCTUnwrap(store.activeGeneration(notebookId: notebook))
        XCTAssertEqual(active.identity, Self.identity)
        try EmbeddingPlanContractTests.seed(store, notebookId: notebook, sources: [["id": 3, "type": "text", "chunks": ["new"]]])
        _ = try store.requestEmbeddingBuild(notebookId: notebook, selection: Self.raw, copyExisting: true, now: 3)
        let pending = try Self.unfinishedEmbedJobs(store)
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(pending[0].hasPrefix("generation:"), "verified dimensions of the active space: no provider probe")
    }

    // MARK: ingestion-build-merge-v1 §4

    func testStartupMergesBootstrapIntoBuildingGeneration() throws {
        let (store, notebook) = try store(sources: 2)
        let generation = try store.requestReindex(notebookId: notebook, identity: Self.identity, now: 1)
        let legacy = try bootstrap(store, notebook)
        XCTAssertEqual(try store.mergeRedundantBootstraps(now: 2), 1)
        XCTAssertEqual(try store.job(id: legacy)?.state, "done")
        XCTAssertEqual(try Self.unfinishedEmbedJobs(store), ["generation:\(generation)"])
        XCTAssertEqual(try generationCount(store, notebook), 1)
        XCTAssertEqual(try store.mergeRedundantBootstraps(now: 2), 0, "idempotent")
    }

    func testStartupCompletesBootstrapOfCurrentActiveSpace() async throws {
        let (store, notebook) = try store(sources: 2)
        let coordinator = coordinator(store, embedder: HookedEmbedder(hookAt: 0) {})
        try await run(store, coordinator, jobId: try store.requestEmbeddingBuild(notebookId: notebook, selection: Self.raw,
                                                                                copyExisting: true, now: 1), lease: "first")
        let legacy = try bootstrap(store, notebook)
        let reindex = try bootstrap(store, notebook, copyExisting: false)
        XCTAssertEqual(try store.mergeRedundantBootstraps(now: 2), 1)
        XCTAssertEqual(try store.job(id: legacy)?.state, "done")
        XCTAssertEqual(try store.job(id: reindex)?.state, "queued")
        XCTAssertEqual(try generationCount(store, notebook), 1, "nothing to embed: no second generation")
    }

    func testRuntimeStartMergesLegacyBootstrap() async throws {
        let (store, notebook) = try store(sources: 2)
        let generation = try store.requestReindex(notebookId: notebook, identity: Self.identity, now: 1)
        let legacy = try bootstrap(store, notebook)
        let session = FolderEmbeddingSession(selection: Self.raw, embedder: HookedEmbedder(hookAt: 0) {})
        let runtime = try FolderIngestionRuntime.make(store: store, admission: IngestionAdmission(),
            resolveSession: { _ in .ready(session) }, clock: MergeClock(), watches: NoWatches(),
            fileSystem: NativeFolderFileSystem(), dispatch: false)
        try await runtime.start()
        XCTAssertEqual(try store.job(id: legacy)?.state, "done")
        XCTAssertEqual(try Self.unfinishedEmbedJobs(store), ["generation:\(generation)"])
        for _ in 0..<20 where try await runtime.drainOnce() {}
        await runtime.stop()
        XCTAssertEqual(try store.activeGeneration(notebookId: notebook)?.id, generation)
        XCTAssertEqual(try generationCount(store, notebook), 1)
        XCTAssertEqual(try Self.unfinishedEmbedJobs(store), [])
    }

    // MARK: End to end

    /// A raw-provider build in progress, a publication arrives: one generation, one activation,
    /// "Indexing d / t" throughout and the new source covered.
    func testPublicationDuringRawBuildActivatesOnce() async throws {
        let (store, notebook) = try store(sources: 3)
        let seen = SeenStatuses()
        let embedder = HookedEmbedder(hookAt: 2) {
            try await MainActor.run {
                seen.phases.append(try store.indexingStatus(notebookId: notebook, now: 2).phase)
                try EmbeddingPlanContractTests.seed(store, notebookId: notebook,
                                                    sources: [["id": 4, "type": "text", "chunks": ["published during the build"]]])
                // What the publication transaction does (`IngestionPublicationSQL.publishLoose` → `enqueueBuild`).
                seen.jobs.append(try store.requestEmbeddingBuild(notebookId: notebook, selection: Self.raw, copyExisting: true, now: 2))
                seen.phases.append(try store.indexingStatus(notebookId: notebook, now: 2).phase)
                seen.pending = try Self.unfinishedEmbedJobs(store)
            }
        }
        let jobId = try store.requestEmbeddingBuild(notebookId: notebook, selection: Self.raw, copyExisting: true, now: 1)
        XCTAssertEqual(try store.indexingStatus(notebookId: notebook, now: 1).phase, .embedding(done: nil, total: nil, preparing: true))
        try await run(store, coordinator(store, embedder: embedder), jobId: jobId, lease: "build")

        XCTAssertEqual(seen.phases, [.embedding(done: 1, total: 3, preparing: false), .embedding(done: 1, total: 4, preparing: false)])
        XCTAssertEqual(seen.jobs, [jobId], "the publication joins the running build")
        XCTAssertEqual(seen.pending.count, 1)
        XCTAssertEqual(try Self.unfinishedEmbedJobs(store), [], "no bootstrap left to build a second generation")
        XCTAssertEqual(try generationCount(store, notebook), 1)
        let active = try XCTUnwrap(store.activeGeneration(notebookId: notebook))
        XCTAssertEqual(try store.manifest(generationId: active.id).filter { $0.state == "done" }.map(\.sourceId).sorted(), [1, 2, 3, 4])
        XCTAssertEqual(embedder.calls, 4, "one provider call per chunk, no second probe")
        XCTAssertEqual(try store.indexingStatus(notebookId: notebook, now: 3).phase, .ready)
    }
}

@MainActor
private final class SeenStatuses {
    var phases: [IndexingPhase] = []
    var jobs: [Int64] = []
    var pending: [String] = []
}

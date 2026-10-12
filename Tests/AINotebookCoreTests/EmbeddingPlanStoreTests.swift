import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private struct StoreClock: IngestLeaseClock {
    func now() -> Int64 { 2 }
    func wait(until: Int64) async throws { try await Task.sleep(nanoseconds: 1_000_000) }
}

/// Store-level `embedding-plan-v1` behaviour beyond the shared build cases.
@MainActor
final class EmbeddingPlanStoreTests: XCTestCase {
    private let selection = EmbeddingSelection(providerId: "local", endpointRevision: "1", model: "m", modelDigest: nil, dims: 3,
        normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")

    private func makeStore(_ sources: [[String: Any]]) throws -> (NotebookStore, Int64) {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "plan").id)
        try EmbeddingPlanContractTests.seed(store, notebookId: notebook, sources: sources)
        return (store, notebook)
    }

    private func build(_ store: NotebookStore, notebook: Int64, copyExisting: Bool = false, batchSize: Int = 64,
                       embedder: RecordingTextEmbedder = RecordingTextEmbedder()) async throws -> RecordingTextEmbedder {
        let jobId = try store.requestEmbeddingBuild(notebookId: notebook, selection: selection, copyExisting: copyExisting, now: 1)
        let token = "build-\(jobId)"
        let job = try XCTUnwrap(store.claimJob(now: 1, leaseToken: token, id: jobId))
        let selection = self.selection
        let coordinator = FolderIndexCoordinator(store: store, admission: IngestionAdmission(), clock: StoreClock(),
            session: { _ in FolderEmbeddingSession(selection: selection, embedder: embedder) },
            selectedSelection: { _ in selection }, batchSize: batchSize)
        try await coordinator.execute(job: job, fence: JobFence(jobId: jobId, leaseToken: token))
        return embedder
    }

    /// Capped spreadsheet chunks are full-text only: the source is done, the notebook needs no
    /// embedding, the status is ready, and the query pin serves the source's 64 vectors.
    func testCappedSpreadsheetIsIndexedNotMissing() async throws {
        let (store, notebook) = try makeStore([["id": 1, "type": "xlsx", "chunks": (0..<100).map { "row \($0)" }]])
        let embedder = try await build(store, notebook: notebook)
        XCTAssertEqual(embedder.calls.map(\.count), [64])
        let active = try XCTUnwrap(store.activeGeneration(notebookId: notebook))
        XCTAssertEqual(try store.manifest(generationId: active.id).map(\.state), ["done"])
        XCTAssertFalse(try store.notebookNeedsEmbedding(notebookId: notebook))
        XCTAssertEqual(try store.indexingStatus(notebookId: notebook, now: 5).phase, .ready)
        let pin = try store.pinQuery(notebookId: notebook, modelKey: active.identity.modelKey)
        defer { store.releaseQuery(pin) }
        XCTAssertNotNil(pin.vectorRevisions[1])
        XCTAssertEqual(try store.pinnedEmbeddings(pin).count, 64)
        try store.runOnDatabase { db in
            let lexical = try Int64.fetchAll(db, sql: """
                SELECT c.ord FROM chunks_fts JOIN source_chunks c ON c.id=chunks_fts.chunk_id WHERE chunks_fts MATCH '"row 99"'
                """)
            XCTAssertEqual(lexical, [99], "an unembedded spreadsheet chunk stays searchable by full text")
        }
    }

    /// A source re-published behind the keyset cursor is picked up in the next round:
    /// settling changed the manifest, so the walk restarts from the beginning.
    func testCursorResetsWhenTheManifestChanges() throws {
        let (store, notebook) = try makeStore([["id": 1, "type": "text", "chunks": ["a1"]], ["id": 2, "type": "text", "chunks": ["b1", "b2"]]])
        let jobId = try store.requestEmbeddingBuild(notebookId: notebook, selection: selection, copyExisting: false, now: 1)
        let generationId = try XCTUnwrap(Int64(try XCTUnwrap(store.job(id: jobId)).draft.target.dropFirst("generation:".count)))
        _ = try store.claimJob(now: 1, leaseToken: "owner", id: jobId)
        let fence = JobFence(jobId: jobId, leaseToken: "owner")
        let first = try XCTUnwrap(store.captureEmbeddingRound(generationId: generationId, limit: 2, cursor: nil, fence: fence, now: 2))
        XCTAssertEqual(first.items.map(\.text), ["a1", "b1"])
        XCTAssertEqual(first.cursor, EmbeddingCursor(priorityClass: 0, sourceId: 2, ord: 0))
        XCTAssertTrue(try store.commitEmbeddingBatch(generationId: generationId, chunkIds: first.items.map(\.chunkId),
            revisionIds: first.items.map(\.revisionId), vectors: [[1, 0, 0], [0, 1, 0]], fence: fence, now: 2))
        _ = try store.commitForegroundRevision(sourceId: 1, draft: RevisionDraft(contentHash: "new", canonicalText: "a new",
            textFormatVersion: 1, chunkerVersion: 2), chunks: ScalarChunker.chunk("a new"), now: 2, leaseToken: "republish")
        let second = try XCTUnwrap(store.captureEmbeddingRound(generationId: generationId, limit: 2, cursor: first.cursor,
                                                               fence: fence, now: 2))
        XCTAssertTrue(second.reset)
        XCTAssertEqual(second.items.map(\.text), ["a new", "b2"])
        // Without a manifest change the cursor is honoured.
        let third = try XCTUnwrap(store.captureEmbeddingRound(generationId: generationId, limit: 2, cursor: second.cursor,
                                                              fence: fence, now: 2))
        XCTAssertFalse(third.reset)
        XCTAssertTrue(third.items.isEmpty)
        // A lost fence captures nothing.
        XCTAssertNil(try store.captureEmbeddingRound(generationId: generationId, limit: 2, cursor: nil,
                                                     fence: JobFence(jobId: jobId, leaseToken: "other"), now: 2))
    }

    /// Copies count separately in progress while the build runs; done still reaches total.
    func testProgressCountsCopiedVectors() throws {
        let (store, notebook) = try makeStore([["id": 1, "type": "text", "chunks": ["same", "x"]], ["id": 2, "type": "text", "chunks": ["same"]]])
        let jobId = try store.requestEmbeddingBuild(notebookId: notebook, selection: selection, copyExisting: false, now: 1)
        let generationId = try XCTUnwrap(Int64(try XCTUnwrap(store.job(id: jobId)).draft.target.dropFirst("generation:".count)))
        _ = try store.claimJob(now: 1, leaseToken: "owner", id: jobId)
        let fence = JobFence(jobId: jobId, leaseToken: "owner")
        let round = try XCTUnwrap(store.captureEmbeddingRound(generationId: generationId, limit: 1, cursor: nil, fence: fence, now: 2))
        XCTAssertEqual(round.items.map(\.text), ["same"])
        XCTAssertTrue(round.joined.isEmpty, "the request is full before the duplicate is reached")
        XCTAssertTrue(try store.commitEmbeddingBatch(generationId: generationId, chunkIds: round.items.map(\.chunkId),
            revisionIds: round.items.map(\.revisionId), vectors: [[1, 2, 2]], fence: fence, now: 2))
        let next = try XCTUnwrap(store.captureEmbeddingRound(generationId: generationId, limit: 1, cursor: round.cursor,
                                                             fence: fence, now: 2))
        XCTAssertEqual(next.items.map(\.text), ["x"])
        XCTAssertEqual(next.copied, 1, "source 2's chunk copies the existing vector of 'same'")
        let progress = try store.generationProgress(notebookId: notebook)
        XCTAssertEqual(progress.copied, 1)
        XCTAssertEqual(try store.indexingStatus(notebookId: notebook, now: 2).phase, .embedding(done: 2, total: 3, preparing: false))
        try store.runOnDatabase { db in
            let blobs = try Data.fetchAll(db, sql: """
                SELECT e.embedding FROM chunk_embeddings e JOIN source_chunks c ON c.id=e.chunk_id WHERE c.text='same' ORDER BY c.id
                """)
            XCTAssertEqual(blobs.count, 2)
            XCTAssertEqual(blobs[0], blobs[1])
        }
    }

    /// An incremental build carries the ledger of copied unchanged vectors, so a new source
    /// whose text the active index already embedded costs no provider call.
    func testIncrementalBuildDedupsAgainstCarriedVectors() async throws {
        let (store, notebook) = try makeStore([["id": 1, "type": "xlsx", "chunks": ["Header", "Row"]]])
        _ = try await build(store, notebook: notebook)
        let first = try XCTUnwrap(store.activeGeneration(notebookId: notebook))
        try EmbeddingPlanContractTests.seed(store, notebookId: notebook, sources: [["id": 2, "type": "xlsx", "chunks": ["Header", "Row", "New"]]])
        let embedder = try await build(store, notebook: notebook, copyExisting: true)
        XCTAssertEqual(embedder.calls, [["New"]])
        let second = try XCTUnwrap(store.activeGeneration(notebookId: notebook))
        XCTAssertNotEqual(first.id, second.id)
        try store.runOnDatabase { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM generation_text_hashes WHERE generation_id=? AND copied=0",
                                            arguments: [second.id]), 3)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM generation_text_hashes WHERE generation_id=? AND copied=1",
                                            arguments: [second.id]), 2)
        }
    }
}

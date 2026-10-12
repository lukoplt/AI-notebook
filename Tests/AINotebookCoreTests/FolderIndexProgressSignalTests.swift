import Foundation
import XCTest
@testable import AINotebookCore

/// Records notebook IDs of one notification name posted by one store.
@MainActor
private final class Posts {
    private(set) var ids: [Int64] = []
    nonisolated(unsafe) private var token: NSObjectProtocol?
    init(_ name: Notification.Name, store: NotebookStore) {
        token = NotificationCenter.default.addObserver(forName: name, object: store, queue: nil) { [weak self] note in
            let id = note.userInfo?["notebookId"] as? Int64
            MainActor.assumeIsolated { if let id { self?.ids.append(id) } }
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

/// A committed background batch is indexing progress, not a catalog change:
/// it posts the status-only signal, coalesced to at most one per interval per
/// notebook (leading edge plus one trailing post), so a fast build does not
/// make every observer reload on the main actor several times per second.
@MainActor
final class FolderIndexProgressSignalTests: XCTestCase {
    private let selection = EmbeddingSelection(providerId: "local", endpointRevision: "1", model: "m", modelDigest: nil, dims: 2,
        normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")

    func testBatchCommitsPostCoalescedStatusSignalsOnly() async throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        store.indexingProgressInterval = 0.3
        let notebook = try XCTUnwrap(store.createNotebook(name: "signal").id)
        var chunks: [(Int64, Int64)] = []
        for title in ["a", "b", "c", "d"] {
            let source = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: title, uri: nil, rawPath: nil).id)
            let revision = try store.commitForegroundRevision(sourceId: source, draft: RevisionDraft(contentHash: title,
                canonicalText: "text " + title, textFormatVersion: 1, chunkerVersion: 2), chunks: ScalarChunker.chunk("text " + title),
                now: 0, leaseToken: title)
            chunks.append((try XCTUnwrap(store.chunks(sourceId: source).first?.id), revision.id))
        }
        let jobId = try store.requestEmbeddingBuild(notebookId: notebook, selection: selection, copyExisting: false, now: 0)
        let generationId = try XCTUnwrap(Int64(try XCTUnwrap(store.job(id: jobId)).draft.target.dropFirst("generation:".count)))
        _ = try store.claimJob(now: 1, leaseToken: "owner", id: jobId)
        let fence = JobFence(jobId: jobId, leaseToken: "owner")
        let catalog = Posts(.folderIngestionDidChange, store: store), status = Posts(.indexingStatusDidChange, store: store)
        for (chunk, revision) in chunks.prefix(3) {
            XCTAssertTrue(try store.commitEmbeddingBatch(generationId: generationId, chunkIds: [chunk], revisionIds: [revision],
                                                         vectors: [[1, 0]], fence: fence, now: 2))
        }
        XCTAssertEqual(catalog.ids, [], "a batch commit is not a catalog mutation")
        XCTAssertEqual(status.ids, [notebook], "the first batch of a window posts at once; the rest coalesce")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(status.ids, [notebook, notebook], "one trailing post carries the coalesced batches")
        XCTAssertEqual(try store.generationProgress(notebookId: notebook).done, 3)
        // After a quiet interval the next batch posts immediately again, with nothing trailing.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(try store.commitEmbeddingBatch(generationId: generationId, chunkIds: [chunks[3].0], revisionIds: [chunks[3].1],
                                                     vectors: [[0, 1]], fence: fence, now: 2))
        XCTAssertEqual(status.ids, [notebook, notebook, notebook])
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(status.ids.count, 3)
        // Activation is a catalog change and posts both signals at once.
        let identity = try XCTUnwrap(store.generation(id: generationId)).identity
        XCTAssertTrue(try store.activateBuiltGeneration(id: generationId, selectedIdentity: identity, fence: fence, now: 3))
        XCTAssertEqual(catalog.ids, [notebook])
        XCTAssertEqual(status.ids.count, 4)
    }
}

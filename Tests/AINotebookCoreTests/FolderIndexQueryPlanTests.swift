import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

/// Per-batch generation statements must stay proportional to the manifest and the
/// batch, never to the whole chunk table (otherwise a folder with hundreds of thousands
/// of chunks re-reads every chunk row in every batch).
@MainActor
final class FolderIndexQueryPlanTests: XCTestCase {
    private let identity = GenerationIdentity(providerId: "local", endpointRevision: "1", model: "m", modelDigest: nil,
        dims: 2, normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")

    private func plan(_ store: NotebookStore, _ sql: String, _ arguments: StatementArguments) throws -> [String] {
        try store.runOnDatabase { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments).map { $0["detail"] as String }
        }
    }

    func testPruneStaleVectorsReachesChunksOnlyThroughOtherRevisions() throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let details = try plan(store, IngestionGenerationSQL.pruneStaleVectorsSQL, [1])
        XCTAssertFalse(details.contains { $0.hasPrefix("SCAN") }, details.joined(separator: "\n"))
        XCTAssertFalse(details.contains { $0.contains("idx_chunks_source") },
                       "every chunk of every manifest source would be read per batch:\n" + details.joined(separator: "\n"))
        XCTAssertTrue(details.contains { $0.contains("idx_chunks_revision_ord") }, details.joined(separator: "\n"))
    }

    func testPruneStaleVectorsKeepsManifestRevisionAndDropsEveryOtherOne() throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "prune").id)
        let source = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: "doc", uri: nil, rawPath: nil).id)
        let other = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: "other", uri: nil, rawPath: nil).id)
        let old = try store.commitForegroundRevision(sourceId: source, draft: RevisionDraft(contentHash: "a", canonicalText: "old text",
            textFormatVersion: 1, chunkerVersion: 2), chunks: ScalarChunker.chunk("old text"), now: 0, leaseToken: "one")
        let kept = try store.commitForegroundRevision(sourceId: other, draft: RevisionDraft(contentHash: "b", canonicalText: "kept",
            textFormatVersion: 1, chunkerVersion: 2), chunks: ScalarChunker.chunk("kept"), now: 0, leaseToken: "two")
        let generation = try store.createGeneration(notebookId: notebook, identity: identity, now: 0)
        let oldChunk = try XCTUnwrap(store.chunks(sourceId: source).first?.id)
        let keptChunk = try XCTUnwrap(store.chunks(sourceId: other).first?.id)
        try store.storeGenerationEmbedding(generationId: generation.id, chunkId: oldChunk, vector: EmbeddingVector(values: [1, 0]))
        try store.storeGenerationEmbedding(generationId: generation.id, chunkId: keptChunk, vector: EmbeddingVector(values: [0, 1]))
        let new = try store.commitForegroundRevision(sourceId: source, draft: RevisionDraft(contentHash: "c", canonicalText: "new text",
            textFormatVersion: 1, chunkerVersion: 2), chunks: ScalarChunker.chunk("new text"), now: 1, leaseToken: "three")
        XCTAssertNotEqual(new.id, old.id)
        let newChunk = try XCTUnwrap(store.chunks(sourceId: source).first?.id)
        // A revision-less (legacy) chunk of a manifest source never keeps a vector either.
        let legacyChunk = try store.runOnDatabase { db -> Int64 in
            try db.execute(sql: "INSERT INTO source_chunks(source_id,ord,text,token_count) VALUES (?,99,'legacy',1)", arguments: [source])
            let id = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES (?,?,?)",
                           arguments: [id, generation.id, EmbeddingVector(values: [1, 0]).asData()])
            return id
        }
        try store.settleGeneration(generationId: generation.id)
        XCTAssertEqual(try store.manifest(generationId: generation.id).first { $0.sourceId == source }?.revisionId, new.id)
        try store.storeGenerationEmbedding(generationId: generation.id, chunkId: newChunk, vector: EmbeddingVector(values: [1, 0]))
        try store.settleGeneration(generationId: generation.id)
        let remaining = try store.runOnDatabase {
            try Int64.fetchAll($0, sql: "SELECT chunk_id FROM chunk_embeddings WHERE generation_id=? ORDER BY chunk_id", arguments: [generation.id])
        }
        XCTAssertEqual(remaining, [keptChunk, newChunk].sorted(), "old-revision and revision-less vectors pruned")
        XCTAssertFalse(remaining.contains(oldChunk) || remaining.contains(legacyChunk))
        XCTAssertEqual(kept.sourceId, other)
    }

    func testSettlingAnUnchangedBuildWritesNothing() throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "settle").id)
        var sources: [Int64] = []
        for title in ["a", "b", "c"] {
            let source = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: title, uri: nil, rawPath: nil).id)
            _ = try store.commitForegroundRevision(sourceId: source, draft: RevisionDraft(contentHash: title, canonicalText: "text " + title,
                textFormatVersion: 1, chunkerVersion: 2), chunks: ScalarChunker.chunk("text " + title), now: 0, leaseToken: title)
            sources.append(source)
        }
        let generation = try store.createGeneration(notebookId: notebook, identity: identity, now: 0)
        try store.runOnDatabase { db in
            try db.execute(sql: "UPDATE sources SET availability='missing' WHERE id=?", arguments: [sources[1]])
            try db.execute(sql: "UPDATE sources SET eligible=0 WHERE id=?", arguments: [sources[2]])
        }
        try store.settleGeneration(generationId: generation.id)
        XCTAssertEqual(try store.manifest(generationId: generation.id).map(\.state), ["pending", "excluded", "excluded"])
        XCTAssertEqual(try store.manifest(generationId: generation.id).map(\.reason), [nil, "missing", "ineligible"])
        let before = try store.runOnDatabase { $0.totalChangesCount }
        try store.settleGeneration(generationId: generation.id)
        XCTAssertEqual(try store.runOnDatabase { $0.totalChangesCount }, before, "a settled manifest is not rewritten per batch")
        // A returning source becomes pending again.
        try store.runOnDatabase { try $0.execute(sql: "UPDATE sources SET availability='present' WHERE id=?", arguments: [sources[1]]) }
        try store.settleGeneration(generationId: generation.id)
        XCTAssertEqual(try store.manifest(generationId: generation.id).map(\.state), ["pending", "pending", "excluded"])
    }

    /// A build round resumes after its keyset cursor on the manifest primary key and reaches
    /// chunks only through `idx_chunks_revision_ord` with the spreadsheet cap as a range bound.
    func testRoundCandidatesUseKeysetAndNeverSort() throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let details = try plan(store, IngestionGenerationSQL.candidatesSQL, [1, 0, 0, -1, 64])
        let text = details.joined(separator: "\n")
        XCTAssertFalse(details.contains { $0.hasPrefix("SCAN") }, text)
        XCTAssertFalse(details.contains { $0.contains("TEMP B-TREE") }, "a round must not sort every pending chunk:\n" + text)
        XCTAssertTrue(details.contains { $0.contains("index_generation_manifest") && $0.contains("source_id>") }, text)
        XCTAssertTrue(details.contains { $0.contains("idx_chunks_revision_ord") && $0.contains("ord<") }, text)
    }

    /// Dedup lookups probe the ledger by (generation, hash), then verify by primary keys.
    func testExistingVectorLookupUsesTheHashIndex() throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let details = try plan(store, IngestionGenerationSQL.existingVectorSQL, [1, "h", "t"])
        let text = details.joined(separator: "\n")
        XCTAssertFalse(details.contains { $0.hasPrefix("SCAN") }, text)
        XCTAssertTrue(details.contains { $0.contains("idx_generation_text_hashes_hash") }, text)
    }

    /// The status strip re-reads progress every second while indexing runs (on the
    /// main actor): counting must stay inside indexes, never read chunk rows.
    func testChunkProgressCountsFromIndexesOnly() throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let details = try plan(store, IndexingStatusSQL.chunkProgressSQL, [1])
        XCTAssertFalse(details.contains { $0.hasPrefix("SCAN") }, details.joined(separator: "\n"))
        XCTAssertTrue(details.contains { $0.contains("COVERING INDEX idx_chunks_revision_ord") },
                      "chunk rows (with their text) would be read per status refresh:\n" + details.joined(separator: "\n"))
    }
}

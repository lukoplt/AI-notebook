import XCTest
import GRDB
@testable import AINotebookCore

private struct NoQueryEmbedding: EmbeddingProducing {
    func embed(model: String, inputs: [String]) async throws -> [[Float]] { throw CancellationError() }
}

/// retrieval-resident-v1: one resident binary16 matrix per generation, loaded per pinned
/// (source, revision) pair, kept across unrelated writes, extended incrementally.
@MainActor final class ResidentVectorMatrixTests: XCTestCase {
    private func vectorIds(_ store: NotebookStore, _ retriever: Retriever, notebookId: Int64,
                           _ query: [Float], k: Int = 4) async throws -> (ids: [Int64], streamed: Bool) {
        let snapshot = try XCTUnwrap(ScopeResolver.resolve(store: store, notebookId: notebookId, scope: .all, modelKey: "synthetic"))
        let pool = try await retriever.searchEmbedded(snapshot: snapshot, query: "", queryVector: query, fetchK: k)
        defer { Task { await pool.close() } }
        XCTAssertEqual(pool.diagnostics.vectorStatus, "used")
        return (pool.vector.map(\.reference.chunkId), pool.diagnostics.streamed)
    }

    func testIncrementalLoadsSurviveUnrelatedWritesAndRevisionChanges() async throws {
        let store = try NotebookStore(path: .inMemory)
        let handle = try SyntheticRetrievalCorpus.populate(store: store, chunkCount: 300, dims: 16)
        let cache = VectorMatrixCache()
        let retriever = Retriever(store: store, client: NoQueryEmbedding(), modelKey: { "synthetic" }, cache: cache)
        let probe = SyntheticRetrievalCorpus.row(index: 5, dims: 16).vector
        // Off-axis query: one-hot corpus rows tie below it, rows stored along it score highest.
        var tilted = probe
        tilted[(probe.firstIndex(of: 1)! + 1) % 16] = 0.5
        let key = { (instance: String) in ResidentMatrixKey(databaseId: store.generationDatabaseIdentity, databaseInstance: instance, notebookId: handle.notebookId,
                                                            generationId: handle.generationId, dims: 16) }
        let instance = store.makeRetrievalReader().databaseInstance

        let first = try await vectorIds(store, retriever, notebookId: handle.notebookId, probe)
        XCTAssertFalse(first.streamed)
        XCTAssertEqual(first.ids.count, 4)
        var stats = await cache.statistics()
        XCTAssertEqual(stats.loadCount, 1)
        XCTAssertEqual(stats.residentBytes, 300 * (16 * 2 + 32))
        let rowsAfterFirst = await cache.residentRowCount(key(instance))
        XCTAssertEqual(rowsAfterFirst, 300)

        // Writes that do not change any pinned pair keep the matrix: no reload.
        _ = try store.createNotebook(name: "unrelated")
        try store.runOnDatabase { db in try db.execute(sql: "UPDATE notebooks SET name='renamed' WHERE id=?", arguments: [handle.notebookId]) }
        let second = try await vectorIds(store, retriever, notebookId: handle.notebookId, probe)
        XCTAssertEqual(second.ids, first.ids)
        stats = await cache.statistics()
        XCTAssertEqual(stats.loadCount, 1, "an unrelated write must not refill the matrix")

        // A new published revision of the first source: only that pair loads; its old rows
        // become garbage and are never returned again.
        let firstSource = try store.runOnDatabase { db in
            try Int64.fetchOne(db, sql: "SELECT min(id) FROM sources WHERE notebook_id=?", arguments: [handle.notebookId])!
        }
        let oldIds = try store.runOnDatabase { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM source_chunks WHERE source_id=?", arguments: [firstSource])
        }
        let newIds: [Int64] = try store.runOnDatabase { db in
            let texts = ["fresh one", "fresh two", "fresh 333"]
            let revision = try RevisionJobSQL.commitForegroundRevision(db, sourceId: firstSource,
                draft: RevisionDraft(contentHash: "fresh", canonicalText: texts.joined(separator: "\n"), textFormatVersion: 1, chunkerVersion: 2),
                chunks: texts.enumerated().map { RevisionChunkDraft(text: $1, tokenCount: 2, pageHint: nil, charStart: $0 * 10,
                                                                    charEnd: $0 * 10 + 9, lang: nil, langInherited: false) },
                now: 1, leaseToken: "resident-test")
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM source_chunks WHERE revision_id=? ORDER BY ord", arguments: [revision.id])
            // An active generation's incremental update, written directly as the shared fixtures do.
            for id in ids {
                try db.execute(sql: "INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES (?,?,?)",
                               arguments: [id, handle.generationId, EmbeddingVector(values: tilted).asData()])
            }
            try db.execute(sql: "UPDATE index_generation_manifest SET revision_id=?,state='done' WHERE generation_id=? AND source_id=?",
                           arguments: [revision.id, handle.generationId, firstSource])
            return ids
        }
        let third = try await vectorIds(store, retriever, notebookId: handle.notebookId, tilted, k: 8)
        XCTAssertEqual(Array(third.ids.prefix(3)), newIds)
        XCTAssertTrue(Set(third.ids).isDisjoint(with: oldIds), "superseded revision rows are never scored")
        stats = await cache.statistics()
        XCTAssertEqual(stats.loadCount, 2)
        let rowsAfterThird = await cache.residentRowCount(key(instance))
        XCTAssertEqual(rowsAfterThird, 303)

        // Over budget: the same answer streams.
        let tiny = Retriever(store: store, client: NoQueryEmbedding(), modelKey: { "synthetic" }, cache: VectorMatrixCache(budgetBytes: 1_000))
        let streamed = try await vectorIds(store, tiny, notebookId: handle.notebookId, tilted, k: 8)
        XCTAssertTrue(streamed.streamed)
        XCTAssertEqual(streamed.ids, third.ids)
    }

    func testBudgetScalesWithPhysicalMemory() {
        XCTAssertEqual(VectorMatrixCache.residentBudget(physicalMemory: 8 << 30), RagContractV1.Cache.globalBudgetBytes)
        XCTAssertEqual(VectorMatrixCache.residentBudget(physicalMemory: 16 << 30), 1 << 30)
        XCTAssertEqual(VectorMatrixCache.residentBudget(physicalMemory: 64 << 30), 1 << 30)
        XCTAssertEqual(VectorMatrixCache.residentBudget(physicalMemory: 0), RagContractV1.Cache.globalBudgetBytes)
    }
}

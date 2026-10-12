import Foundation
import GRDB

/// One deterministic synthetic row (shared `retrieval-perf-v1` oracle).
public struct SyntheticRetrievalChunk: Sendable {
    public let chunkId: Int64; public let sourceId: Int64; public let ord: Int
    public let text: String; public let vector: [Float]

    public init(chunkId: Int64, sourceId: Int64, ord: Int, text: String, vector: [Float]) {
        self.chunkId = chunkId; self.sourceId = sourceId; self.ord = ord
        self.text = text; self.vector = vector
    }
}

/// Actual database identities of a populated benchmark notebook. Fixture
/// logical row IDs are independent of unrelated existing notebook IDs.
public struct SyntheticRetrievalHandle: Sendable {
    public let notebookId: Int64; public let generationId: Int64
    public let chunkCount: Int; public let dims: Int

    public init(notebookId: Int64, generationId: Int64, chunkCount: Int, dims: Int) {
        self.notebookId = notebookId; self.generationId = generationId
        self.chunkCount = chunkCount; self.dims = dims
    }
}

public enum SyntheticRetrievalCorpus {
    static let chunksPerSource = 100
    /// Ten sources of 100 rows keeps each embedding transaction at ≤1024 rows.
    static let sourcesPerTransaction = 10

    public static func row(index: Int, dims: Int, seed: Int = 17) -> SyntheticRetrievalChunk {
        precondition(index >= 0 && dims > 0 && seed >= 0)
        var vector = [Float](repeating: 0, count: dims)
        vector[(index % dims + seed % dims) % dims] = 1
        return SyntheticRetrievalChunk(chunkId: Int64(index + 1), sourceId: Int64(1 + index / chunksPerSource),
            ord: index % chunksPerSource, text: "synthetic \(index) needle\(index % 97)", vector: vector)
    }

    /// Populates a fresh benchmark notebook: 100 chunks per source, one published
    /// chunker-v2 revision each, and one legacy generation (`synthetic`) that is
    /// activated only after every source is complete. At most one transaction's
    /// rows are generated in memory; the whole corpus is never materialized.
    @MainActor public static func populate(store: NotebookStore, chunkCount: Int,
        dims: Int, seed: Int = 17) throws -> SyntheticRetrievalHandle {
        guard chunkCount > 0, seed >= 0, RetrievalSQL.byteWidth(dims: dims) != nil else {
            throw RetrievalError.invalidMeasurementInput
        }
        let notebookId = try requireNotebookId(store.createNotebook(name: "Synthetic retrieval \(chunkCount)x\(dims)"))
        let identity = GenerationIdentity(providerId: "legacy", endpointRevision: "legacy", model: "synthetic",
            modelDigest: nil, dims: dims, normalization: "legacy", queryFormatVersion: "legacy",
            docFormatVersion: "legacy", chunkerVersion: "legacy")
        let generationId = try store.runOnDatabase { db in
            try GenerationSQL.create(db, notebookId: notebookId, identity: identity, now: 0).id
        }
        var next = 0
        while next < chunkCount {
            try store.runOnDatabase { db in
                for _ in 0..<sourcesPerTransaction where next < chunkCount {
                    let end = min(chunkCount, (next / chunksPerSource + 1) * chunksPerSource)
                    try insertSource(db, notebookId: notebookId, generationId: generationId,
                                     rows: (next..<end).map { row(index: $0, dims: dims, seed: seed) },
                                     seed: seed, dims: dims)
                    next = end
                }
            }
        }
        try store.runOnDatabase { db in try GenerationSQL.activate(db, id: generationId, fence: nil, now: 0) }
        return SyntheticRetrievalHandle(notebookId: notebookId, generationId: generationId,
                                        chunkCount: chunkCount, dims: dims)
    }

    private static func requireNotebookId(_ notebook: Notebook) throws -> Int64 {
        guard let id = notebook.id else { throw RetrievalError.invalidMeasurementInput }
        return id
    }

    /// One source: LF-joined canonical text with scalar spans computed while
    /// appending, a published revision, done manifest and its one-hot vectors.
    private static func insertSource(_ db: Database, notebookId: Int64, generationId: Int64,
                                     rows: [SyntheticRetrievalChunk], seed: Int, dims: Int) throws {
        guard let logicalSource = rows.first?.sourceId else { return }
        var text = "", offset = 0
        var drafts: [RevisionChunkDraft] = []
        drafts.reserveCapacity(rows.count)
        for row in rows {
            if !text.isEmpty { text += "\n"; offset += 1 }
            let length = row.text.unicodeScalars.count
            drafts.append(RevisionChunkDraft(text: row.text, tokenCount: 3, pageHint: nil,
                charStart: offset, charEnd: offset + length, lang: nil, langInherited: false))
            text += row.text
            offset += length
        }
        var source = Source(notebookId: notebookId, type: .text, title: "Synthetic source \(logicalSource)",
            uri: nil, rawPath: nil, status: .pending, error: nil, ingestedAt: Date(timeIntervalSince1970: 0))
        try source.insert(db)
        guard let sourceId = source.id else { throw RetrievalError.invalidMeasurementInput }
        let revision = try RevisionJobSQL.commitForegroundRevision(db, sourceId: sourceId,
            draft: RevisionDraft(contentHash: "synthetic-\(seed)-\(dims)-\(logicalSource)", canonicalText: text,
                                 textFormatVersion: 1, chunkerVersion: 2),
            chunks: drafts, now: 0, leaseToken: "synthetic-benchmark")
        try GenerationSQL.setManifest(db, generationId: generationId, entries: [
            ManifestEntry(sourceId: sourceId, revisionId: revision.id, state: "pending", reason: nil)])
        let chunkIds = try Int64.fetchAll(db, sql: "SELECT id FROM source_chunks WHERE revision_id=? ORDER BY ord",
                                          arguments: [revision.id])
        guard chunkIds.count == rows.count else { throw RetrievalError.invalidMeasurementInput }
        for (chunkId, row) in zip(chunkIds, rows) {
            // One-hot rows are already unit length.
            try GenerationSQL.storeEmbedding(db, generationId: generationId, chunkId: chunkId,
                                             vector: EmbeddingVector(values: row.vector))
        }
        try GenerationSQL.setManifest(db, generationId: generationId, entries: [
            ManifestEntry(sourceId: sourceId, revisionId: revision.id, state: "done", reason: nil)])
    }
}

public struct RetrievalPerformanceSample: Sendable {
    public let queryEmbeddingMs: Double
    public let warmRetrievalMs: Double
    public let hydrationMs: Double
    /// Reported separately; warm-retrieval percentiles never include embedding.
    public var endToEndMs: Double { queryEmbeddingMs + warmRetrievalMs + hydrationMs }

    public init(queryEmbeddingMs: Double, warmRetrievalMs: Double, hydrationMs: Double) {
        self.queryEmbeddingMs = queryEmbeddingMs
        self.warmRetrievalMs = warmRetrievalMs
        self.hydrationMs = hydrationMs
    }
}

/// Post-embedding timing hooks for WP7. Unit tests use a fake monotonic clock;
/// the Mac harness passes `DispatchTime.now().uptimeNanoseconds` with
/// `ticksPerSecond` 1_000_000_000. No latency target is asserted here.
public enum RetrievalPerformance {
    /// Owns `snapshot` from entry: the pool and snapshot are closed on success
    /// and on every failure, including a throwing embedding closure.
    @MainActor public static func measure(snapshot: ResolvedRetrievalScope,
        embedding: () async throws -> [Float],
        retrieval: ([Float]) async throws -> PinnedRetrievalCandidates,
        hydration: (PinnedRetrievalCandidates) async throws -> Void,
        ticksPerSecond: UInt64, now: () -> UInt64) async throws -> RetrievalPerformanceSample {
        var pool: PinnedRetrievalCandidates?
        do {
            guard ticksPerSecond > 0 else { throw RetrievalError.invalidMeasurementInput }
            let t0=now(), vector=try await embedding(), t1=now()
            let result=try await retrieval(vector); pool=result
            let t2=now()
            try await hydration(result)
            let t3=now()
            guard t0<=t1 && t1<=t2 && t2<=t3 else { throw RetrievalError.invalidMeasurementInput }
            let frequency = Double(ticksPerSecond)
            let sample=RetrievalPerformanceSample(queryEmbeddingMs:Double(t1-t0)*1000/frequency,
                warmRetrievalMs:Double(t2-t1)*1000/frequency,
                hydrationMs:Double(t3-t2)*1000/frequency)
            await result.close(); await snapshot.close()
            return sample
        } catch {
            await pool?.close(); await snapshot.close()
            throw error
        }
    }

    /// Nearest-rank p95: sorted index `ceil(0.95*n)-1`. Requires samples.
    public static func percentile95(_ samples: [Double]) -> Double {
        precondition(!samples.isEmpty, "percentile95 requires at least one sample")
        let sorted = samples.sorted()
        let index = Int((0.95 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[max(0, index)]
    }
}

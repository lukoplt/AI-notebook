import Foundation
import GRDB

public actor Retriever {
    private let store: NotebookStore
    private let client: EmbeddingProducing
    private let modelKey: @Sendable () -> String
    public let rrfK: Int

    /// `modelKey` is read at the start of every `search`, so a provider/model
    /// switch in Settings applies to the next query without rebuilding the
    /// retriever (fixes the pre-registry staleness bug).
    public init(
        store: NotebookStore,
        client: EmbeddingProducing,
        modelKey: @escaping @Sendable () -> String,
        rrfK: Int = 60
    ) {
        self.store = store
        self.client = client
        self.modelKey = modelKey
        self.rrfK = rrfK
    }

    /// Convenience for a fixed key (tests, single-provider setups).
    public init(
        store: NotebookStore,
        client: EmbeddingProducing,
        model: String,
        rrfK: Int = 60
    ) {
        self.init(store: store, client: client, modelKey: { model }, rrfK: rrfK)
    }

    /// Hybrid retrieval: cosine top-K on vectors + FTS5 BM25 top-K → RRF.
    ///
    /// When `sourceIds` is non-empty, both branches are restricted to chunks in
    /// those sources; an empty set (the default) means no filter.
    public func search(
        notebookId: Int64,
        query: String,
        topK: Int = 8,
        sourceIds: Set<Int64> = []
    ) async throws -> [RetrievalHit] {
        // 1) Vector ranking — embed query, score against stored vectors.
        let key = modelKey()
        let queryVectors = try await client.embed(model: key, inputs: [query])
        let queryVector = queryVectors.first ?? []
        let storeRef = store
        let modelRef = key
        let allEmbeddings = try await MainActor.run {
            try storeRef.embeddings(notebookId: notebookId, model: modelRef)
        }
        let candidateEmbeddings = sourceIds.isEmpty
            ? allEmbeddings
            : allEmbeddings.filter { sourceIds.contains($0.sourceId) }
        let scored: [(chunkId: Int64, sourceId: Int64, score: Float)] =
            candidateEmbeddings.map { e in
                (
                    chunkId: e.chunkId,
                    sourceId: e.sourceId,
                    score: Cosine.similarity(queryVector, e.vector.values)
                )
            }
        let vectorRanked: [(chunkId: Int64, sourceId: Int64, score: Float)] =
            Array(scored.sorted { $0.score > $1.score }.prefix(topK))

        // 2) FTS ranking — BM25 top-K on chunks_fts within the notebook.
        let queryRef = query
        let topKRef = topK
        let sourceIdsRef = sourceIds
        let ftsRanked = try await MainActor.run {
            try Self.ftsTopK(
                store: storeRef,
                notebookId: notebookId,
                query: queryRef,
                k: topKRef,
                sourceIds: sourceIdsRef
            )
        }

        // 3) Reciprocal Rank Fusion.
        var rrfScores: [Int64: Float] = [:]
        var meta: [Int64: (sourceId: Int64, snippet: String)] = [:]
        for (rank, hit) in vectorRanked.enumerated() {
            rrfScores[hit.chunkId, default: 0] += 1.0 / Float(rrfK + rank + 1)
            meta[hit.chunkId] = (hit.sourceId, "")
        }
        for (rank, hit) in ftsRanked.enumerated() {
            rrfScores[hit.chunkId, default: 0] += 1.0 / Float(rrfK + rank + 1)
            meta[hit.chunkId] = (hit.sourceId, hit.snippet)
        }

        // 4) Hydrate snippets for chunks that only came from the vector branch.
        let missingSnippets = meta.compactMap { (id, m) in m.snippet.isEmpty ? id : nil }
        if !missingSnippets.isEmpty {
            let snippets = try await MainActor.run {
                try Self.snippets(store: storeRef, chunkIds: missingSnippets)
            }
            for (id, snippet) in snippets {
                meta[id] = (meta[id]?.sourceId ?? 0, snippet)
            }
        }

        return rrfScores
            .sorted { $0.value > $1.value }
            .prefix(topK)
            .compactMap { (id, score) in
                guard let m = meta[id] else { return nil }
                return RetrievalHit(chunkId: id, sourceId: m.sourceId, score: score, snippet: m.snippet)
            }
    }

    // MARK: - Internal SQL helpers

    @MainActor
    private static func ftsTopK(
        store: NotebookStore,
        notebookId: Int64,
        query: String,
        k: Int,
        sourceIds: Set<Int64>
    ) throws -> [(chunkId: Int64, sourceId: Int64, snippet: String)] {
        try store.runOnDatabase { db in
            var arguments: [DatabaseValueConvertible] = [Self.escapeFTS(query), notebookId]
            var sourceFilter = ""
            if !sourceIds.isEmpty {
                let placeholders = sourceIds.map { _ in "?" }.joined(separator: ",")
                sourceFilter = "AND sc.source_id IN (\(placeholders))"
                arguments.append(contentsOf: sourceIds.map { $0 as DatabaseValueConvertible })
            }
            arguments.append(k)
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT sc.id AS chunk_id, sc.source_id AS source_id, sc.text AS text
                FROM chunks_fts f
                JOIN source_chunks sc ON sc.id = f.chunk_id
                JOIN sources s ON s.id = sc.source_id
                WHERE f.text MATCH ? AND s.notebook_id = ? \(sourceFilter)
                ORDER BY bm25(chunks_fts)
                LIMIT ?
                """,
                arguments: StatementArguments(arguments)
            )
            return rows.map { r in
                let text: String = r["text"]
                return (
                    chunkId: r["chunk_id"],
                    sourceId: r["source_id"],
                    snippet: String(text.prefix(240))
                )
            }
        }
    }

    @MainActor
    private static func snippets(
        store: NotebookStore,
        chunkIds: [Int64]
    ) throws -> [Int64: String] {
        guard !chunkIds.isEmpty else { return [:] }
        return try store.runOnDatabase { db in
            let placeholders = chunkIds.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, text FROM source_chunks WHERE id IN (\(placeholders))",
                arguments: StatementArguments(chunkIds)
            )
            var out: [Int64: String] = [:]
            for r in rows {
                let text: String = r["text"]
                out[r["id"]] = String(text.prefix(240))
            }
            return out
        }
    }

    /// Defensive escaping of double quotes for the FTS5 `MATCH` operator.
    /// We wrap the whole query in double quotes so it's treated as a phrase
    /// search and special characters can't break the parser.
    private static func escapeFTS(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

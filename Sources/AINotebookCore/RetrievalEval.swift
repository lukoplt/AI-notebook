import Foundation

/// Epic D2: a tiny retrieval-quality harness. Given a set of queries each
/// annotated with the chunk ids that *should* be retrieved ("gold"), it runs
/// the real hybrid retriever and reports recall@k. Intended to be run locally
/// (never in CI) to decide whether contextual enrichment (D1) or a reranker
/// (D3) actually improve retrieval before enabling them by default.
public struct EvalQuery: Sendable {
    public let text: String
    public let goldChunkIds: Set<Int64>
    public init(text: String, goldChunkIds: Set<Int64>) {
        self.text = text
        self.goldChunkIds = goldChunkIds
    }
}

public struct EvalQueryReport: Sendable, Equatable {
    public let query: String
    /// Fraction of this query's gold chunks that appeared in the top-k.
    public let recall: Double
    /// Whether at least one gold chunk was retrieved.
    public let hit: Bool
}

public struct EvalReport: Sendable, Equatable {
    public let k: Int
    public let perQuery: [EvalQueryReport]
    /// Mean of per-query recall — the headline "recall@k" number.
    public let meanRecall: Double
    /// Fraction of queries with at least one gold chunk retrieved.
    public let hitRate: Double

    /// A one-line summary suitable for printing from a local eval script.
    public var summary: String {
        String(format: "recall@%d = %.3f  hitRate = %.3f  (%d queries)", k, meanRecall, hitRate, perQuery.count)
    }
}

public enum RetrievalEval {
    /// Runs every query through the hybrid retriever and aggregates recall@k.
    public static func run(
        retriever: Retriever,
        notebookId: Int64,
        queries: [EvalQuery],
        k: Int = 8
    ) async throws -> EvalReport {
        var reports: [EvalQueryReport] = []
        for q in queries {
            let hits = try await retriever.search(notebookId: notebookId, query: q.text, topK: k)
            let retrieved = Set(hits.map(\.chunkId))
            let found = q.goldChunkIds.intersection(retrieved)
            let recall = q.goldChunkIds.isEmpty ? 0 : Double(found.count) / Double(q.goldChunkIds.count)
            reports.append(EvalQueryReport(query: q.text, recall: recall, hit: !found.isEmpty))
        }
        let meanRecall = reports.isEmpty ? 0 : reports.map(\.recall).reduce(0, +) / Double(reports.count)
        let hitRate = reports.isEmpty ? 0 : Double(reports.filter(\.hit).count) / Double(reports.count)
        return EvalReport(k: k, perQuery: reports, meanRecall: meanRecall, hitRate: hitRate)
    }
}

public struct EvalEvidence: Sendable, Equatable {
    public let chunkId: Int64
    public let span: EvalSpan
    public let text: String

    public init(chunkId: Int64, span: EvalSpan, text: String) {
        self.chunkId = chunkId
        self.span = span
        self.text = text
    }
}

/// WP8 supplies retained ranges, including the actual end of a truncated prefix.
/// Nil hook means unavailable; an empty returned array is a measured empty pack.
public typealias EvalPackHook = @Sendable (EvalQuestion, [EvalEvidence]) async throws -> [EvalSpan]

public struct EvalMetric: Codable, Equatable, Sendable {
    public let status: String
    public let found: Int?
    public let total: Int?
    public let recallBp: Int?

    public init(status: String, found: Int?, total: Int?, recallBp: Int?) {
        self.status = status
        self.found = found
        self.total = total
        self.recallBp = recallBp
    }

    public static let unavailable = EvalMetric(status: "not_available", found: nil, total: nil, recallBp: nil)
    public static let notApplicable = EvalMetric(status: "not_applicable", found: 0, total: 0, recallBp: nil)

    private enum CodingKeys: String, CodingKey { case status, found, total, recallBp = "recall_bp" }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(found, forKey: .found)
        try c.encode(total, forKey: .total)
        try c.encode(recallBp, forKey: .recallBp)
    }
}

public enum EvalMetrics {
    public static let names = ["lexical_recall_at_top_k", "lexical_recall_at_fetch_k", "hybrid_recall_at_top_k",
                               "candidate_recall_at_fetch_k", "packed_evidence_recall"]

    public static func recall(gold: [EvalSpan], evidence: [EvalSpan]) -> EvalMetric {
        guard !gold.isEmpty else { return .notApplicable }
        let found = gold.filter { g in
            evidence.contains { e in
                e.documentId == g.documentId && e.contentHash == g.contentHash
                    && e.start <= g.start && e.end >= g.end
            }
        }.count
        return EvalMetric(status: "measured", found: found, total: gold.count, recallBp: 10000 * found / gold.count)
    }

    /// Micro recall pools gold items, excluding queries without a denominator.
    public static func aggregate(_ metrics: [EvalMetric]) -> EvalMetric {
        let measured = metrics.filter { $0.status == "measured" }
        let found = measured.reduce(0) { $0 + ($1.found ?? 0) }
        let total = measured.reduce(0) { $0 + ($1.total ?? 0) }
        if total > 0 { return EvalMetric(status: "measured", found: found, total: total, recallBp: 10000 * found / total) }
        return metrics.contains { $0.status == "not_available" } ? .unavailable : .notApplicable
    }

    public static func measure(gold: [EvalSpan], lexical: [EvalSpan], fused: [EvalSpan],
                               topK: Int, includeVectors: Bool, packed: [EvalSpan]?) throws -> [String: EvalMetric] {
        guard topK > 0 else { throw EvalFailure("invalid_top_k") }
        return [
            "lexical_recall_at_top_k": recall(gold: gold, evidence: Array(lexical.prefix(topK))),
            "lexical_recall_at_fetch_k": recall(gold: gold, evidence: lexical),
            "hybrid_recall_at_top_k": includeVectors ? recall(gold: gold, evidence: Array(fused.prefix(topK))) : .unavailable,
            "candidate_recall_at_fetch_k": recall(gold: gold, evidence: fused),
            "packed_evidence_recall": packed.map { recall(gold: gold, evidence: $0) } ?? .unavailable
        ]
    }
}

import Foundation

public struct EvalQueryRow: Codable, Sendable {
    public let queryId: String
    public let text: String
    public let language: String
    public let caseType: String
    public let status: String
    public let filesInScope: Int
    public let candidatesWithChunks: Int
    public let lexical: [EvalSpan]
    public let vector: [EvalSpan]
    public let fused: [EvalSpan]
    public let metrics: [String: EvalMetric]

    public init(queryId: String,
                text: String,
                language: String,
                caseType: String,
                status: String,
                filesInScope: Int,
                candidatesWithChunks: Int,
                lexical: [EvalSpan],
                vector: [EvalSpan],
                fused: [EvalSpan],
                metrics: [String: EvalMetric]) {
        self.queryId = queryId
        self.text = text
        self.language = language
        self.caseType = caseType
        self.status = status
        self.filesInScope = filesInScope
        self.candidatesWithChunks = candidatesWithChunks
        self.lexical = lexical
        self.vector = vector
        self.fused = fused
        self.metrics = metrics
    }

    private enum CodingKeys: String, CodingKey {
        case queryId = "query_id"
        case text = "text"
        case language = "language"
        case caseType = "case_type"
        case status = "status"
        case filesInScope = "files_in_scope"
        case candidatesWithChunks = "candidates_with_chunks"
        case lexical = "lexical"
        case vector = "vector"
        case fused = "fused"
        case metrics = "metrics"
    }
}

public struct EvalReportV1: Codable, Sendable {
    public let schemaVersion: Int
    public let corpusId: String
    public let corpusHash: String
    public let platform: String
    public let retrievalVersion: String
    public let chunkerVersion: String
    public let mode: String
    public let model: String?
    public let dimensions: Int?
    public let topK: Int
    public let fetchK: Int
    public let documents: Int
    public let queriesTotal: Int
    public let overviewQueries: Int
    public let absentQueries: Int
    public let emptySelectionQueries: Int
    public let metrics: [String: EvalMetric]
    public let byLanguage: [String: [String: EvalMetric]]
    public let byCaseType: [String: [String: EvalMetric]]
    public let queries: [EvalQueryRow]
    public let capabilities: [String: String]
    public let timing: [String: Int?]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case corpusId = "corpus_id"
        case corpusHash = "corpus_hash"
        case platform = "platform"
        case retrievalVersion = "retrieval_version"
        case chunkerVersion = "chunker_version"
        case mode = "mode"
        case model = "model"
        case dimensions = "dimensions"
        case topK = "top_k"
        case fetchK = "fetch_k"
        case documents = "documents"
        case queriesTotal = "queries_total"
        case overviewQueries = "overview_queries"
        case absentQueries = "absent_queries"
        case emptySelectionQueries = "empty_selection_queries"
        case metrics = "metrics"
        case byLanguage = "by_language"
        case byCaseType = "by_case_type"
        case queries = "queries"
        case capabilities = "capabilities"
        case timing = "timing"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(corpusId, forKey: .corpusId)
        try c.encode(corpusHash, forKey: .corpusHash)
        try c.encode(platform, forKey: .platform)
        try c.encode(retrievalVersion, forKey: .retrievalVersion)
        try c.encode(chunkerVersion, forKey: .chunkerVersion)
        try c.encode(mode, forKey: .mode)
        try c.encode(model, forKey: .model)
        try c.encode(dimensions, forKey: .dimensions)
        try c.encode(topK, forKey: .topK)
        try c.encode(fetchK, forKey: .fetchK)
        try c.encode(documents, forKey: .documents)
        try c.encode(queriesTotal, forKey: .queriesTotal)
        try c.encode(overviewQueries, forKey: .overviewQueries)
        try c.encode(absentQueries, forKey: .absentQueries)
        try c.encode(emptySelectionQueries, forKey: .emptySelectionQueries)
        try c.encode(metrics, forKey: .metrics)
        try c.encode(byLanguage, forKey: .byLanguage)
        try c.encode(byCaseType, forKey: .byCaseType)
        try c.encode(queries, forKey: .queries)
        try c.encode(capabilities, forKey: .capabilities)
        try c.encode(timing, forKey: .timing)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data([0x0a])
    }

    public static func assemble(corpus: EvalCorpus, corpusHash: String, platform: String,
                                mode: String, model: String?, dimensions: Int?, topK: Int, fetchK: Int,
                                rows: [EvalQueryRow], hasPackingHook: Bool) -> EvalReportV1 {
        func aggregate(_ rows: [EvalQueryRow]) -> [String: EvalMetric] {
            let measured = rows.filter { $0.status == "measured" && $0.caseType != "overview" }
            return Dictionary(uniqueKeysWithValues: EvalMetrics.names.map { name in
                (name, EvalMetrics.aggregate(measured.compactMap { $0.metrics[name] }))
            })
        }
        let byLanguage = Dictionary(grouping: rows, by: \.language).mapValues(aggregate)
        let byCaseType = Dictionary(grouping: rows, by: \.caseType).mapValues(aggregate)
        return EvalReportV1(schemaVersion: 1, corpusId: corpus.corpusId, corpusHash: corpusHash,
            platform: platform, retrievalVersion: "legacy-fts-eval-rrf-v1", chunkerVersion: "eval-scalars-v1",
            mode: mode, model: model, dimensions: dimensions, topK: topK, fetchK: fetchK,
            documents: corpus.documents.count, queriesTotal: corpus.questions.count,
            overviewQueries: rows.filter { $0.caseType == "overview" }.count,
            absentQueries: rows.filter { $0.caseType == "absent" }.count,
            emptySelectionQueries: rows.filter { $0.caseType == "empty_selection" }.count,
            metrics: aggregate(rows), byLanguage: byLanguage, byCaseType: byCaseType, queries: rows,
            capabilities: ["packed_evidence": hasPackingHook ? "measured" : "not_available", "overview": "not_available"],
            timing: ["warm_retrieval_ms": nil, "end_to_end_ms": nil, "cold_cache_ms": nil])
    }

    public func markdown() -> String {
        func number(_ value: Int?) -> String { value.map(String.init) ?? "—" }
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        var lines = [
            "# Multilingual retrieval eval v1", "",
            "Corpus: \(corpusId) (\(documents) documents, \(queriesTotal) queries)",
            "Backend: \(retrievalVersion); chunker: \(chunkerVersion); mode: \(mode)",
            "topK: \(topK); fetchK per branch: \(fetchK)",
            "Recall aggregation: micro (pooled gold evidence items).", "",
            "| metric | found | total | recall bp | status |",
            "|---|---:|---:|---:|---|"
        ]
        for name in EvalMetrics.names {
            let metric = metrics[name] ?? .unavailable
            lines.append("| \(name) | \(number(metric.found)) | \(number(metric.total)) | \(number(metric.recallBp)) | \(metric.status) |")
        }
        lines += ["", "| query | text | status | lexical bp | hybrid bp | candidate bp | packed bp |",
                  "|---|---|---|---:|---:|---:|---:|"]
        for row in queries {
            let cells = [escape(row.queryId), escape(row.text), escape(row.status)] +
                ["lexical_recall_at_top_k", "hybrid_recall_at_top_k", "candidate_recall_at_fetch_k", "packed_evidence_recall"]
                .map { number(row.metrics[$0]?.recallBp) }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        lines += ["", "Candidate recall uses the full union of the per-branch fetchK lists.",
                  "Unavailable packing/overview measurements are not scores; WP8 supplies those adapters."]
        return lines.joined(separator: "\n") + "\n"
    }
}

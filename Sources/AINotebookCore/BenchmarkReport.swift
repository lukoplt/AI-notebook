import Foundation

// MARK: - Math (benchmark-v1 §6.2)

public enum BenchmarkMath {
    public static let warmGateUs: Int64 = 300_000

    /// Nearest rank: `sorted[ceilDiv(n·bp, 10000) − 1]`.
    public static func percentile(_ samples: [Int64], bp: Int) throws -> Int64 {
        guard !samples.isEmpty, (1...10_000).contains(bp), samples.allSatisfy({ $0 >= 0 }) else {
            throw BenchmarkError(code: "invalidSamples")
        }
        return samples.sorted()[Int(TokenEstimatorV2.ceilDiv(Int64(samples.count) * Int64(bp), 10_000)) - 1]
    }

    public static func tokensPerSecondMilli(tokens: Int64, elapsedUs: Int64) throws -> Int64? {
        guard tokens >= 0, elapsedUs >= 0, tokens <= Int64.max / 1_000_000_000 else {
            throw BenchmarkError(code: "invalidSamples")
        }
        return elapsedUs == 0 ? nil : tokens * 1_000_000_000 / elapsedUs
    }

    /// Gated only for 100K chunks, non-concurrent, 200 queries; strict `< 300000`.
    public static func warmGate(chunks: Int, concurrent: Bool, queries: Int, p95Us: Int64) -> Bool? {
        guard chunks == 100_000, !concurrent, queries == 200 else { return nil }
        return p95Us < warmGateUs
    }

    /// CLI milliseconds → integer microseconds, ties away from zero.
    public static func microseconds(fromMilliseconds ms: Double) -> Int64 {
        let v = ms * 1000
        return Int64((abs(v) + 0.5).rounded(.down)) * (v >= 0 ? 1 : -1)
    }
}

// MARK: - Markdown/JSON helpers (benchmark-v1 §6.4)

public enum BenchmarkMarkdown {
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\r", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    public static func value(_ text: String?) -> String { text.map(escape) ?? "not measured" }
    public static func value(_ number: Int?) -> String { number.map { String($0) } ?? "not measured" }
    public static func value(_ number: Int64?) -> String { number.map { String($0) } ?? "not measured" }
    public static func value(_ flag: Bool?) -> String { flag.map { $0 ? "yes" : "no" } ?? "not measured" }

    public static func recall(_ metric: EvalMetric) -> String {
        guard let bp = metric.recallBp else { return "not measured" }
        return "\(bp / 100)." + pad(bp % 100, 2) + "%"
    }

    public static func milli(_ value: Int64?) -> String? {
        value.map { "\($0 / 1000)." + pad(Int($0 % 1000), 3) }
    }

    static func unit(_ value: String?, _ suffix: String) -> String { value.map { "\($0) \(suffix)" } ?? "not measured" }
    static func unit(_ value: Int64?, _ suffix: String) -> String { unit(value.map { String($0) }, suffix) }
    static func unit(_ value: Int?, _ suffix: String) -> String { unit(value.map { String($0) }, suffix) }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let s = String(value)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}

// MARK: - Report DTOs (benchmark-v1 §6.1)

public struct BenchmarkEnvironment: Codable, Equatable, Sendable {
    public let cpu: String?
    public let ramBytes: Int64?
    public let os: String?
    public let architecture: String?
    public let buildCommit: String?
    public let ollamaVersion: String?
    public let accelerator: String?

    public init(cpu: String?, ramBytes: Int64?, os: String?, architecture: String?, buildCommit: String?,
                ollamaVersion: String?, accelerator: String?) {
        self.cpu = cpu
        self.ramBytes = ramBytes
        self.os = os
        self.architecture = architecture
        self.buildCommit = buildCommit
        self.ollamaVersion = ollamaVersion
        self.accelerator = accelerator
    }

    private enum CodingKeys: String, CodingKey { case cpu, ramBytes, os, architecture, buildCommit, ollamaVersion, accelerator }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cpu, forKey: .cpu); try c.encode(ramBytes, forKey: .ramBytes); try c.encode(os, forKey: .os)
        try c.encode(architecture, forKey: .architecture); try c.encode(buildCommit, forKey: .buildCommit)
        try c.encode(ollamaVersion, forKey: .ollamaVersion); try c.encode(accelerator, forKey: .accelerator)
    }
}

public struct BenchmarkCorpus: Codable, Equatable, Sendable {
    public let id: String
    public let hash: String
    public let documents: Int
    public let queries: Int
    public let chunkerVersion: String

    public init(id: String, hash: String, documents: Int, queries: Int, chunkerVersion: String) {
        self.id = id
        self.hash = hash
        self.documents = documents
        self.queries = queries
        self.chunkerVersion = chunkerVersion
    }
}

public struct BenchmarkParameters: Codable, Equatable, Sendable {
    public let fetchK: Int
    public let topK: Int
    public let evidenceShareBp: Int
    public let runtimeContext: Int
    public let maxOutputTokens: Int
    public let seed: Int

    public init(fetchK: Int, topK: Int, evidenceShareBp: Int, runtimeContext: Int, maxOutputTokens: Int, seed: Int) {
        self.fetchK = fetchK
        self.topK = topK
        self.evidenceShareBp = evidenceShareBp
        self.runtimeContext = runtimeContext
        self.maxOutputTokens = maxOutputTokens
        self.seed = seed
    }
}

public struct BenchmarkChat: Codable, Equatable, Sendable {
    public let model: String
    public let modelDigest: String?
    public let tokenFamily: String?
    public let showTemplateSha256: String?

    public init(model: String, modelDigest: String?, tokenFamily: String?, showTemplateSha256: String?) {
        self.model = model
        self.modelDigest = modelDigest
        self.tokenFamily = tokenFamily
        self.showTemplateSha256 = showTemplateSha256
    }

    private enum CodingKeys: String, CodingKey { case model, modelDigest, tokenFamily, showTemplateSha256 }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model); try c.encode(modelDigest, forKey: .modelDigest)
        try c.encode(tokenFamily, forKey: .tokenFamily); try c.encode(showTemplateSha256, forKey: .showTemplateSha256)
    }
}

public struct BenchmarkIdentity: Codable, Equatable, Sendable {
    public let providerId: String
    public let endpointRevision: String
    public let model: String
    public let modelDigest: String?
    public let dims: Int
    public let normalization: String
    public let queryFormatVersion: String
    public let docFormatVersion: String
    public let chunkerVersion: String

    public init(providerId: String, endpointRevision: String, model: String, modelDigest: String?, dims: Int,
                normalization: String, queryFormatVersion: String, docFormatVersion: String, chunkerVersion: String) {
        self.providerId = providerId
        self.endpointRevision = endpointRevision
        self.model = model
        self.modelDigest = modelDigest
        self.dims = dims
        self.normalization = normalization
        self.queryFormatVersion = queryFormatVersion
        self.docFormatVersion = docFormatVersion
        self.chunkerVersion = chunkerVersion
    }

    public init(_ identity: GenerationIdentity) {
        self.init(providerId: identity.providerId, endpointRevision: identity.endpointRevision, model: identity.model,
                  modelDigest: identity.modelDigest, dims: identity.dims, normalization: identity.normalization,
                  queryFormatVersion: identity.queryFormatVersion, docFormatVersion: identity.docFormatVersion,
                  chunkerVersion: identity.chunkerVersion)
    }

    private enum CodingKeys: String, CodingKey {
        case providerId, endpointRevision, model, modelDigest, dims, normalization, queryFormatVersion
        case docFormatVersion, chunkerVersion
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(providerId, forKey: .providerId); try c.encode(endpointRevision, forKey: .endpointRevision)
        try c.encode(model, forKey: .model); try c.encode(modelDigest, forKey: .modelDigest)
        try c.encode(dims, forKey: .dims); try c.encode(normalization, forKey: .normalization)
        try c.encode(queryFormatVersion, forKey: .queryFormatVersion)
        try c.encode(docFormatVersion, forKey: .docFormatVersion); try c.encode(chunkerVersion, forKey: .chunkerVersion)
    }
}

public struct BenchmarkQueryTiming: Codable, Equatable, Sendable {
    public let embeddingUs: Int64
    public let retrievalUs: Int64
    public let hydrationUs: Int64
    public let endToEndUs: Int64

    public init(embeddingUs: Int64, retrievalUs: Int64, hydrationUs: Int64, endToEndUs: Int64) {
        self.embeddingUs = embeddingUs
        self.retrievalUs = retrievalUs
        self.hydrationUs = hydrationUs
        self.endToEndUs = endToEndUs
    }
}

public struct BenchmarkOverview: Codable, Equatable, Sendable {
    public let filesInScope: Int
    public let publishedCandidateFiles: Int
    public let filesIncluded: Int

    public init(filesInScope: Int, publishedCandidateFiles: Int, filesIncluded: Int) {
        self.filesInScope = filesInScope
        self.publishedCandidateFiles = publishedCandidateFiles
        self.filesIncluded = filesIncluded
    }
}

public struct BenchmarkQualityQuery: Codable, Sendable {
    public let eval: EvalQueryRow
    public let packed: [EvalSpan]
    public let citationMap: [Citation]
    public let answerText: String?
    public let preparedHash: String?
    public let timing: BenchmarkQueryTiming?
    public let overview: BenchmarkOverview?

    public init(eval: EvalQueryRow, packed: [EvalSpan], citationMap: [Citation], answerText: String?,
                preparedHash: String?, timing: BenchmarkQueryTiming?, overview: BenchmarkOverview?) {
        self.eval = eval
        self.packed = packed
        self.citationMap = citationMap
        self.answerText = answerText
        self.preparedHash = preparedHash
        self.timing = timing
        self.overview = overview
    }

    private enum CodingKeys: String, CodingKey { case eval, packed, citationMap, answerText, preparedHash, timing, overview }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(eval, forKey: .eval); try c.encode(packed, forKey: .packed)
        try c.encode(citationMap, forKey: .citationMap); try c.encode(answerText, forKey: .answerText)
        try c.encode(preparedHash, forKey: .preparedHash); try c.encode(timing, forKey: .timing)
        try c.encode(overview, forKey: .overview)
    }
}

public struct BenchmarkQuality: Codable, Sendable {
    public let metrics: [String: EvalMetric]
    public let byLanguage: [String: [String: EvalMetric]]
    public let byCaseType: [String: [String: EvalMetric]]
    public let queries: [BenchmarkQualityQuery]

    public init(metrics: [String: EvalMetric], byLanguage: [String: [String: EvalMetric]],
                byCaseType: [String: [String: EvalMetric]], queries: [BenchmarkQualityQuery]) {
        self.metrics = metrics
        self.byLanguage = byLanguage
        self.byCaseType = byCaseType
        self.queries = queries
    }

    /// WP1 micro aggregation over all, per language (six keys) and per case type (six keys).
    public init(queries: [BenchmarkQualityQuery]) {
        let (metrics, byLanguage, byCaseType) = Self.aggregates(queries.map(\.eval))
        self.init(metrics: metrics, byLanguage: byLanguage, byCaseType: byCaseType, queries: queries)
    }

    public static let languages = ["cs", "de", "en", "sk", "und", "mixed"]
    public static let caseTypes = ["answer", "exact_identifier", "scope", "absent", "empty_selection", "overview"]

    public static func aggregates(_ rows: [EvalQueryRow])
        -> ([String: EvalMetric], [String: [String: EvalMetric]], [String: [String: EvalMetric]]) {
        func agg(_ rs: [EvalQueryRow]) -> [String: EvalMetric] {
            Dictionary(uniqueKeysWithValues: EvalMetrics.names.map { name in
                (name, EvalMetrics.aggregate(rs.map { $0.metrics[name] ?? .unavailable }))
            })
        }
        return (agg(rows),
                Dictionary(uniqueKeysWithValues: languages.map { l in (l, agg(rows.filter { $0.language == l })) }),
                Dictionary(uniqueKeysWithValues: caseTypes.map { t in (t, agg(rows.filter { $0.caseType == t })) }))
    }
}

public struct BenchmarkCitations: Codable, Equatable, Sendable {
    public let snapshotsCorrect: Int
    public let snapshotsTotal: Int
    public let answerMarkersCorrect: Int
    public let answerMarkersTotal: Int
    public let answerGoldSupported: Int
    public let answerMarkersJudged: Int
    public let semanticReview: String

    public init(snapshotsCorrect: Int, snapshotsTotal: Int, answerMarkersCorrect: Int, answerMarkersTotal: Int,
                answerGoldSupported: Int, answerMarkersJudged: Int, semanticReview: String = "not_measured") {
        self.snapshotsCorrect = snapshotsCorrect
        self.snapshotsTotal = snapshotsTotal
        self.answerMarkersCorrect = answerMarkersCorrect
        self.answerMarkersTotal = answerMarkersTotal
        self.answerGoldSupported = answerGoldSupported
        self.answerMarkersJudged = answerMarkersJudged
        self.semanticReview = semanticReview
    }
}

public struct BenchmarkIngest: Codable, Equatable, Sendable {
    public let serviceTokens: Int64?
    public let successfulTokens: Int64?
    public let rejectedRequests: Int?
    public let splitParts: Int?
    public let elapsedUs: Int64?
    public let tokensPerSecondMilli: Int64?
    public let runnerPeakRssBytes: Int64?
    public let serverPeakRssBytes: Int64?
    public let combinedPeakRssBytes: Int64?
    public let serviceTokenStatus: String
    public let uncountedRequests: Int?
    public let memoryMethod: String?
    public let sampleIntervalMs: Int?

    public init(serviceTokens: Int64?, successfulTokens: Int64?, rejectedRequests: Int?, splitParts: Int?,
                elapsedUs: Int64?, tokensPerSecondMilli: Int64?, runnerPeakRssBytes: Int64?, serverPeakRssBytes: Int64?,
                combinedPeakRssBytes: Int64?, serviceTokenStatus: String, uncountedRequests: Int?,
                memoryMethod: String?, sampleIntervalMs: Int?) {
        self.serviceTokens = serviceTokens
        self.successfulTokens = successfulTokens
        self.rejectedRequests = rejectedRequests
        self.splitParts = splitParts
        self.elapsedUs = elapsedUs
        self.tokensPerSecondMilli = tokensPerSecondMilli
        self.runnerPeakRssBytes = runnerPeakRssBytes
        self.serverPeakRssBytes = serverPeakRssBytes
        self.combinedPeakRssBytes = combinedPeakRssBytes
        self.serviceTokenStatus = serviceTokenStatus
        self.uncountedRequests = uncountedRequests
        self.memoryMethod = memoryMethod
        self.sampleIntervalMs = sampleIntervalMs
    }

    private enum CodingKeys: String, CodingKey {
        case serviceTokens, successfulTokens, rejectedRequests, splitParts, elapsedUs, tokensPerSecondMilli
        case runnerPeakRssBytes, serverPeakRssBytes, combinedPeakRssBytes, serviceTokenStatus, uncountedRequests
        case memoryMethod, sampleIntervalMs
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(serviceTokens, forKey: .serviceTokens); try c.encode(successfulTokens, forKey: .successfulTokens)
        try c.encode(rejectedRequests, forKey: .rejectedRequests); try c.encode(splitParts, forKey: .splitParts)
        try c.encode(elapsedUs, forKey: .elapsedUs); try c.encode(tokensPerSecondMilli, forKey: .tokensPerSecondMilli)
        try c.encode(runnerPeakRssBytes, forKey: .runnerPeakRssBytes)
        try c.encode(serverPeakRssBytes, forKey: .serverPeakRssBytes)
        try c.encode(combinedPeakRssBytes, forKey: .combinedPeakRssBytes)
        try c.encode(serviceTokenStatus, forKey: .serviceTokenStatus)
        try c.encode(uncountedRequests, forKey: .uncountedRequests); try c.encode(memoryMethod, forKey: .memoryMethod)
        try c.encode(sampleIntervalMs, forKey: .sampleIntervalMs)
    }
}

public struct BenchmarkQuerySample: Codable, Equatable, Sendable {
    public let queryId: Int
    public let embeddingUs: Int64
    public let retrievalUs: Int64
    public let hydrationUs: Int64
    public let endToEndUs: Int64

    public init(queryId: Int, embeddingUs: Int64, retrievalUs: Int64, hydrationUs: Int64, endToEndUs: Int64) {
        self.queryId = queryId
        self.embeddingUs = embeddingUs
        self.retrievalUs = retrievalUs
        self.hydrationUs = hydrationUs
        self.endToEndUs = endToEndUs
    }
}

public struct BenchmarkPerformanceRow: Codable, Equatable, Sendable {
    public let chunks: Int
    public let concurrent: Bool
    public let queries: Int
    public let warmupQueries: Int
    public let warmP50Us: Int64
    public let warmP95Us: Int64
    public let endToEndP50Us: Int64
    public let endToEndP95Us: Int64
    public let hydrationP95Us: Int64
    public let coldCacheLoadUs: Int64?
    public let cacheMode: String
    public let residentBytes: Int64
    public let peakPageBytes: Int64
    public let completedWrites: Int
    public let overlapUs: Int64
    public let gatePassed: Bool?
    public let samples: [BenchmarkQuerySample]

    public init(chunks: Int, concurrent: Bool, queries: Int, warmupQueries: Int, warmP50Us: Int64, warmP95Us: Int64,
                endToEndP50Us: Int64, endToEndP95Us: Int64, hydrationP95Us: Int64, coldCacheLoadUs: Int64?,
                cacheMode: String, residentBytes: Int64, peakPageBytes: Int64, completedWrites: Int, overlapUs: Int64,
                gatePassed: Bool?, samples: [BenchmarkQuerySample]) {
        self.chunks = chunks
        self.concurrent = concurrent
        self.queries = queries
        self.warmupQueries = warmupQueries
        self.warmP50Us = warmP50Us
        self.warmP95Us = warmP95Us
        self.endToEndP50Us = endToEndP50Us
        self.endToEndP95Us = endToEndP95Us
        self.hydrationP95Us = hydrationP95Us
        self.coldCacheLoadUs = coldCacheLoadUs
        self.cacheMode = cacheMode
        self.residentBytes = residentBytes
        self.peakPageBytes = peakPageBytes
        self.completedWrites = completedWrites
        self.overlapUs = overlapUs
        self.gatePassed = gatePassed
        self.samples = samples
    }

    /// Assembles summaries and the gate from raw samples (never typed by hand).
    public init(chunks: Int, concurrent: Bool, warmupQueries: Int, coldCacheLoadUs: Int64?, cacheMode: String,
                residentBytes: Int64, peakPageBytes: Int64, completedWrites: Int, overlapUs: Int64,
                samples: [BenchmarkQuerySample]) throws {
        let warm = samples.map(\.retrievalUs), total = samples.map(\.endToEndUs)
        let p95 = try BenchmarkMath.percentile(warm, bp: 9500)
        self.init(chunks: chunks, concurrent: concurrent, queries: samples.count, warmupQueries: warmupQueries,
                  warmP50Us: try BenchmarkMath.percentile(warm, bp: 5000), warmP95Us: p95,
                  endToEndP50Us: try BenchmarkMath.percentile(total, bp: 5000),
                  endToEndP95Us: try BenchmarkMath.percentile(total, bp: 9500),
                  hydrationP95Us: try BenchmarkMath.percentile(samples.map(\.hydrationUs), bp: 9500),
                  coldCacheLoadUs: coldCacheLoadUs, cacheMode: cacheMode, residentBytes: residentBytes,
                  peakPageBytes: peakPageBytes, completedWrites: completedWrites, overlapUs: overlapUs,
                  gatePassed: BenchmarkMath.warmGate(chunks: chunks, concurrent: concurrent, queries: samples.count,
                                                     p95Us: p95),
                  samples: samples)
    }

    private enum CodingKeys: String, CodingKey {
        case chunks, concurrent, queries, warmupQueries, warmP50Us, warmP95Us, endToEndP50Us, endToEndP95Us
        case hydrationP95Us, coldCacheLoadUs, cacheMode, residentBytes, peakPageBytes, completedWrites, overlapUs
        case gatePassed, samples
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chunks, forKey: .chunks); try c.encode(concurrent, forKey: .concurrent)
        try c.encode(queries, forKey: .queries); try c.encode(warmupQueries, forKey: .warmupQueries)
        try c.encode(warmP50Us, forKey: .warmP50Us); try c.encode(warmP95Us, forKey: .warmP95Us)
        try c.encode(endToEndP50Us, forKey: .endToEndP50Us); try c.encode(endToEndP95Us, forKey: .endToEndP95Us)
        try c.encode(hydrationP95Us, forKey: .hydrationP95Us); try c.encode(coldCacheLoadUs, forKey: .coldCacheLoadUs)
        try c.encode(cacheMode, forKey: .cacheMode); try c.encode(residentBytes, forKey: .residentBytes)
        try c.encode(peakPageBytes, forKey: .peakPageBytes); try c.encode(completedWrites, forKey: .completedWrites)
        try c.encode(overlapUs, forKey: .overlapUs); try c.encode(gatePassed, forKey: .gatePassed)
        try c.encode(samples, forKey: .samples)
    }
}

public struct BenchmarkCandidate: Codable, Sendable {
    public let profileId: String
    public let identity: BenchmarkIdentity
    public let status: String
    public let errorCode: String?
    public let quality: BenchmarkQuality
    public let citations: BenchmarkCitations
    public let ingest: BenchmarkIngest
    public let performance: [BenchmarkPerformanceRow]

    public init(profileId: String, identity: BenchmarkIdentity, status: String, errorCode: String?,
                quality: BenchmarkQuality, citations: BenchmarkCitations, ingest: BenchmarkIngest,
                performance: [BenchmarkPerformanceRow]) {
        self.profileId = profileId
        self.identity = identity
        self.status = status
        self.errorCode = errorCode
        self.quality = quality
        self.citations = citations
        self.ingest = ingest
        self.performance = performance
    }

    private enum CodingKeys: String, CodingKey {
        case profileId, identity, status, errorCode, quality, citations, ingest, performance
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profileId, forKey: .profileId); try c.encode(identity, forKey: .identity)
        try c.encode(status, forKey: .status); try c.encode(errorCode, forKey: .errorCode)
        try c.encode(quality, forKey: .quality); try c.encode(citations, forKey: .citations)
        try c.encode(ingest, forKey: .ingest); try c.encode(performance, forKey: .performance)
    }
}

/// `BenchmarkReportV1` (benchmark-v1 §6).
public struct BenchmarkReportV1: Codable, Sendable {
    public let contract: String
    public let version: Int
    public let status: String
    public let backend: String
    public let mode: String
    public let platform: String
    public let environment: BenchmarkEnvironment
    public let corpus: BenchmarkCorpus
    public let calibrationHash: String
    public let parameters: BenchmarkParameters
    public let chat: BenchmarkChat
    public let candidates: [BenchmarkCandidate]

    public static let backendId = "fts-or-pinned-rrf-v1"

    public init(contract: String = "benchmark-report", version: Int = 1, status: String,
                backend: String = BenchmarkReportV1.backendId, mode: String, platform: String,
                environment: BenchmarkEnvironment, corpus: BenchmarkCorpus, calibrationHash: String,
                parameters: BenchmarkParameters, chat: BenchmarkChat, candidates: [BenchmarkCandidate]) {
        self.contract = contract
        self.version = version
        self.status = status
        self.backend = backend
        self.mode = mode
        self.platform = platform
        self.environment = environment
        self.corpus = corpus
        self.calibrationHash = calibrationHash
        self.parameters = parameters
        self.chat = chat
        self.candidates = candidates
    }

    public func jsonData() throws -> Data { try BenchmarkMarkdown.json(self) }

    // MARK: Validation (§6.3, first failure wins)

    private static func isDigest(_ value: String) -> Bool {
        value.hasPrefix("sha256:") && OllamaBenchmarkClient.isLowerHex64(String(value.dropFirst(7)))
    }

    static func validateMetric(_ m: EvalMetric) throws {
        let ok: Bool
        switch m.status {
        case "measured":
            if let found = m.found, let total = m.total, total > 0, (0...total).contains(found) {
                ok = m.recallBp == 10_000 * found / total
            } else { ok = false }
        case "not_applicable": ok = m.found == 0 && m.total == 0 && m.recallBp == nil
        case "not_available": ok = m.found == nil && m.total == nil && m.recallBp == nil
        default: ok = false
        }
        if !ok { throw BenchmarkError(code: "invalidMetric") }
    }

    public func validate() throws {
        func fail(_ code: String) -> BenchmarkError { BenchmarkError(code: code) }
        guard contract == "benchmark-report", version == 1, backend == Self.backendId,
              ["complete", "incomplete"].contains(status), ["fixture", "live"].contains(mode),
              ["macos", "windows"].contains(platform) else { throw fail("invalidReport") }
        guard OllamaBenchmarkClient.isLowerHex64(corpus.hash), OllamaBenchmarkClient.isLowerHex64(calibrationHash),
              chat.modelDigest.map(Self.isDigest) ?? true else { throw fail("invalidHash") }
        let p = parameters
        guard p.topK > 0, p.topK <= p.fetchK, p.fetchK <= 1024, (0...10_000).contains(p.evidenceShareBp),
              p.maxOutputTokens > 0, p.maxOutputTokens < p.runtimeContext else { throw fail("invalidReport") }
        let ids = candidates.map(\.profileId)
        guard Set(ids).count == ids.count else { throw fail("duplicateProfile") }
        let catalog = try EmbeddingProfiles.bundled()
        let order = ids.map { id in catalog.firstIndex { $0.id == id } }
        guard !order.contains(nil) else { throw fail("unknownProfile") }
        guard order.map({ $0! }) == order.map({ $0! }).sorted() else { throw fail("invalidOrder") }
        for c in candidates { try Self.validate(candidate: c, profile: catalog.first { $0.id == c.profileId }!) }
        if status == "complete" {
            guard chat.modelDigest != nil, chat.tokenFamily != nil else { throw fail("incompleteMeasurement") }
            for c in candidates {
                let ig = c.ingest
                guard c.status == "complete", c.identity.modelDigest != nil, !c.performance.isEmpty,
                      ig.successfulTokens != nil, ig.elapsedUs != nil, ig.combinedPeakRssBytes != nil,
                      !c.quality.queries.contains(where: {
                          $0.eval.metrics["packed_evidence_recall"]?.status == "not_available"
                      }),
                      !c.performance.contains(where: { $0.cacheMode == "cached" && $0.coldCacheLoadUs == nil })
                else { throw fail("incompleteMeasurement") }
            }
        }
    }

    private static func validate(candidate c: BenchmarkCandidate, profile: EmbeddingProfile) throws {
        func fail(_ code: String) -> BenchmarkError { BenchmarkError(code: code) }
        let i = c.identity
        do {
            try profile.validateIdentity(model: i.model, dims: i.dims, queryFormatVersion: i.queryFormatVersion,
                                         docFormatVersion: i.docFormatVersion)
        } catch { throw fail("profileIdentityMismatch") }
        guard i.normalization == "l2", i.chunkerVersion == "2" else { throw fail("profileIdentityMismatch") }
        guard i.modelDigest.map(isDigest) ?? true else { throw fail("invalidHash") }
        guard ["complete", "failed", "incomplete"].contains(c.status),
              (c.status == "complete") == (c.errorCode == nil) else { throw fail("invalidReport") }
        let rows = c.quality.queries
        let qids = rows.map(\.eval.queryId)
        guard Set(qids).count == qids.count else { throw fail("duplicateQuery") }
        guard qids == qids.sorted(by: TokenCalibration.scalarLess) else { throw fail("invalidOrder") }
        for x in rows {
            for n in EvalMetrics.names {
                guard let m = x.eval.metrics[n] else { throw fail("invalidMetric") }
                try validateMetric(m)
            }
            guard x.packed.allSatisfy({ $0.start >= 0 && $0.end > $0.start }) else { throw fail("invalidMetric") }
            guard x.preparedHash.map(OllamaBenchmarkClient.isLowerHex64) ?? true else { throw fail("invalidHash") }
        }
        let (metrics, byLanguage, byCaseType) = BenchmarkQuality.aggregates(rows.map(\.eval))
        let groups = [c.quality.metrics] + Array(c.quality.byLanguage.values) + Array(c.quality.byCaseType.values)
        for g in groups { for n in EvalMetrics.names { if let m = g[n] { try validateMetric(m) } } }
        guard metrics == c.quality.metrics, byLanguage == c.quality.byLanguage, byCaseType == c.quality.byCaseType
        else { throw fail("inconsistentAggregate") }
        let ct = c.citations
        guard ct.semanticReview == "not_measured",
              [ct.snapshotsCorrect, ct.snapshotsTotal, ct.answerMarkersCorrect, ct.answerMarkersTotal,
               ct.answerGoldSupported, ct.answerMarkersJudged].allSatisfy({ $0 >= 0 }),
              ct.snapshotsCorrect <= ct.snapshotsTotal, ct.answerMarkersCorrect <= ct.answerMarkersTotal,
              ct.answerGoldSupported <= ct.answerMarkersCorrect, ct.answerMarkersJudged <= ct.answerMarkersTotal
        else { throw fail("invalidCitations") }
        let ig = c.ingest
        let longs = [ig.serviceTokens, ig.successfulTokens, ig.elapsedUs, ig.tokensPerSecondMilli,
                     ig.runnerPeakRssBytes, ig.serverPeakRssBytes, ig.combinedPeakRssBytes]
        let ints = [ig.rejectedRequests, ig.splitParts, ig.uncountedRequests, ig.sampleIntervalMs]
        guard longs.allSatisfy({ ($0 ?? 0) >= 0 }), ints.allSatisfy({ ($0 ?? 0) >= 0 }) else { throw fail("invalidSamples") }
        switch ig.serviceTokenStatus {
        case "measured":
            guard ig.uncountedRequests == 0, !(c.status == "complete" && ig.serviceTokens == nil) else {
                throw fail("invalidSamples")
            }
        case "partial", "not_available":
            guard ig.serviceTokens == nil else { throw fail("invalidSamples") }
        default: throw fail("invalidSamples")
        }
        if let tokens = ig.successfulTokens, let elapsed = ig.elapsedUs {
            guard ig.tokensPerSecondMilli == (try BenchmarkMath.tokensPerSecondMilli(tokens: tokens, elapsedUs: elapsed))
            else { throw fail("summaryMismatch") }
        }
        if let r = ig.runnerPeakRssBytes, let s = ig.serverPeakRssBytes, let combined = ig.combinedPeakRssBytes {
            guard max(r, s) <= combined, combined <= r + s else { throw fail("summaryMismatch") }
        }
        let keys = c.performance.map { ($0.chunks, $0.concurrent ? 1 : 0) }
        for (a, b) in zip(keys, keys.dropFirst()) where !(a < b) { throw fail("invalidOrder") }
        for x in c.performance {
            let s = x.samples
            guard x.queries > 0, x.warmupQueries >= 0, s.count == x.queries,
                  s.map(\.queryId) == Array(0..<s.count),
                  s.allSatisfy({ $0.embeddingUs >= 0 && $0.retrievalUs >= 0 && $0.hydrationUs >= 0 && $0.endToEndUs >= 0 }),
                  s.allSatisfy({ $0.endToEndUs >= $0.embeddingUs + $0.retrievalUs + $0.hydrationUs }),
                  !(x.chunks == 100_000 && !x.concurrent && x.queries != 200)
            else { throw fail("invalidSamples") }
            let warm = s.map(\.retrievalUs), total = s.map(\.endToEndUs)
            guard x.warmP50Us == (try BenchmarkMath.percentile(warm, bp: 5000)),
                  x.warmP95Us == (try BenchmarkMath.percentile(warm, bp: 9500)),
                  x.endToEndP50Us == (try BenchmarkMath.percentile(total, bp: 5000)),
                  x.endToEndP95Us == (try BenchmarkMath.percentile(total, bp: 9500)),
                  x.hydrationP95Us == (try BenchmarkMath.percentile(s.map(\.hydrationUs), bp: 9500)),
                  x.gatePassed == BenchmarkMath.warmGate(chunks: x.chunks, concurrent: x.concurrent,
                                                         queries: x.queries, p95Us: x.warmP95Us)
            else { throw fail("summaryMismatch") }
            guard ["cached", "streamed"].contains(x.cacheMode), !(x.cacheMode == "streamed" && x.coldCacheLoadUs != nil)
            else { throw fail("invalidSamples") }
            if x.concurrent {
                guard x.completedWrites >= 2, x.overlapUs > 0 else { throw fail("insufficientIngestionOverlap") }
            } else {
                guard x.completedWrites == 0, x.overlapUs == 0 else { throw fail("invalidSamples") }
            }
        }
    }

    // MARK: Markdown (§6.4)

    public func markdown() -> String {
        typealias M = BenchmarkMarkdown
        let e = environment, c0 = corpus, p = parameters, ch = chat
        var lines = ["# Benchmark report v1", "", "Status: \(status)", "Mode: \(mode)", "Platform: \(platform)",
                     "Backend: \(backend)", "", "## Environment", "", "| field | value |", "|---|---|"]
        lines.append("| cpu | \(M.value(e.cpu)) |")
        lines.append("| ramBytes | \(M.value(e.ramBytes)) |")
        lines.append("| os | \(M.value(e.os)) |")
        lines.append("| architecture | \(M.value(e.architecture)) |")
        lines.append("| buildCommit | \(M.value(e.buildCommit)) |")
        lines.append("| ollamaVersion | \(M.value(e.ollamaVersion)) |")
        lines.append("| accelerator | \(M.value(e.accelerator)) |")
        lines += ["", "Corpus: \(M.value(c0.id)) (\(c0.hash)); documents \(c0.documents); queries \(c0.queries); chunker \(M.value(c0.chunkerVersion))",
                  "Calibration: \(calibrationHash)",
                  "Parameters: fetchK \(p.fetchK); topK \(p.topK); evidenceShareBp \(p.evidenceShareBp); runtimeContext \(p.runtimeContext); maxOutputTokens \(p.maxOutputTokens); seed \(p.seed)",
                  "Chat: \(M.value(ch.model)) (\(M.value(ch.modelDigest))); token family \(M.value(ch.tokenFamily)); template \(M.value(ch.showTemplateSha256))"]
        for c in candidates {
            let i = c.identity, q = c.quality, ct = c.citations, ig = c.ingest
            lines += ["", "## Candidate \(c.profileId)", "",
                      "Status: \(c.status); error: \(M.value(c.errorCode ?? "none"))",
                      "Identity: provider \(M.value(i.providerId)); endpoint \(M.value(i.endpointRevision)); model \(M.value(i.model)) (\(M.value(i.modelDigest))); dims \(i.dims); normalization \(M.value(i.normalization)); chunker \(M.value(i.chunkerVersion))",
                      "Query format: \(M.value(i.queryFormatVersion))",
                      "Document format: \(M.value(i.docFormatVersion))", "",
                      "| metric | found | total | recall | status |", "|---|---:|---:|---:|---|"]
            for n in EvalMetrics.names {
                let m = q.metrics[n] ?? .unavailable
                lines.append("| \(n) | \(M.value(m.found)) | \(M.value(m.total)) | \(M.recall(m)) | \(m.status) |")
            }
            lines += ["", "| language | " + EvalMetrics.names.joined(separator: " | ") + " |",
                      "|---|" + String(repeating: "---:|", count: EvalMetrics.names.count)]
            for lang in BenchmarkQuality.languages {
                let row = EvalMetrics.names.map { M.recall(q.byLanguage[lang]?[$0] ?? .unavailable) }
                lines.append("| \(lang) | " + row.joined(separator: " | ") + " |")
            }
            lines += ["", "Citations: snapshots \(ct.snapshotsCorrect)/\(ct.snapshotsTotal); answer markers \(ct.answerMarkersCorrect)/\(ct.answerMarkersTotal); gold-supported \(ct.answerGoldSupported)/\(ct.answerMarkersJudged) judged; semantic review \(ct.semanticReview)",
                      "Ingestion: service tokens \(M.value(ig.serviceTokens)) (\(ig.serviceTokenStatus)); successful tokens \(M.value(ig.successfulTokens)); rejected requests \(M.value(ig.rejectedRequests)); split parts \(M.value(ig.splitParts)); uncounted requests \(M.value(ig.uncountedRequests)); elapsed \(M.unit(ig.elapsedUs, "us")); throughput \(M.unit(M.milli(ig.tokensPerSecondMilli), "tokens/s"))",
                      "Memory: runner peak \(M.unit(ig.runnerPeakRssBytes, "bytes")); server peak \(M.unit(ig.serverPeakRssBytes, "bytes")); combined peak \(M.unit(ig.combinedPeakRssBytes, "bytes")); method \(M.value(ig.memoryMethod)); interval \(M.unit(ig.sampleIntervalMs, "ms"))", "",
                      "| chunks | concurrent | queries | warmup | warm p50 us | warm p95 us | end-to-end p50 us | end-to-end p95 us | hydration p95 us | cold cache us | cache | resident bytes | peak page bytes | writes | overlap us | gate |",
                      "|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|---|"]
            for x in c.performance {
                let gate = x.gatePassed.map { $0 ? "pass" : "fail" } ?? "not measured"
                let cells = [String(x.chunks), M.value(x.concurrent), M.value(x.queries), M.value(x.warmupQueries),
                             M.value(x.warmP50Us), M.value(x.warmP95Us), M.value(x.endToEndP50Us),
                             M.value(x.endToEndP95Us), M.value(x.hydrationP95Us), M.value(x.coldCacheLoadUs),
                             M.value(x.cacheMode), M.value(x.residentBytes), M.value(x.peakPageBytes),
                             M.value(x.completedWrites), M.value(x.overlapUs), gate]
                lines.append("| " + cells.joined(separator: " | ") + " |")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

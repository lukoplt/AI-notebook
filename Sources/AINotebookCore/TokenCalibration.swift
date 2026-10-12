import Foundation

public struct TokenSample: Codable, Equatable, Sendable {
    public let id: String
    public let family: String
    public let language: String
    public let split: String
    public let scalars: Int
    public let tokens: Int

    public init(id: String, family: String, language: String, split: String, scalars: Int, tokens: Int) {
        self.id = id
        self.family = family
        self.language = language
        self.split = split
        self.scalars = scalars
        self.tokens = tokens
    }
}

public struct TokenUndercountRow: Codable, Equatable, Sendable {
    public let id: String
    public let estimated: Int
    public let actual: Int
    public let undercount: Int

    public init(id: String, estimated: Int, actual: Int, undercount: Int) {
        self.id = id
        self.estimated = estimated
        self.actual = actual
        self.undercount = undercount
    }
}

/// One count observation; only `kind == body` with a `train` sample enters `fit`.
public struct TokenObservation: Codable, Equatable, Sendable {
    public let kind: String // body, embedding, prompt
    public let method: String
    public let profileId: String?
    public let sample: TokenSample

    public init(kind: String, method: String, profileId: String? = nil, sample: TokenSample) {
        self.kind = kind
        self.method = method
        self.profileId = profileId
        self.sample = sample
    }
}

/// Calibration input documents/queries (WP1 corpus fields used by §5.2).
public struct CalibrationDocument: Codable, Equatable, Sendable {
    public let documentId: String
    public let language: String
    public let text: String

    public init(documentId: String, language: String, text: String) {
        self.documentId = documentId
        self.language = language
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case documentId = "document_id", language, text }
}

public struct CalibrationQuery: Codable, Equatable, Sendable {
    public let queryId: String
    public let language: String
    public let caseType: String
    public let text: String
    public let goldDocumentIds: [String]

    public init(queryId: String, language: String, caseType: String, text: String, goldDocumentIds: [String]) {
        self.queryId = queryId
        self.language = language
        self.caseType = caseType
        self.text = text
        self.goldDocumentIds = goldDocumentIds
    }

    private enum CodingKeys: String, CodingKey {
        case queryId = "query_id", language, caseType = "case_type", text, goldDocumentIds = "gold_document_ids"
    }
}

/// One planned calibration sample (§5.2); `text` is the exact body to count.
public struct CalibrationPlanSample: Codable, Equatable, Sendable {
    public let id: String
    public let language: String
    public let split: String
    public let documentId: String?
    public let start: Int?
    public let end: Int?
    public let scalars: Int
    public let utf8Bytes: Int
    public let kind: String // body, query, mixed
    public let sources: [String]?
    public let text: String

    public init(id: String, language: String, split: String, documentId: String?, start: Int?, end: Int?,
                scalars: Int, utf8Bytes: Int, kind: String, sources: [String]?, text: String) {
        self.id = id
        self.language = language
        self.split = split
        self.documentId = documentId
        self.start = start
        self.end = end
        self.scalars = scalars
        self.utf8Bytes = utf8Bytes
        self.kind = kind
        self.sources = sources
        self.text = text
    }
}

public enum TokenCalibration {
    public static let bodyLanguages = ["cs", "de", "en", "sk"]
    static let mixedOrder = ["cs", "sk", "en", "de"]

    static func scalarLess(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }

    /// Per `(family, language)` rate = max `ceilDiv(tokens·10000, scalars)` over training samples.
    public static func fit(_ training: [TokenSample]) throws -> [TokenRate] {
        let bad = BenchmarkError(code: "invalidCalibration")
        guard !training.isEmpty else { throw bad }
        var ids = Set<String>()
        var groups: [String: (family: String, language: String, rate: Int64)] = [:]
        for s in training {
            guard s.split == "train", ids.insert(s.id).inserted, TokenEstimatorV2.languages.contains(s.language),
                  TokenEstimatorV2.validFamily(s.family), s.scalars > 0, s.scalars <= TokenEstimatorV2.maxScalars,
                  s.tokens >= 0, Int64(s.tokens) <= Int64.max / 10_000 else { throw bad }
            let rate = TokenEstimatorV2.ceilDiv(Int64(s.tokens) * 10_000, Int64(s.scalars))
            let key = s.family + "\u{0}" + s.language
            if let existing = groups[key] { groups[key]!.rate = max(existing.rate, rate) }
            else { groups[key] = (s.family, s.language, rate) }
        }
        let rows = groups.values.sorted {
            $0.family != $1.family ? scalarLess($0.family, $1.family) : scalarLess($0.language, $1.language)
        }
        return try rows.map {
            guard $0.rate <= Int64(TokenEstimatorV2.maxRateBp) else { throw bad }
            return TokenRate(family: $0.family, language: $0.language, tokensPerScalarBp: Int($0.rate))
        }
    }

    static func familyRate(family: String, language: String, rates: [TokenRate]) -> Int? {
        let rows = rates.filter { $0.family == family }
        return rows.first { $0.language == language }?.tokensPerScalarBp ?? rows.map(\.tokensPerScalarBp).max()
    }

    /// Body estimate from a scalar count: `ceil(ceil(n·rate/10000)·11500/10000)`.
    static func estimate(scalars: Int, rate: Int) -> Int {
        let base = TokenEstimatorV2.ceilDiv(Int64(scalars) * Int64(rate), 10_000)
        return Int(TokenEstimatorV2.ceilDiv(base * (10_000 + TokenEstimatorV2.headroomBp), 10_000))
    }

    public static func undercountRows(_ samples: [TokenSample], rates: [TokenRate]) throws -> [TokenUndercountRow] {
        try samples.map { s in
            guard let rate = familyRate(family: s.family, language: s.language, rates: rates) else {
                throw BenchmarkError(code: "uncalibratedFamily")
            }
            let est = estimate(scalars: s.scalars, rate: rate)
            return TokenUndercountRow(id: s.id, estimated: est, actual: s.tokens, undercount: max(0, s.tokens - est))
        }
    }

    public static func undercounts(_ samples: [TokenSample], rates: [TokenRate]) throws -> Int {
        try undercountRows(samples, rates: rates).filter { $0.undercount > 0 }.count
    }

    /// Embedding and full-prompt observations never enter chat body rates.
    public static func fitObservations(_ observations: [TokenObservation]) throws -> (trainingIds: [String], rates: [TokenRate]) {
        let training = observations.filter { $0.kind == "body" && $0.sample.split == "train" }.map(\.sample)
        return (training.map(\.id), try fit(training))
    }

    /// Frozen train/holdout partition and sample windows (benchmark-v1 §5.2).
    public static func samplePlan(documents: [CalibrationDocument], queries: [CalibrationQuery]) -> [CalibrationPlanSample] {
        var partition: [String: String] = [:]
        var samples: [CalibrationPlanSample] = []
        var windows: [String: [(doc: CalibrationDocument, scalars: [Unicode.Scalar], start: Int, end: Int)]] = [:]
        func text(_ scalars: [Unicode.Scalar], _ start: Int, _ end: Int) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[start..<end])
            return String(view)
        }
        for language in bodyLanguages {
            let docs = documents.filter { $0.language == language }.sorted { scalarLess($0.documentId, $1.documentId) }
            for (index, d) in docs.enumerated() {
                let split = index % 4 < 3 ? "train" : "holdout"
                partition[d.documentId] = split
                let scalars = Array(d.text.unicodeScalars), n = scalars.count
                var spans = stride(from: 0, to: n, by: 256).map { ($0, min($0 + 256, n)) }
                for (s, e) in spans { windows[language + "\u{0}" + split, default: []].append((d, scalars, s, e)) }
                if n > 256 && n <= 1024 { spans.append((0, n)) }
                for (s, e) in spans {
                    let body = text(scalars, s, e)
                    samples.append(CalibrationPlanSample(
                        id: "\(d.documentId):\(s):\(e)", language: language, split: split, documentId: d.documentId,
                        start: s, end: e, scalars: e - s, utf8Bytes: body.utf8.count, kind: "body", sources: nil,
                        text: body))
                }
            }
        }
        for q in queries.sorted(by: { scalarLess($0.queryId, $1.queryId) }) {
            guard ["answer", "exact_identifier"].contains(q.caseType), !q.goldDocumentIds.isEmpty,
                  bodyLanguages.contains(q.language), !q.text.isEmpty else { continue }
            let splits = q.goldDocumentIds.map { partition[$0] }
            let unique = Set(splits.map { $0 ?? "\u{0}missing" })
            let split = unique.count == 1 && !splits.contains(nil) ? splits[0]! : "holdout"
            let n = q.text.unicodeScalars.count
            samples.append(CalibrationPlanSample(
                id: "query:\(q.queryId):0:\(n)", language: q.language, split: split, documentId: "query:\(q.queryId)",
                start: 0, end: n, scalars: n, utf8Bytes: q.text.utf8.count, kind: "query", sources: nil, text: q.text))
        }
        for split in ["train", "holdout"] {
            let lists = mixedOrder.map { windows[$0 + "\u{0}" + split] ?? [] }
            let count = lists.map(\.count).min() ?? 0
            for j in 0..<count {
                let parts = lists.map { $0[j] }
                let body = parts.map { text($0.scalars, $0.start, $0.end) }.joined(separator: "\n")
                let ids = parts.map { "\($0.doc.documentId):\($0.start):\($0.end)" }
                samples.append(CalibrationPlanSample(
                    id: ids.joined(separator: "+"), language: "mixed", split: split, documentId: nil, start: nil,
                    end: nil, scalars: body.unicodeScalars.count, utf8Bytes: body.utf8.count, kind: "mixed",
                    sources: ids, text: body))
            }
        }
        return samples.sorted { scalarLess($0.id, $1.id) }
    }
}

// MARK: - Calibration report

public struct TokenCalibrationReportSample: Codable, Equatable, Sendable {
    public let id: String
    public let language: String
    public let split: String
    public let documentId: String?
    public let start: Int?
    public let end: Int?
    public let scalars: Int
    public let utf8Bytes: Int
    public let tokens: Int?

    public init(id: String, language: String, split: String, documentId: String?, start: Int?, end: Int?,
                scalars: Int, utf8Bytes: Int, tokens: Int?) {
        self.id = id
        self.language = language
        self.split = split
        self.documentId = documentId
        self.start = start
        self.end = end
        self.scalars = scalars
        self.utf8Bytes = utf8Bytes
        self.tokens = tokens
    }

    private enum CodingKeys: String, CodingKey { case id, language, split, documentId, start, end, scalars, utf8Bytes, tokens }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(language, forKey: .language); try c.encode(split, forKey: .split)
        try c.encode(documentId, forKey: .documentId); try c.encode(start, forKey: .start); try c.encode(end, forKey: .end)
        try c.encode(scalars, forKey: .scalars); try c.encode(utf8Bytes, forKey: .utf8Bytes); try c.encode(tokens, forKey: .tokens)
    }
}

public struct TokenPromptCheck: Codable, Equatable, Sendable {
    public let queryId: String
    public let split: String
    public let preparedHash: String
    public let wireMessagesHash: String
    public let actualTokens: Int?
    public let estimatedTokens: Int?

    public init(queryId: String, split: String, preparedHash: String, wireMessagesHash: String,
                actualTokens: Int?, estimatedTokens: Int?) {
        self.queryId = queryId
        self.split = split
        self.preparedHash = preparedHash
        self.wireMessagesHash = wireMessagesHash
        self.actualTokens = actualTokens
        self.estimatedTokens = estimatedTokens
    }

    private enum CodingKeys: String, CodingKey { case queryId, split, preparedHash, wireMessagesHash, actualTokens, estimatedTokens }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(queryId, forKey: .queryId); try c.encode(split, forKey: .split)
        try c.encode(preparedHash, forKey: .preparedHash); try c.encode(wireMessagesHash, forKey: .wireMessagesHash)
        try c.encode(actualTokens, forKey: .actualTokens); try c.encode(estimatedTokens, forKey: .estimatedTokens)
    }
}

/// `TokenCalibrationReportV1` (benchmark-v1 §5.4).
public struct TokenCalibrationReportV1: Codable, Equatable, Sendable {
    public let contract: String
    public let version: Int
    public let status: String
    public let corpusHash: String
    public let platform: String
    public let model: String
    public let modelDigest: String
    public let ollamaVersion: String?
    public let showTemplateSha256: String
    public let family: String
    public let method: String
    public let tokenizerId: String?
    public let tokenizerRevision: String?
    public let tokenizerAssetsSha256: String?
    public let samples: [TokenCalibrationReportSample]
    public let rates: [TokenRate]
    public let headroomBp: Int
    public let promptChecks: [TokenPromptCheck]
    public let bodyHoldoutUndercounts: Int?
    public let promptHoldoutUndercounts: Int?
    public let maxOverestimateTokens: Int?
    public let calibrated: Bool
    public let errorCode: String?

    public init(contract: String = "token-calibration-report", version: Int = 1, status: String, corpusHash: String,
                platform: String, model: String, modelDigest: String, ollamaVersion: String?,
                showTemplateSha256: String, family: String, method: String, tokenizerId: String?,
                tokenizerRevision: String?, tokenizerAssetsSha256: String?, samples: [TokenCalibrationReportSample],
                rates: [TokenRate], headroomBp: Int = 1500, promptChecks: [TokenPromptCheck],
                bodyHoldoutUndercounts: Int?, promptHoldoutUndercounts: Int?, maxOverestimateTokens: Int?,
                calibrated: Bool, errorCode: String?) {
        self.contract = contract
        self.version = version
        self.status = status
        self.corpusHash = corpusHash
        self.platform = platform
        self.model = model
        self.modelDigest = modelDigest
        self.ollamaVersion = ollamaVersion
        self.showTemplateSha256 = showTemplateSha256
        self.family = family
        self.method = method
        self.tokenizerId = tokenizerId
        self.tokenizerRevision = tokenizerRevision
        self.tokenizerAssetsSha256 = tokenizerAssetsSha256
        self.samples = samples
        self.rates = rates
        self.headroomBp = headroomBp
        self.promptChecks = promptChecks
        self.bodyHoldoutUndercounts = bodyHoldoutUndercounts
        self.promptHoldoutUndercounts = promptHoldoutUndercounts
        self.maxOverestimateTokens = maxOverestimateTokens
        self.calibrated = calibrated
        self.errorCode = errorCode
    }

    public struct Summary: Equatable, Sendable {
        public let bodyHoldoutUndercounts: Int?
        public let promptHoldoutUndercounts: Int?
        public let maxOverestimateTokens: Int?
        public let calibrated: Bool
    }

    /// Derived counters for `samples`, `rates` and `promptChecks` (§5.4).
    public static func summarize(status: String, family: String, samples: [TokenCalibrationReportSample],
                                 rates: [TokenRate], promptChecks: [TokenPromptCheck]) throws -> Summary {
        let holdout = samples.filter { $0.split == "holdout" }
        let measured = samples.allSatisfy { $0.tokens != nil }
        var bodyUnder: Int?
        var over: [Int] = []
        if measured && !rates.isEmpty {
            let rows = try TokenCalibration.undercountRows(holdout.map {
                TokenSample(id: $0.id, family: family, language: $0.language, split: $0.split,
                            scalars: $0.scalars, tokens: $0.tokens!)
            }, rates: rates)
            bodyUnder = rows.filter { $0.undercount > 0 }.count
            over = rows.map { $0.estimated - $0.actual }
        }
        let prompts = promptChecks.filter { $0.split == "holdout" }
        var promptUnder: Int?
        if measured && prompts.allSatisfy({ $0.actualTokens != nil && $0.estimatedTokens != nil }) {
            promptUnder = prompts.filter { $0.actualTokens! > $0.estimatedTokens! }.count
            over += prompts.map { $0.estimatedTokens! - $0.actualTokens! }
        }
        let calibrated = status == "complete" && bodyUnder == 0 && promptUnder == 0 && !holdout.isEmpty && !prompts.isEmpty
        let maxOver: Int? = bodyUnder == nil ? nil : (over.isEmpty ? 0 : max(0, over.max()!))
        return Summary(bodyHoldoutUndercounts: bodyUnder, promptHoldoutUndercounts: promptUnder,
                       maxOverestimateTokens: maxOver, calibrated: calibrated)
    }

    public func validate() throws {
        let bad = BenchmarkError(code: "invalidCalibration")
        guard contract == "token-calibration-report", version == 1, ["complete", "incomplete"].contains(status),
              headroomBp == 1500 else { throw bad }
        switch method {
        case OllamaBenchmarkClient.rawMethod:
            guard tokenizerId == nil, tokenizerRevision == nil, tokenizerAssetsSha256 == nil,
                  family == "ollama:" + modelDigest else { throw bad }
        case OllamaBenchmarkClient.documentedTokenizerMethod:
            guard let id = tokenizerId, !id.isEmpty, let rev = tokenizerRevision, !rev.isEmpty,
                  let assets = tokenizerAssetsSha256, OllamaBenchmarkClient.isLowerHex64(assets),
                  family == "hf:\(id)@\(rev):\(assets)" else { throw bad }
        default: throw bad
        }
        guard modelDigest.hasPrefix("sha256:"), OllamaBenchmarkClient.normalizeDigest(modelDigest) == modelDigest,
              OllamaBenchmarkClient.isLowerHex64(corpusHash), OllamaBenchmarkClient.isLowerHex64(showTemplateSha256)
        else { throw bad }
        let ids = samples.map(\.id)
        guard Set(ids).count == ids.count, ids == ids.sorted(by: TokenCalibration.scalarLess) else { throw bad }
        if status == "incomplete" {
            guard let errorCode, !errorCode.isEmpty, !calibrated else { throw bad }
            return
        }
        guard errorCode == nil, samples.allSatisfy({ $0.tokens != nil }) else { throw bad }
        let train = samples.filter { $0.split == "train" }.map {
            TokenSample(id: $0.id, family: family, language: $0.language, split: "train", scalars: $0.scalars,
                        tokens: $0.tokens!)
        }
        guard (try? TokenCalibration.fit(train)) == rates else { throw bad }
        let summary = try Self.summarize(status: status, family: family, samples: samples, rates: rates,
                                         promptChecks: promptChecks)
        guard summary == Summary(bodyHoldoutUndercounts: bodyHoldoutUndercounts,
                                 promptHoldoutUndercounts: promptHoldoutUndercounts,
                                 maxOverestimateTokens: maxOverestimateTokens, calibrated: calibrated) else { throw bad }
    }

    public func jsonData() throws -> Data { try BenchmarkMarkdown.json(self) }

    public func markdown() -> String {
        typealias M = BenchmarkMarkdown
        var lines = ["# Token calibration report v1", "", "Status: \(status)", "Platform: \(M.value(platform))",
                     "Model: \(M.value(model)) (\(M.value(modelDigest)))", "Ollama: \(M.value(ollamaVersion))",
                     "Template: \(M.value(showTemplateSha256))", "Family: \(M.value(family))",
                     "Method: \(M.value(method))"]
        if let tokenizerId {
            lines.append("Tokenizer: \(M.value(tokenizerId)) @ \(M.value(tokenizerRevision)) (\(M.value(tokenizerAssetsSha256)))")
        } else {
            lines.append("Tokenizer: none")
        }
        lines += ["Corpus: \(M.value(corpusHash))", "Headroom: \(headroomBp) bp", "Calibrated: \(M.value(calibrated))",
                  "Error: \(M.value(errorCode ?? "none"))", "",
                  "| sample | language | split | scalars | utf8 bytes | tokens |", "|---|---|---|---:|---:|---:|"]
        for s in samples {
            lines.append("| \(M.value(s.id)) | \(s.language) | \(s.split) | \(s.scalars) | \(s.utf8Bytes) | \(M.value(s.tokens)) |")
        }
        lines += ["", "| family | language | tokens per scalar bp |", "|---|---|---:|"]
        for r in rates { lines.append("| \(M.value(r.family)) | \(r.language) | \(r.tokensPerScalarBp) |") }
        lines += ["", "| query | split | prepared | wire | actual | estimated |", "|---|---|---|---|---:|---:|"]
        for p in promptChecks {
            lines.append("| \(M.value(p.queryId)) | \(p.split) | \(p.preparedHash) | \(p.wireMessagesHash) | \(M.value(p.actualTokens)) | \(M.value(p.estimatedTokens)) |")
        }
        lines += ["", "Body holdout undercounts: \(M.value(bodyHoldoutUndercounts))",
                  "Prompt holdout undercounts: \(M.value(promptHoldoutUndercounts))",
                  "Max overestimate tokens: \(M.value(maxOverestimateTokens))"]
        return lines.joined(separator: "\n") + "\n"
    }

    private enum CodingKeys: String, CodingKey {
        case contract, version, status, corpusHash, platform, model, modelDigest, ollamaVersion, showTemplateSha256
        case family, method, tokenizerId, tokenizerRevision, tokenizerAssetsSha256, samples, rates, headroomBp
        case promptChecks, bodyHoldoutUndercounts, promptHoldoutUndercounts, maxOverestimateTokens, calibrated, errorCode
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(contract, forKey: .contract); try c.encode(version, forKey: .version)
        try c.encode(status, forKey: .status); try c.encode(corpusHash, forKey: .corpusHash)
        try c.encode(platform, forKey: .platform); try c.encode(model, forKey: .model)
        try c.encode(modelDigest, forKey: .modelDigest); try c.encode(ollamaVersion, forKey: .ollamaVersion)
        try c.encode(showTemplateSha256, forKey: .showTemplateSha256); try c.encode(family, forKey: .family)
        try c.encode(method, forKey: .method); try c.encode(tokenizerId, forKey: .tokenizerId)
        try c.encode(tokenizerRevision, forKey: .tokenizerRevision)
        try c.encode(tokenizerAssetsSha256, forKey: .tokenizerAssetsSha256)
        try c.encode(samples, forKey: .samples); try c.encode(rates, forKey: .rates)
        try c.encode(headroomBp, forKey: .headroomBp); try c.encode(promptChecks, forKey: .promptChecks)
        try c.encode(bodyHoldoutUndercounts, forKey: .bodyHoldoutUndercounts)
        try c.encode(promptHoldoutUndercounts, forKey: .promptHoldoutUndercounts)
        try c.encode(maxOverestimateTokens, forKey: .maxOverestimateTokens)
        try c.encode(calibrated, forKey: .calibrated); try c.encode(errorCode, forKey: .errorCode)
    }
}

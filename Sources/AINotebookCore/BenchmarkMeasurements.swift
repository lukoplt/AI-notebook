import Foundation

/// Raw per-query timing; the report-owned row type (Task 6) is reused, not redeclared.
public typealias BenchmarkTimingSample = BenchmarkQuerySample

public struct BenchmarkPhaseMeasurement: Equatable, Sendable {
    public let coldCacheLoadUs: Int64?
    public let samples: [BenchmarkTimingSample]
    public let completedWrites: Int
    public let overlapUs: Int64

    public init(coldCacheLoadUs: Int64?, samples: [BenchmarkTimingSample], completedWrites: Int, overlapUs: Int64) {
        self.coldCacheLoadUs = coldCacheLoadUs
        self.samples = samples
        self.completedWrites = completedWrites
        self.overlapUs = overlapUs
    }
}

public struct CalibrationRequest: Sendable {
    public let id: String
    public let family: String
    public let language: String
    public let split: String
    /// `body` (raw prompt, may train) or `prompt` (full rendered chat request, never trains).
    public let kind: String
    public let text: String
    public let messages: [ChatTurn]

    public init(id: String, family: String, language: String, split: String, kind: String, text: String,
                messages: [ChatTurn] = []) {
        self.id = id
        self.family = family
        self.language = language
        self.split = split
        self.kind = kind
        self.text = text
        self.messages = messages
    }
}

public struct CalibrationObservation: Codable, Equatable, Sendable {
    public let sample: TokenSample
    public let kind: String
    public let textHash: String
    public let method: String
    public let modelDigest: String
    public let tokenizerRevision: String?
    public let assetsSha256: String?

    public init(sample: TokenSample, kind: String, textHash: String, method: String, modelDigest: String,
                tokenizerRevision: String?, assetsSha256: String?) {
        self.sample = sample
        self.kind = kind
        self.textHash = textHash
        self.method = method
        self.modelDigest = modelDigest
        self.tokenizerRevision = tokenizerRevision
        self.assetsSha256 = assetsSha256
    }
}

public struct CacheAdmission: Equatable, Sendable {
    public let chargeBytes: Int64
    /// `cached` when the candidate matrix fits the application cache budget, else `streamed`.
    public let cacheMode: String
}

@MainActor public enum BenchmarkMeasurements {
    public nonisolated static let cacheBudgetBytes: Int64 = 536_870_912

    /// Cold (one callback), warmup, then measured queries. In concurrent mode a writer
    /// child task runs from after warmup until the measured loop ends; it is always
    /// cancelled and awaited, and only completions inside the measured window count.
    public static func run(queries: Int, warmup: Int, concurrent: Bool,
                           nowUs: @escaping @MainActor () -> Int64,
                           coldLoad: () async throws -> Int64?,
                           runQuery: (Int) async throws -> BenchmarkTimingSample,
                           writeBatch: @escaping @MainActor (Int) async throws -> Void) async throws -> BenchmarkPhaseMeasurement {
        guard queries > 0, warmup >= 0 else { throw BenchmarkError(code: "invalidSamples") }
        try Task.checkCancellation()
        let coldElapsed = try await coldLoad()
        guard coldElapsed.map({ $0 >= 0 }) ?? true else { throw BenchmarkError(code: "invalidSamples") }
        for i in 0..<warmup {
            try Task.checkCancellation()
            _ = try await runQuery(i)
        }
        let writer: Task<[Int64], Error>? = concurrent ? Task { @MainActor in
            var completions: [Int64] = []
            var batch = 0
            while !Task.isCancelled {
                do { try await writeBatch(batch) } catch {
                    if Task.isCancelled || error is CancellationError { break }
                    throw error
                }
                completions.append(nowUs())
                batch += 1
                await Task.yield()
            }
            return completions
        } : nil
        let measuredStart: Int64, measuredEnd: Int64
        var samples: [BenchmarkTimingSample] = []
        do {
            measuredStart = nowUs()
            for i in 0..<queries {
                try Task.checkCancellation()
                samples.append(try await runQuery(i))
            }
            measuredEnd = nowUs()
        } catch {
            writer?.cancel()
            _ = await writer?.result
            throw error
        }
        guard measuredStart <= measuredEnd else {
            writer?.cancel()
            _ = await writer?.result
            throw BenchmarkError(code: "invalidSamples")
        }
        guard let writer else {
            return BenchmarkPhaseMeasurement(coldCacheLoadUs: coldElapsed, samples: samples, completedWrites: 0, overlapUs: 0)
        }
        writer.cancel()
        let completions = try await writer.value
        let (writes, overlap) = try overlap(completionsUs: completions, measuredStartUs: measuredStart,
                                            measuredEndUs: measuredEnd)
        return BenchmarkPhaseMeasurement(coldCacheLoadUs: coldElapsed, samples: samples, completedWrites: writes,
                                         overlapUs: overlap)
    }

    /// Writer completions inside `[start, end]`; fewer than two or a zero span fails.
    public nonisolated static func overlap(completionsUs: [Int64], measuredStartUs: Int64,
                                           measuredEndUs: Int64) throws -> (completedWrites: Int, overlapUs: Int64) {
        let inside = completionsUs.filter { $0 >= measuredStartUs && $0 <= measuredEndUs }
        guard inside.count >= 2, let first = inside.min(), let last = inside.max(), last > first else {
            throw BenchmarkError(code: "insufficientIngestionOverlap")
        }
        return (inside.count, last - first)
    }

    /// Admission charge `rows·(dims·4 + 32)` against the 512 MiB application cache.
    public nonisolated static func cacheAdmission(chunks: Int, dims: Int,
                                                  budgetBytes: Int64 = cacheBudgetBytes) -> CacheAdmission {
        let charge = Int64(chunks) * (Int64(dims) * 4 + 32)
        return CacheAdmission(chargeBytes: charge, cacheMode: charge <= budgetBytes ? "cached" : "streamed")
    }

    /// Observes each request exactly once. Only provider-reported counts are accepted here;
    /// a missing count is `tokenCountUnavailable` (the caller may fall back explicitly).
    public static func calibrate(requests: [CalibrationRequest], modelDigest: String,
                                 observe: (CalibrationRequest) async throws -> ChatTokenObservation) async throws -> [CalibrationObservation] {
        guard Set(requests.map(\.id)).count == requests.count,
              requests.allSatisfy({ $0.kind == "body" || $0.kind == "prompt" }) else {
            throw BenchmarkError(code: "invalidCalibration")
        }
        var rows: [CalibrationObservation] = []
        for request in requests {
            try Task.checkCancellation()
            let observed = try await observe(request)
            try Task.checkCancellation()
            guard let count = observed.promptTokens else { throw BenchmarkError(code: "tokenCountUnavailable") }
            guard count >= 0 else { throw BenchmarkError(code: "invalidTokenCount") }
            let sample = TokenSample(id: request.id, family: request.family, language: request.language,
                                     split: request.split, scalars: request.text.unicodeScalars.count, tokens: count)
            rows.append(CalibrationObservation(
                sample: sample, kind: request.kind, textHash: EvalCorpus.sha256(Data(request.text.utf8)),
                method: request.kind == "body" ? OllamaBenchmarkClient.rawMethod : OllamaBenchmarkClient.chatMethod,
                modelDigest: modelDigest, tokenizerRevision: nil, assetsSha256: nil))
        }
        return rows
    }

    /// Body-rate fit from observations: only `kind=body, split=train` rows train.
    public nonisolated static func fitBodyRates(_ observations: [CalibrationObservation]) throws -> [TokenRate] {
        try TokenCalibration.fit(observations.filter { $0.kind == "body" && $0.sample.split == "train" }.map(\.sample))
    }

    /// FNV-1a 32-bit over UTF-8 (deterministic synthetic seeds).
    public nonisolated static func fnv1a32(_ text: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for byte in text.utf8 { h = (h ^ UInt32(byte)) &* 16_777_619 }
        return h
    }
}

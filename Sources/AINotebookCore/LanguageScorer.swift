import Foundation

public struct LanguageFeatureCount: Codable, Equatable, Sendable {
    public let symbols: [Int32]
    public let count: Int64
}
public struct LanguageProfileScore: Codable, Equatable, Sendable {
    public let weightedSums: [Int64]
    public let orderScores: [Int64]
    public let combinedScore: Int64
}

/// Complete diagnostics for a normalized text slice, including abstentions.
public struct LanguageTextResult: Codable, Equatable, Sendable {
    public let words: [String]
    public let wordScalars: [[UInt32]]
    public let letterCount: Int64
    public let wordCount: Int64
    public let bucketStart: Int?
    public let features: [[LanguageFeatureCount]]
    public let featureCounts: [Int64]
    public let knownCounts: [Int64]
    public let unknownCounts: [Int64]
    public let profiles: [String: LanguageProfileScore]
    public let winner: String
    public let runnerUp: String
    public let margin: Int64
    public let coverageBp: Int64
    public let label: String
    public let reason: String

    private enum CodingKeys: String, CodingKey {
        case words, wordScalars, letterCount, wordCount, bucketStart, features, featureCounts, knownCounts,
             unknownCounts, profiles, winner, runnerUp, margin, coverageBp, label, reason
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(words, forKey: .words)
        try c.encode(wordScalars, forKey: .wordScalars)
        try c.encode(letterCount, forKey: .letterCount)
        try c.encode(wordCount, forKey: .wordCount)
        try c.encode(bucketStart, forKey: .bucketStart)
        try c.encode(features, forKey: .features)
        try c.encode(featureCounts, forKey: .featureCounts)
        try c.encode(knownCounts, forKey: .knownCounts)
        try c.encode(unknownCounts, forKey: .unknownCounts)
        try c.encode(profiles, forKey: .profiles)
        try c.encode(winner, forKey: .winner)
        try c.encode(runnerUp, forKey: .runnerUp)
        try c.encode(margin, forKey: .margin)
        try c.encode(coverageBp, forKey: .coverageBp)
        try c.encode(label, forKey: .label)
        try c.encode(reason, forKey: .reason)
    }
}

struct LanguageScorer: Sendable {
    let model: LanguageModel
    let tables: UnicodeTables
    private let vocabularyIndices: [[[Int32]: Int]]
    /// Label-only path used by ingestion; same decisions as `score`.
    let fast: LanguageFastScorer

    init(model: LanguageModel, tables: UnicodeTables) {
        self.model = model
        self.tables = tables
        vocabularyIndices = model.vocabulary.map { order in
            Dictionary(uniqueKeysWithValues: order.features.enumerated().map { ($0.element, $0.offset) })
        }
        fast = LanguageFastScorer(model: model, tables: tables)
    }
    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        precondition(b > 0)
        return a / b - ((a < 0 && a % b != 0) ? 1 : 0)
    }

    /// The caller supplies an already normalized, capped text/document slice.
    func score(_ scalars: [UInt32]) -> LanguageTextResult {
        precondition(scalars.count <= model.parameters.textCapScalars)
        let words = LanguageNormalization.classify(scalars, tables: tables)
        var raw = Array(repeating: [[Int32]: Int64](), count: 3)
        for padded in words.boundaryWords {
            for n in 1...3 where padded.count >= n {
                for i in 0...(padded.count - n) {
                    raw[n - 1][Array(padded[i..<(i + n)]), default: 0] += 1
                }
            }
        }
        let features = raw.map { counts in
            counts.map { LanguageFeatureCount(symbols: $0.key, count: $0.value) }
                .sorted { $0.symbols.lexicographicallyPrecedes($1.symbols) }
        }
        let featureCounts = features.map { $0.reduce(Int64(0)) { $0 + $1.count } }
        let knownCounts = features.enumerated().map { n, counts in
            counts.reduce(Int64(0)) { $0 + (vocabularyIndices[n][$1.symbols] == nil ? 0 : $1.count) }
        }
        let unknownCounts = zip(featureCounts, knownCounts).map(-)
        let total = featureCounts.reduce(0, +)
        let coverage: Int64 = total == 0 ? 0 : 10_000 * knownCounts.reduce(0, +) / total
        var scores: [String: LanguageProfileScore] = [:]
        for profile in model.profiles {
            let sums = profile.orders.enumerated().map { n, order in
                features[n].reduce(Int64(0)) { sum, feature in
                    let weight = vocabularyIndices[n][feature.symbols].map { order.weights[$0] } ?? order.unknownWeight
                    return sum + feature.count * weight
                }
            }
            let orderScores = sums.enumerated().map { n, sum in
                featureCounts[n] == 0 ? 0 : Self.floorDiv(sum, featureCounts[n])
            }
            let combined = profile.priorWeight + zip(model.parameters.orderWeights, orderScores).reduce(0) { $0 + $1.0 * $1.1 }
            scores[profile.id] = LanguageProfileScore(weightedSums: sums, orderScores: orderScores, combinedScore: combined)
        }
        let ranked = scores.sorted { a, b in
            if a.value.combinedScore != b.value.combinedScore { return a.value.combinedScore > b.value.combinedScore }
            if a.key == "background" { return b.key != "background" }
            if b.key == "background" { return false }
            return a.key < b.key
        }
        let winner = ranked[0], runner = ranked[1]
        let margin = winner.value.combinedScore - runner.value.combinedScore
        let bucket = model.thresholds.last { Int64($0.start) <= words.letterCount }
        let reason: String
        if words.letterCount < model.parameters.minLetters { reason = "minLetters" }
        else if words.wordCount < model.parameters.minWords { reason = "minWords" }
        else if let bucket {
            if bucket.enabled == 0 { reason = "bucketDisabled" }
            else if winner.key == "background" { reason = "background" }
            else if winner.value.combinedScore < bucket.minWinningScore { reason = "minWinningScore" }
            else if margin < bucket.minMargin { reason = "minMargin" }
            else if coverage < bucket.minKnownCoverageBp { reason = "minKnownCoverageBp" }
            else { reason = "accepted" }
        } else { preconditionFailure("validated model must contain a bucket for at least 12 letters") }
        return LanguageTextResult(words: words.words, wordScalars: words.wordScalars, letterCount: words.letterCount,
            wordCount: words.wordCount, bucketStart: bucket?.start, features: features, featureCounts: featureCounts,
            knownCounts: knownCounts, unknownCounts: unknownCounts, profiles: scores, winner: winner.key,
            runnerUp: runner.key, margin: margin, coverageBp: coverage, label: reason == "accepted" ? winner.key : "und", reason: reason)
    }
}

import Foundation

/// The decision fields of `LanguageTextResult`, computed by `LanguageScorer.decide`
/// without the diagnostics (words, feature lists, per-profile breakdowns).
struct LanguageTextDecision: Equatable, Sendable {
    let label: String
    let reason: String
    let letterCount: Int64
    let wordCount: Int64
    let winner: String
    let runnerUp: String
    let margin: Int64
    let coverageBp: Int64
    /// Combined score per profile, in `model.profiles` order.
    let combinedScores: [Int64]
}

/// Label-only scoring for ingestion: the same arithmetic as `LanguageScorer.score`
/// on n-gram occurrences instead of counted, sorted feature lists. A weighted sum
/// over distinct features (count × weight) equals the sum over their occurrences,
/// so every order score, combined score, margin, coverage and decision is
/// identical (`LanguageFastScorerTests` checks this against the full scorer).
/// Model tables are flattened once per scorer: one open-addressing table per
/// order maps a packed n-gram to its vocabulary index, and weights are stored
/// feature-major so one lookup updates every profile.
struct LanguageFastScorer: Sendable {
    private struct Order: Sendable {
        let keys: [UInt64]
        let indices: [Int32]
        let mask: Int
        let weights: [Int64]          // vocabulary index * profileCount + profile
        let unknownWeights: [Int64]   // per profile
    }
    private let orders: [Order]
    private let profileCount: Int
    private let profileIds: [String]
    private let priors: [Int64]
    private let orderWeights: [Int64]
    /// Position of each profile in the full scorer's tie order (background first, then by id).
    private let tieRanks: [Int]
    private let model: LanguageModel
    private let tables: UnicodeTables

    private static let empty = UInt64.max
    /// Symbols (-2 EOS, -1 BOS, scalars) packed into 21 bits each.
    @inline(__always) static func symbol(_ value: Int32) -> UInt64 { UInt64(Int64(value) + 2) }
    @inline(__always) static func key(_ symbols: [Int32]) -> UInt64 {
        symbols.reduce(UInt64(0)) { $0 << 21 | symbol($1) }
    }
    @inline(__always) private static func slot(_ key: UInt64, _ mask: Int) -> Int {
        Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> 32) & mask
    }

    init(model: LanguageModel, tables: UnicodeTables) {
        self.model = model
        self.tables = tables
        let profiles = model.profiles
        profileCount = profiles.count
        profileIds = profiles.map(\.id)
        priors = profiles.map(\.priorWeight)
        orderWeights = model.parameters.orderWeights
        let ranked = profiles.indices.sorted { a, b in
            let x = profiles[a].id, y = profiles[b].id
            if x == "background" { return y != "background" }
            if y == "background" { return false }
            return x < y
        }
        var ranks = [Int](repeating: 0, count: profiles.count)
        for (rank, index) in ranked.enumerated() { ranks[index] = rank }
        tieRanks = ranks
        orders = model.vocabulary.enumerated().map { n, vocabulary in
            var capacity = 16
            while capacity < vocabulary.features.count * 2 { capacity <<= 1 }
            var keys = [UInt64](repeating: Self.empty, count: capacity)
            var indices = [Int32](repeating: -1, count: capacity)
            for (index, feature) in vocabulary.features.enumerated() {
                let key = Self.key(feature)
                var slot = Self.slot(key, capacity - 1)
                while keys[slot] != Self.empty {
                    precondition(keys[slot] != key, "validated vocabulary features are distinct")
                    slot = (slot + 1) & (capacity - 1)
                }
                keys[slot] = key
                indices[slot] = Int32(index)
            }
            var weights = [Int64](repeating: 0, count: vocabulary.features.count * profiles.count)
            for (p, profile) in profiles.enumerated() {
                for (index, weight) in profile.orders[n].weights.enumerated() { weights[index * profiles.count + p] = weight }
            }
            return Order(keys: keys, indices: indices, mask: capacity - 1, weights: weights,
                         unknownWeights: profiles.map { $0.orders[n].unknownWeight })
        }
    }

    @inline(__always) private func index(_ order: Order, _ key: UInt64) -> Int {
        var slot = Self.slot(key, order.mask)
        while true {
            let stored = order.keys[slot]
            if stored == key { return Int(order.indices[slot]) }
            if stored == Self.empty { return -1 }
            slot = (slot + 1) & order.mask
        }
    }

    /// Same contract as `LanguageScorer.score`: an already normalized, capped slice.
    func decide(_ scalars: UnsafeBufferPointer<UInt32>) -> LanguageTextDecision {
        precondition(scalars.count <= model.parameters.textCapScalars)
        let profiles = profileCount
        var known = [Int64](repeating: 0, count: 3 * profiles)
        var totals: (Int64, Int64, Int64) = (0, 0, 0)
        var knownTotals: (Int64, Int64, Int64) = (0, 0, 0)
        var letters: Int64 = 0, words: Int64 = 0
        let o1 = orders[0], o2 = orders[1], o3 = orders[2]
        // Previous two symbols of the current padded word and how many it has.
        var p1: UInt64 = 0, p2: UInt64 = 0, length = 0
        known.withUnsafeMutableBufferPointer { sums in
            @inline(__always) func add(_ order: Order, _ base: Int, _ key: UInt64) -> Bool {
                let i = index(order, key)
                guard i >= 0 else { return false }
                let row = i * profiles
                for p in 0..<profiles { sums[base + p] += order.weights[row + p] }
                return true
            }
            @inline(__always) func emit(_ u: UInt64) {
                totals.0 += 1
                if add(o1, 0, u) { knownTotals.0 += 1 }
                if length >= 1 {
                    totals.1 += 1
                    if add(o2, profiles, p1 << 21 | u) { knownTotals.1 += 1 }
                }
                if length >= 2 {
                    totals.2 += 1
                    if add(o3, 2 * profiles, p2 << 42 | p1 << 21 | u) { knownTotals.2 += 1 }
                }
                p2 = p1
                p1 = u
                length += 1
            }
            for scalar in scalars {
                switch tables.wordClass(scalar) {
                case UnicodeTables.letterClass:
                    if length == 0 { emit(Self.symbol(-1)) }
                    emit(UInt64(scalar) + 2)
                    letters += 1
                case UnicodeTables.markClass:
                    if length > 0 { emit(UInt64(scalar) + 2) }
                default:
                    if length > 0 {
                        emit(Self.symbol(-2))
                        words += 1
                        length = 0
                    }
                }
            }
            if length > 0 {
                emit(Self.symbol(-2))
                words += 1
            }
        }
        let counts = [totals.0, totals.1, totals.2], knownCounts = [knownTotals.0, knownTotals.1, knownTotals.2]
        var combined = [Int64](repeating: 0, count: profiles)
        var best = 0, second = -1
        for p in 0..<profiles {
            var score = priors[p]
            for n in 0..<3 {
                let sum = known[n * profiles + p] + (counts[n] - knownCounts[n]) * orders[n].unknownWeights[p]
                score += orderWeights[n] * (counts[n] == 0 ? 0 : LanguageScorer.floorDiv(sum, counts[n]))
            }
            combined[p] = score
        }
        @inline(__always) func precedes(_ a: Int, _ b: Int) -> Bool {
            combined[a] != combined[b] ? combined[a] > combined[b] : tieRanks[a] < tieRanks[b]
        }
        for p in 1..<profiles {
            if precedes(p, best) { second = best; best = p }
            else if second < 0 || precedes(p, second) { second = p }
        }
        let margin = combined[best] - combined[second]
        let total = counts[0] + counts[1] + counts[2]
        let coverage: Int64 = total == 0 ? 0 : 10_000 * (knownCounts[0] + knownCounts[1] + knownCounts[2]) / total
        let parameters = model.parameters
        let reason: String
        if letters < parameters.minLetters { reason = "minLetters" }
        else if words < parameters.minWords { reason = "minWords" }
        else if let bucket = model.thresholds.last(where: { Int64($0.start) <= letters }) {
            if bucket.enabled == 0 { reason = "bucketDisabled" }
            else if profileIds[best] == "background" { reason = "background" }
            else if combined[best] < bucket.minWinningScore { reason = "minWinningScore" }
            else if margin < bucket.minMargin { reason = "minMargin" }
            else if coverage < bucket.minKnownCoverageBp { reason = "minKnownCoverageBp" }
            else { reason = "accepted" }
        } else { preconditionFailure("validated model must contain a bucket for at least 12 letters") }
        return LanguageTextDecision(label: reason == "accepted" ? profileIds[best] : "und", reason: reason,
                                    letterCount: letters, wordCount: words, winner: profileIds[best],
                                    runnerUp: profileIds[second], margin: margin, coverageBp: coverage,
                                    combinedScores: combined)
    }

    func decide(_ scalars: [UInt32]) -> LanguageTextDecision {
        scalars.withUnsafeBufferPointer { decide($0) }
    }

    /// `LanguageDocument.detect` reduced to its aggregate: the same sampled windows,
    /// each decided in place on the normalized stream.
    func decideDocument(stream: [UInt32]) -> LanguageAggregate {
        let parameters = model.parameters
        let ranges = LanguageDocument.ranges(length: stream.count, count: parameters.windowCount, size: parameters.windowScalars)
        let decisions = stream.withUnsafeBufferPointer { buffer in
            ranges.map { decide(UnsafeBufferPointer(rebasing: buffer[$0])) }
        }
        return LanguageDocument.aggregate(targets: model.targets, labels: decisions.map(\.label),
                                          letters: decisions.map(\.letterCount))
    }
}

import Foundation

public protocol ContextTokenEstimating: Sendable {
    var version: Int { get }
    func estimate(_ text: String, language: String) -> Int
}

/// Development estimator pinned by folder-rag-v1; calibration is owned by WP7.
public struct PlaceholderTokenEstimatorV1: ContextTokenEstimating {
    public let version = 1
    public init() {}

    public func estimate(_ text: String, language: String) -> Int {
        let divisor: Int64 = language == "en" ? 4 : 3
        let count = Int64(text.unicodeScalars.count)
        let base = count / divisor + (count % divisor == 0 ? 0 : 1)
        let scaled = base.multipliedReportingOverflow(by: Int64(10_000 + RagContractV1.Pack.tokenEstimateHeadroomBp))
        precondition(!scaled.overflow, "Token estimate exceeds Int64")
        return Int(scaled.partialValue / 10_000 + (scaled.partialValue % 10_000 == 0 ? 0 : 1))
    }
}

public enum ContextPackAlgorithms {
    static let maxJSONInteger: Int64 = 9_007_199_254_740_991

    static func scalarLess(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }

    /// Repeated integer floors are part of the ordering contract.
    public static func diversity(_ passages: [PackPassage], singleSource: Bool) -> [PackPassage] {
        var remaining = passages
        var counts: [Int64: Int] = [:]
        var output: [PackPassage] = []
        let penalty = Int64(singleSource ? 10_000 : RagContractV1.Pack.diversityPenaltyBp)
        func effective(_ p: PackPassage) -> Int64 {
            precondition((0...2_000_000).contains(p.rrfMicro))
            var score = p.rrfMicro
            for _ in 0..<(counts[p.sourceId] ?? 0) {
                let product = score.multipliedReportingOverflow(by: penalty)
                precondition(!product.overflow)
                score = product.partialValue / 10_000
            }
            return score
        }
        while !remaining.isEmpty {
            let nextIndex = remaining.indices.min {
                let left = effective(remaining[$0]), right = effective(remaining[$1])
                return left == right ? remaining[$0].chunkId < remaining[$1].chunkId : left > right
            }!
            let next = remaining.remove(at: nextIndex)
            output.append(next)
            counts[next.sourceId, default: 0] += 1
        }
        return output
    }

    struct DirectoryKey: Hashable {
        let folderId: Int64?
        let dir: String

        init(folderId: Int64?, path: String) {
            self.folderId = folderId
            dir = path.unicodeScalars.lastIndex(of: "/").map { String(path.unicodeScalars[..<$0]) } ?? ""
        }

        static func == (a: Self, b: Self) -> Bool {
            a.folderId == b.folderId && a.dir.unicodeScalars.elementsEqual(b.dir.unicodeScalars)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(folderId)
            for scalar in dir.unicodeScalars { hasher.combine(scalar.value) }
        }

        static func less(_ a: Self, _ b: Self) -> Bool {
            if a.folderId != b.folderId {
                guard let left = a.folderId else { return true }
                guard let right = b.folderId else { return false }
                return left < right
            }
            return scalarLess(a.dir, b.dir)
        }
    }

    public static func overviewOrder(_ passages: [PackPassage]) -> [PackPassage] {
        let grouped = Dictionary(grouping: passages) { DirectoryKey(folderId: $0.folderId, path: $0.relPath) }
        let groups = grouped.keys.sorted(by: DirectoryKey.less).map { key in
            grouped[key]!.sorted {
                if $0.relPath.unicodeScalars.elementsEqual($1.relPath.unicodeScalars) {
                    return ($0.sourceId, $0.chunkId) < ($1.sourceId, $1.chunkId)
                }
                return scalarLess($0.relPath, $1.relPath)
            }
        }
        var result: [PackPassage] = []
        for round in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where round < group.count { result.append(group[round]) }
        }
        return result
    }

    static func share(_ count: Int, _ basisPoints: Int) -> Int {
        // All callers validate counts as Int32 before any arithmetic.
        let product = Int64(count).multipliedReportingOverflow(by: Int64(basisPoints))
        precondition(!product.overflow)
        return Int(product.partialValue / 10_000)
    }

    public static func budget(_ x: PackBudgetInput,
                              evidenceShareBp: Int = RagContractV1.Pack.evidenceShareBp) throws -> PackBudgetResult {
        try validateBudget(x)
        guard (0...10_000).contains(evidenceShareBp) else { throw RagTuningError.invalidTuning }
        let b = x.runtimeContext - x.maxOutputTokens
        guard b > 0, x.mandatoryTokens <= b else { throw ContextPackError.contextTooSmall }
        let r = b - x.mandatoryTokens
        let e = min(share(r, evidenceShareBp), x.evidenceBudgetCap ?? Int.max, x.evidenceCeilingTokens ?? Int.max)
        let limit = min(x.topK, RagContractV1.Pack.maxPassages)
        var ids = Set<Int64>(), used = 0
        var truncated: Int64?
        var prefix: PackBudgetPrefix?
        func fill(_ ceiling: Int) {
            guard e > 0 else { return }
            for p in x.passages where !ids.contains(p.id) {
                if ids.count == limit { break }
                if p.tokens <= ceiling - used { ids.insert(p.id); used += p.tokens }
            }
        }
        if e > 0, limit > 0, let first = x.passages.first, first.tokens > e,
           let chosen = first.truncationCandidates.last(where: { $0.tokens <= e }) {
            ids.insert(first.id)
            used = chosen.tokens
            truncated = first.id
            prefix = chosen
        }
        fill(e)
        let mapShare = x.mapCeilingTokens ?? share(r, RagContractV1.Pack.mapMaxShareBp)
        var map = min(x.mapTokensDesired, mapShare)
        let external = min(x.noteWebTokensDesired, share(r, RagContractV1.Pack.noteWebMaxShareBp))
        var historyCount = 0, historyTokens = 0
        func fillHistory(_ ceiling: Int) {
            while historyCount < x.historyTurnTokensNewestFirst.count {
                let cost = x.historyTurnTokensNewestFirst[historyCount]
                if cost > ceiling - historyTokens { break }
                historyTokens += cost
                historyCount += 1
            }
        }
        fillHistory(r - used - map - external)
        var left = r - used - map - external - historyTokens
        fill(min(used + left, x.evidenceBudgetCap ?? Int.max))
        left = r - used - map - external - historyTokens
        fillHistory(historyTokens + left)
        left = r - used - map - external - historyTokens
        let mapCeiling = min(x.mapTokensDesired, mapShare)
        let extra = min(left, mapCeiling - map)
        map += extra
        left -= extra
        return PackBudgetResult(remainder: r, evidenceTarget: e,
            includedPassageIds: x.passages.filter { ids.contains($0.id) }.map(\.id),
            truncatedPassageId: truncated, truncatedPassageEndScalar: prefix?.endScalar,
            truncatedPassageTokens: prefix?.tokens, evidenceTokens: used, mapTokens: map,
            noteWebTokens: external, historyTurnsIncluded: historyCount,
            historyTokens: historyTokens, unusedTokens: left)
    }

    private static func validateBudget(_ x: PackBudgetInput) throws {
        let costs = [x.mandatoryTokens, x.mapTokensDesired, x.noteWebTokensDesired]
            + x.historyTurnTokensNewestFirst + [x.evidenceBudgetCap ?? 0, x.mapCeilingTokens ?? 0, x.evidenceCeilingTokens ?? 0]
        guard [x.runtimeContext, x.maxOutputTokens].allSatisfy({ (1...Int(Int32.max)).contains($0) }),
              (0...Int(Int32.max)).contains(x.topK),
              costs.allSatisfy({ (0...Int(Int32.max)).contains($0) }) else {
            throw ContextPackError.invalidInput
        }
        var seen = Set<Int64>()
        for p in x.passages {
            guard (0...maxJSONInteger).contains(p.id), seen.insert(p.id).inserted,
                  (0...Int(Int32.max)).contains(p.tokens) else { throw ContextPackError.invalidInput }
            var lastEnd = 0, lastCost = 0
            for prefix in p.truncationCandidates {
                guard prefix.endScalar > lastEnd, Int64(prefix.endScalar) <= maxJSONInteger,
                      prefix.tokens > lastCost, prefix.tokens < p.tokens else { throw ContextPackError.invalidInput }
                lastEnd = prefix.endScalar
                lastCost = prefix.tokens
            }
        }
    }
}

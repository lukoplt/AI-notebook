import Foundation

/// A sampled range in normalized Unicode scalars, not a canonical-text span.
public struct LanguageWindow: Codable, Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let expected: LanguageTextResult
}

public struct LanguageDocumentResult: Codable, Equatable, Sendable {
    public let normalizedScalarCount: Int
    public let windowCount: Int
    public let windowScalars: Int
    public let windows: [LanguageWindow]
    public let sampledLetters: Int64
    public let acceptedLetters: [String: Int64]
    public let unknownLetters: Int64
    public let sharesBp: [String: Int64]
    public let unknownShareBp: Int64
    public let langCoverageBp: Int64
    public let label: String
    public let reason: String
}

struct LanguageAggregate: Codable, Equatable, Sendable {
    let sampledLetters: Int64
    let acceptedLetters: [String: Int64]
    let unknownLetters: Int64
    let sharesBp: [String: Int64]
    let unknownShareBp: Int64
    let langCoverageBp: Int64
    let label: String
    let reason: String
}

enum LanguageDocument {
    static func ranges(length: Int, count: Int, size: Int) -> [Range<Int>] {
        precondition(length >= 0 && count > 0 && size > 0)
        guard length > 0 else { return [] }
        let n = Int64(length), c = Int64(count), s = Int64(size)
        let k = min(c, n / s + (n % s == 0 ? 0 : 1))
        let width = min(s, n / k)
        return (0..<k).map { index in
            let start = k == 1 ? 0 : index * (n - width) / (k - 1)
            return Int(start)..<Int(start + width)
        }
    }

    /// Samples the already normalized stream once; each slice is scored as-is.
    static func detect(stream: [UInt32], scorer: LanguageScorer) -> LanguageDocumentResult {
        let parameters = scorer.model.parameters
        let windows = ranges(length: stream.count, count: parameters.windowCount,
                             size: parameters.windowScalars).map { range in
            LanguageWindow(start: range.lowerBound, end: range.upperBound,
                           expected: scorer.score(Array(stream[range])))
        }
        let result = aggregate(targets: scorer.model.targets,
                               labels: windows.map { $0.expected.label },
                               letters: windows.map { $0.expected.letterCount })
        return LanguageDocumentResult(
            normalizedScalarCount: stream.count, windowCount: windows.count,
            windowScalars: windows.first.map { $0.end - $0.start } ?? 0, windows: windows,
            sampledLetters: result.sampledLetters, acceptedLetters: result.acceptedLetters,
            unknownLetters: result.unknownLetters, sharesBp: result.sharesBp,
            unknownShareBp: result.unknownShareBp, langCoverageBp: result.langCoverageBp,
            label: result.label, reason: result.reason)
    }

    static func aggregate(targets: [String], labels: [String], letters: [Int64]) -> LanguageAggregate {
        precondition(labels.count == letters.count)
        precondition(letters.allSatisfy { $0 >= 0 } && Set(targets).count == targets.count)
        let total = letters.reduce(0, +)
        var accepted = Dictionary(uniqueKeysWithValues: targets.map { ($0, Int64(0)) })
        var unknown: Int64 = 0
        for (label, count) in zip(labels, letters) {
            if accepted[label] != nil { accepted[label, default: 0] += count }
            else { unknown += count }
        }
        let shares = accepted.mapValues { total == 0 ? 0 : 10_000 * $0 / total }
        let unknownShare = total == 0 ? 0 : 10_000 * unknown / total
        let coverage = total == 0 ? 0 : 10_000 * accepted.values.reduce(0, +) / total
        let dominant = targets.first {
            let count = accepted[$0, default: 0]
            return count > 0 && 10_000 * count >= 7_000 * total
        }
        let confidentTargets = accepted.values.filter { $0 > 0 }.count
        let label = dominant ?? (confidentTargets >= 2 ? "mixed" : "und")
        let reason = dominant != nil ? "dominant" : (confidentTargets >= 2 ? "mixed" : "insufficientEvidence")
        return LanguageAggregate(sampledLetters: total, acceptedLetters: accepted,
                                 unknownLetters: unknown, sharesBp: shares,
                                 unknownShareBp: unknownShare, langCoverageBp: coverage,
                                 label: label, reason: reason)
    }
}

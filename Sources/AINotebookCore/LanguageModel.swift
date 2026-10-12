import Foundation

struct LanguageParameters: Decodable, Sendable {
    let maxFeaturesPerProfile: [Int]
    let orderWeights: [Int64]
    let scoreScale: Int
    let lengthBucketStarts: [Int]
    let minLetters: Int
    let minWords: Int
    let mixedDominanceBp: Int
    let inputCapScalars: Int
    let textCapScalars: Int
    let windowCount: Int
    let windowScalars: Int
}
struct LanguageVocabulary: Decodable, Sendable {
    let order: Int
    let features: [[Int32]]
}
struct LanguageProfileOrder: Decodable, Sendable {
    let order: Int
    let weights: [Int64]
    let unknownWeight: Int64
}
struct LanguageProfile: Decodable, Sendable {
    let id: String
    let priorWeight: Int64
    let orders: [LanguageProfileOrder]
}
struct LanguageThreshold: Decodable, Sendable {
    let start: Int
    let enabled: Int
    let minWinningScore: Int64
    let minMargin: Int64
    let minKnownCoverageBp: Int64
}
struct LanguageAttribution: Codable, Equatable, Sendable {
    let sourceIds: [String]
    let licenseIds: [String]
    let attributionPath: String
    let attributionSha256: String
    let noticePath: String
    let noticeSha256: String

    static let keys = ["sourceIds", "licenseIds", "attributionPath", "attributionSha256", "noticePath", "noticeSha256"]
    func validate(production: Bool) throws {
        try require(sourceIds.allSatisfy { asciiIdentifier($0, punctuation: "_-") }, "source IDs")
        try require([attributionSha256, noticeSha256].allSatisfy { $0.isEmpty || isSHA256($0) }, "attribution digests")
        if production {
            try require(!sourceIds.isEmpty && !licenseIds.isEmpty && licenseIds.allSatisfy { !$0.isEmpty }
                && !attributionPath.isEmpty && !noticePath.isEmpty && isSHA256(attributionSha256)
                && isSHA256(noticeSha256), "production attribution")
            try require(Set(sourceIds).count == sourceIds.count && Set(licenseIds).count == licenseIds.count, "duplicate attribution IDs")
        } else {
            try require(sourceIds.isEmpty && licenseIds.isEmpty && attributionPath.isEmpty
                && attributionSha256.isEmpty && noticePath.isEmpty && noticeSha256.isEmpty, "synthetic attribution")
        }
    }
}

struct LanguageModel: Decodable, Sendable {
    let contract: String
    let version: Int
    let kind: String
    let modelId: String
    let targets: [String]
    let normalizationTablesVersion: String
    let alpha: Int
    let parameters: LanguageParameters
    let vocabulary: [LanguageVocabulary]
    let profiles: [LanguageProfile]
    let thresholds: [LanguageThreshold]
    let attribution: LanguageAttribution

    static func parse(_ data: Data, tables: UnicodeTables, allowSynthetic: Bool) throws -> LanguageModel {
        let root = try LanguageJSON.parse(data)
        try root.checkKeys(["contract", "version", "kind", "modelId", "targets", "normalizationTablesVersion", "alpha",
                            "parameters", "vocabulary", "profiles", "thresholds", "attribution"])
        try root.field("parameters").checkKeys(["maxFeaturesPerProfile", "orderWeights", "scoreScale", "lengthBucketStarts",
            "minLetters", "minWords", "mixedDominanceBp", "inputCapScalars", "textCapScalars", "windowCount", "windowScalars"])
        for order in try root.field("vocabulary").array() { try order.checkKeys(["order", "features"]) }
        for profile in try root.field("profiles").array() {
            try profile.checkKeys(["id", "priorWeight", "orders"])
            for order in try profile.field("orders").array() { try order.checkKeys(["order", "weights", "unknownWeight"]) }
        }
        for threshold in try root.field("thresholds").array() {
            try threshold.checkKeys(["start", "enabled", "minWinningScore", "minMargin", "minKnownCoverageBp"])
        }
        try root.field("attribution").checkKeys(LanguageAttribution.keys)
        let model = try JSONDecoder().decode(LanguageModel.self, from: data)
        try model.validate(tables: tables, allowSynthetic: allowSynthetic)
        return model
    }

    private func validate(tables: UnicodeTables, allowSynthetic: Bool) throws {
        try require(contract == "lang-detector" && version == 1 && alpha == 1
            && normalizationTablesVersion == UnicodeTables.normalizationVersion, "model version")
        try require(kind == "production" || (allowSynthetic && kind == "synthetic"), "model kind")
        try require(asciiIdentifier(modelId, punctuation: "._-"), "model ID")
        try require((2...4).contains(targets.count) && targets.allSatisfy(isLanguageID)
            && strictlySorted(targets), "targets")
        let p = parameters
        try require(p.maxFeaturesPerProfile.count == 3 && p.maxFeaturesPerProfile.allSatisfy { (1...4096).contains($0) }, "feature caps")
        try require(p.orderWeights == [1, 2, 3] && p.scoreScale == 1024 && p.lengthBucketStarts == [12, 32, 80, 200]
            && p.minLetters == 12 && p.minWords == 3 && p.mixedDominanceBp == 7000, "fixed parameters")
        try require(p.windowScalars > 0 && p.windowScalars <= p.textCapScalars && p.textCapScalars <= p.inputCapScalars
            && p.inputCapScalars <= 5_000_000 && (1...8).contains(p.windowCount), "scalar caps")
        if kind == "production" {
            try require(targets == ["cs", "de", "en", "sk"] && p.maxFeaturesPerProfile == [256, 1024, 4096]
                && p.inputCapScalars == 5_000_000 && p.textCapScalars == 8192 && p.windowCount == 8
                && p.windowScalars == 512, "production parameters")
        }
        try require(vocabulary.map(\.order) == [1, 2, 3], "vocabulary orders")
        for (n, order) in vocabulary.enumerated() {
            try require(order.features.count <= (targets.count + 1) * p.maxFeaturesPerProfile[n], "vocabulary cap")
            var previous: [Int32]?
            for feature in order.features {
                try require(feature.count == n + 1 && (previous.map { $0.lexicographicallyPrecedes(feature) } ?? true), "feature ordering/length")
                previous = feature
                var interiorCount = 0
                for (i, symbol) in feature.enumerated() {
                    if symbol == -1 { try require(i == 0, "BOS position") }
                    else if symbol == -2 { try require(i == feature.count - 1, "EOS position") }
                    else {
                        try require(symbol >= 0 && UnicodeTables.isScalar(UInt32(symbol)), "feature scalar")
                        let category = tables.generalCategory(UInt32(symbol))
                        try require(category.hasPrefix("L") || category.hasPrefix("M"), "feature category")
                        try require(!(i == 1 && feature[0] == -1 && category.hasPrefix("M")), "detached BOS mark")
                        interiorCount += 1
                    }
                }
                try require(interiorCount > 0 || (feature.count == 1 && [-1, -2].contains(feature[0])), "boundary-only feature")
            }
        }
        try require(profiles.map(\.id) == ["background"] + targets, "profiles")
        let prior: Int64
        switch profiles.count {
        case 3: prior = -1125
        case 4: prior = -1420
        case 5: prior = -1648
        default: throw LanguageJSON.Invalid.data("profile count")
        }
        for profile in profiles {
            try require(profile.priorWeight == prior && profile.orders.map(\.order) == [1, 2, 3], "prior/orders")
            for (n, order) in profile.orders.enumerated() {
                try require(order.weights.count == vocabulary[n].features.count
                    && order.weights.allSatisfy { (-1_000_000...0).contains($0) }
                    && (-1_000_000...0).contains(order.unknownWeight), "profile weights")
            }
        }
        try require(thresholds.map(\.start) == [12, 32, 80, 200], "threshold starts")
        for t in thresholds {
            try require((0...1).contains(t.enabled) && (-7_000_000...0).contains(t.minWinningScore)
                && (0...7_000_000).contains(t.minMargin) && (0...10000).contains(t.minKnownCoverageBp)
                && (t.enabled == 0 || t.minMargin > 0), "threshold values")
        }
        try attribution.validate(production: kind == "production")
    }
}

// Shared validation primitives also used by the production manifest reader.
func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw LanguageJSON.Invalid.data(message) }
}
func strictlySorted<T: Comparable>(_ values: [T]) -> Bool {
    zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
}
func asciiIdentifier(_ value: String, punctuation: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || punctuation.utf8.contains($0)
    }
}
func isLanguageID(_ value: String) -> Bool {
    (2...3).contains(value.utf8.count) && value.utf8.allSatisfy { (97...122).contains($0) }
}
func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

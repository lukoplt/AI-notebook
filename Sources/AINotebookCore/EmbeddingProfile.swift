import Foundation

/// Typed WP7 error (`docs/contracts/benchmark-v1.md`). `code` is the contract error code.
public struct EmbeddingProfileError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public init(code: String) { self.code = code }
    public var description: String { "EmbeddingProfileError(\(code))" }
}

public enum EmbeddingPurpose: String, Codable, Sendable { case query, document }

/// One row of the frozen WP7 embedding catalog (benchmark-v1 §2).
public struct EmbeddingProfile: Codable, Equatable, Sendable {
    public let id: String
    public let model: String
    public let tokenizerId: String
    public let queryPrefix: String
    public let documentPrefix: String
    public let nativeDims: Int
    public let dims: Int
    public let maxInputTokens: Int
    public let matryoshka: Bool
    public let ceilingSource: String

    public init(id: String, model: String, tokenizerId: String, queryPrefix: String, documentPrefix: String,
                nativeDims: Int, dims: Int, maxInputTokens: Int, matryoshka: Bool, ceilingSource: String) {
        self.id = id
        self.model = model
        self.tokenizerId = tokenizerId
        self.queryPrefix = queryPrefix
        self.documentPrefix = documentPrefix
        self.nativeDims = nativeDims
        self.dims = dims
        self.maxInputTokens = maxInputTokens
        self.matryoshka = matryoshka
        self.ceilingSource = ceilingSource
    }

    /// Prefix + text, no trimming or normalization.
    public func format(_ text: String, purpose: EmbeddingPurpose) -> String {
        (purpose == .query ? queryPrefix : documentPrefix) + text
    }

    public func formatVersion(_ purpose: EmbeddingPurpose, effectiveLimit: Int? = nil) -> String {
        "wp7:" + id + ":" + purpose.rawValue + ":split1:scalarpool1:prefixl2:ctx" + String(effectiveLimit ?? maxInputTokens)
    }

    /// Identity agreement (§2 `identity`): exact model, dims and both format strings sharing one
    /// ctx value in `1...maxInputTokens`. Returns that effective limit.
    @discardableResult
    public func validateIdentity(model: String, dims: Int, queryFormatVersion: String,
                                 docFormatVersion: String) throws -> Int {
        let mismatch = EmbeddingProfileError(code: "profileIdentityMismatch")
        guard Data(model.utf8) == Data(self.model.utf8), dims == self.dims,
              let limit = Self.contextSuffix(queryFormatVersion, prefix: formatVersionPrefix(.query)),
              (1...maxInputTokens).contains(limit),
              Data(queryFormatVersion.utf8) == Data(formatVersion(.query, effectiveLimit: limit).utf8),
              Data(docFormatVersion.utf8) == Data(formatVersion(.document, effectiveLimit: limit).utf8)
        else { throw mismatch }
        return limit
    }

    /// Parses the ctx value of a stored format string for this profile and purpose.
    public func effectiveLimit(fromFormatVersion value: String, purpose: EmbeddingPurpose) throws -> Int {
        guard let limit = Self.contextSuffix(value, prefix: formatVersionPrefix(purpose)),
              (1...maxInputTokens).contains(limit),
              value == formatVersion(purpose, effectiveLimit: limit)
        else { throw EmbeddingProfileError(code: "profileIdentityMismatch") }
        return limit
    }

    private func formatVersionPrefix(_ purpose: EmbeddingPurpose) -> String {
        "wp7:" + id + ":" + purpose.rawValue + ":split1:scalarpool1:prefixl2:ctx"
    }

    private static func contextSuffix(_ value: String, prefix: String) -> Int? {
        guard value.hasPrefix(prefix) else { return nil }
        let digits = value.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.count <= 10, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              digits.first != "0" else { return nil }
        return Int(digits)
    }
}

public enum EmbeddingProfiles {
    public static let ids = ["nomic-v2-256", "nomic-v2-768", "qwen3-06b-256", "qwen3-06b-512",
                             "qwen3-06b-1024", "bge-m3-1024", "paraphrase-768"]

    public static func bundled() throws -> [EmbeddingProfile] { try cached.get() }

    /// True for an exact WP7 format string of a catalog profile (`wp7:<id>:<purpose>:...:ctx<n>`).
    public static func isFormatVersion(_ value: String, purpose: EmbeddingPurpose) -> Bool {
        guard let id = OllamaBenchmarkClient.profileId(fromFormatVersion: value),
              let profile = try? require(id) else { return false }
        return (try? profile.effectiveLimit(fromFormatVersion: value, purpose: purpose)) != nil
    }

    /// Exact catalog ID only; a model name is never accepted as an ID.
    public static func require(_ id: String) throws -> EmbeddingProfile {
        guard let p = try bundled().first(where: { Data($0.id.utf8) == Data(id.utf8) }) else {
            throw EmbeddingProfileError(code: "unknownProfile")
        }
        return p
    }

    /// Catalog invariants: seven unique IDs in contract order, positive dims and ceilings,
    /// `dims <= nativeDims`, reduction only for Matryoshka rows.
    public static func validate(_ profiles: [EmbeddingProfile]) throws {
        let bad = EmbeddingProfileError(code: "invalidProfile")
        guard profiles.map(\.id) == ids else { throw bad }
        for p in profiles {
            guard !p.model.isEmpty, !p.tokenizerId.isEmpty, p.nativeDims > 0, p.dims > 0, p.dims <= p.nativeDims,
                  p.maxInputTokens > 0, p.matryoshka || p.dims == p.nativeDims,
                  p.ceilingSource == "model-card" || p.ceilingSource == "ollama-512"
            else { throw bad }
        }
    }

    private struct Catalog: Decodable {
        let contract: String
        let version: Int
        let profiles: [EmbeddingProfile]
    }

    private static let cached: Result<[EmbeddingProfile], Error> = Result {
        guard let url = Bundle.module.url(forResource: "embedding-profiles-v1", withExtension: "json",
                                          subdirectory: "Benchmark") else {
            throw EmbeddingProfileError(code: "missingResource")
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        guard catalog.contract == "embedding-profiles", catalog.version == 1 else {
            throw EmbeddingProfileError(code: "invalidProfile")
        }
        try validate(catalog.profiles)
        return catalog.profiles
    }
}

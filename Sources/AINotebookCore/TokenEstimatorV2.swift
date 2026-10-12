import CryptoKit
import Foundation

/// Typed WP7 benchmark/calibration error; `code` is the benchmark-v1 contract code.
public struct BenchmarkError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public init(code: String) { self.code = code }
    public var description: String { "BenchmarkError(\(code))" }
}

public struct TokenRate: Codable, Equatable, Sendable {
    public let family: String
    public let language: String
    public let tokensPerScalarBp: Int

    public init(family: String, language: String, tokensPerScalarBp: Int) {
        self.family = family
        self.language = language
        self.tokensPerScalarBp = tokensPerScalarBp
    }
}

public struct TokenFamilyBinding: Codable, Equatable, Sendable {
    public let model: String
    public let modelDigest: String
    public let family: String

    public init(model: String, modelDigest: String, family: String) {
        self.model = model
        self.modelDigest = modelDigest
        self.family = family
    }
}

/// Calibrated chat-token estimator v2 (benchmark-v1 §4). Without any rate for its
/// family it is the explicitly uncalibrated UTF-8-byte fallback.
public struct TokenEstimatorV2: ContextTokenEstimating {
    public let version = 2
    public let family: String
    public let rates: [TokenRate]
    private let familyRates: [String: Int]
    private let maxRate: Int?

    public static let languages: Set<String> = ["cs", "de", "en", "sk", "und", "mixed"]
    public static let headroomBp: Int64 = 1500
    public static let maxRateBp = 1_000_000
    public static let maxScalars = 5_000_000
    public static let fixtureFamily = "fixture-only"

    public init(family: String, rates: [TokenRate]) throws {
        try Self.validateRates(rates)
        self.family = family
        self.rates = rates
        var own: [String: Int] = [:]
        for r in rates where r.family == family { own[r.language] = r.tokensPerScalarBp }
        familyRates = own
        maxRate = own.values.max()
    }

    public func estimate(_ text: String, language: String) -> Int {
        let base: Int64
        if let rate = familyRates[language] ?? maxRate {
            let n = Int64(text.unicodeScalars.count)
            if n > Int64(Self.maxScalars) { return Int(Int32.max) }
            base = Self.ceilDiv(n * Int64(rate), 10_000)
        } else {
            base = Int64(text.utf8.count) // explicitly uncalibrated conservative fallback
        }
        if base > Int64(Int32.max) / 2 { return Int(Int32.max) }
        return Int(min(Int64(Int32.max), Self.ceilDiv(base * (10_000 + Self.headroomBp), 10_000)))
    }

    /// Bundled resource estimator. Only an exact `(model, modelDigest)` binding selects
    /// calibrated rates; everything else is the honest UTF-8 fallback.
    public static func bundled(model: String, modelDigest: String? = nil) throws -> TokenEstimatorV2 {
        let resource = try TokenEstimateResource.bundled()
        guard let family = resolveFamily(model: model, modelDigest: modelDigest, bindings: resource.bindings) else {
            return try TokenEstimatorV2(family: "unverified", rates: [])
        }
        return try TokenEstimatorV2(family: family, rates: resource.rates.filter { $0.family == family })
    }

    /// Exact `(model, modelDigest)` equality only; a missing digest never resolves.
    public static func resolveFamily(model: String, modelDigest: String?, bindings: [TokenFamilyBinding]) -> String? {
        guard let modelDigest else { return nil }
        return bindings.first {
            Data($0.model.utf8) == Data(model.utf8) && Data($0.modelDigest.utf8) == Data(modelDigest.utf8)
        }?.family
    }

    static func ceilDiv(_ a: Int64, _ b: Int64) -> Int64 { a / b + (a % b == 0 ? 0 : 1) }

    static func validFamily(_ family: String) -> Bool {
        !family.isEmpty && !family.unicodeScalars.contains { $0.properties.isWhitespace }
    }

    static func validateRates(_ rates: [TokenRate]) throws {
        var seen = Set<String>()
        for r in rates {
            guard validFamily(r.family), languages.contains(r.language),
                  (0...maxRateBp).contains(r.tokensPerScalarBp),
                  seen.insert(r.family + "\u{0}" + r.language).inserted
            else { throw BenchmarkError(code: "invalidCalibration") }
        }
    }
}

/// Minimal JSON value for provenance rows and canonical hashing.
public indirect enum BenchmarkJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([BenchmarkJSON])
    case object([String: BenchmarkJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([BenchmarkJSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: BenchmarkJSON].self) { self = .object(o) }
        else { throw BenchmarkError(code: "invalidCalibration") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .int(i): try c.encode(i)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    /// Canonical JSON (benchmark-v1 §4): sorted keys (scalar order), `,`/`:` separators,
    /// literal UTF-8, JSON-required escapes only, no slash escaping.
    public var canonical: String {
        switch self {
        case .null: return "null"
        case let .bool(b): return b ? "true" : "false"
        case let .int(i): return String(i)
        case let .string(s): return Self.quote(s)
        case let .array(a): return "[" + a.map(\.canonical).joined(separator: ",") + "]"
        case let .object(o):
            let keys = o.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) { $0.value < $1.value } }
            return "{" + keys.map { Self.quote($0) + ":" + o[$0]!.canonical }.joined(separator: ",") + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    static func from<T: Encodable>(_ value: T) throws -> BenchmarkJSON {
        try JSONDecoder().decode(BenchmarkJSON.self, from: JSONEncoder().encode(value))
    }
}

func sha256LowerHex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Runtime resource `token-estimate-v2.json` (benchmark-v1 §4).
public struct TokenEstimateResource: Codable, Equatable, Sendable {
    public let contract: String
    public let version: Int
    public let status: String
    public let payloadHash: String
    public let bindings: [TokenFamilyBinding]
    public let rates: [TokenRate]
    public let provenance: [BenchmarkJSON]

    public init(contract: String = "token-estimate", version: Int = 2, status: String, payloadHash: String,
                bindings: [TokenFamilyBinding], rates: [TokenRate], provenance: [BenchmarkJSON]) {
        self.contract = contract
        self.version = version
        self.status = status
        self.payloadHash = payloadHash
        self.bindings = bindings
        self.rates = rates
        self.provenance = provenance
    }

    public static func payloadHash(bindings: [TokenFamilyBinding], rates: [TokenRate],
                                   provenance: [BenchmarkJSON]) throws -> String {
        let payload = BenchmarkJSON.object(["bindings": try .from(bindings), "provenance": .array(provenance),
                                            "rates": try .from(rates)])
        return sha256LowerHex(payload.canonical)
    }

    /// `production` rejects the synthetic `fixture-only` family anywhere.
    public func validate(production: Bool) throws {
        let bad = BenchmarkError(code: "invalidCalibration")
        guard contract == "token-estimate", version == 2,
              payloadHash == (try Self.payloadHash(bindings: bindings, rates: rates, provenance: provenance))
        else { throw bad }
        try TokenEstimatorV2.validateRates(rates)
        switch status {
        case "pending": guard bindings.isEmpty, rates.isEmpty, provenance.isEmpty else { throw bad }
        case "calibrated": break
        default: throw bad
        }
        let families = Set(rates.map(\.family))
        var pairs = Set<String>()
        for b in bindings {
            guard OllamaBenchmarkClient.normalizeDigest(b.modelDigest) == b.modelDigest, b.modelDigest.hasPrefix("sha256:"),
                  families.contains(b.family), pairs.insert(b.model + "\u{0}" + b.modelDigest).inserted
            else { throw bad }
        }
        if production && (families.contains(TokenEstimatorV2.fixtureFamily)
                          || bindings.contains { $0.family == TokenEstimatorV2.fixtureFamily }) { throw bad }
    }

    public static func bundled() throws -> TokenEstimateResource { try cached.get() }

    private static let cached: Result<TokenEstimateResource, Error> = Result {
        guard let url = Bundle.module.url(forResource: "token-estimate-v2", withExtension: "json",
                                          subdirectory: "Benchmark") else {
            throw BenchmarkError(code: "missingResource")
        }
        let resource = try JSONDecoder().decode(TokenEstimateResource.self, from: Data(contentsOf: url))
        try resource.validate(production: true)
        return resource
    }
}

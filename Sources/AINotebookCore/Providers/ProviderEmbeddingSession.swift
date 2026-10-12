import CryptoKit
import Foundation

/// Prepares a query-embedding session bound to one index generation's identity.
public protocol EmbeddingSessionPreparing: Sendable {
    func prepareEmbedding(identity: GenerationIdentity) async throws -> ProviderEmbeddingSession
}

/// Immutable embedding capability: provider configuration, credential and raw
/// model were captured once, so later Settings edits affect only new sessions.
public struct ProviderEmbeddingSession: Sendable {
    /// Qualified storage key (`providerId:rawModel`), or the stored legacy key.
    public let storageKey: String
    /// Endpoint fingerprint of the captured provider root (never a secret).
    public let endpointRevision: String
    /// True for legacy generations, which have no provable historical endpoint.
    public let legacyEndpointUnverified: Bool
    /// Full captured identity of a named WP7 profile session; nil for legacy/`1`.
    public let identity: GenerationIdentity?
    private let backend: Backend

    private enum Backend: Sendable {
        case raw(client: any EmbeddingProducing, model: String, format: String)
        case profile(profile: EmbeddingProfile, pipeline: StrictEmbeddingPipeline, effectiveLimit: Int)
    }

    /// `rawFormat` is the generation's raw format (`legacy`, `1` or `2`, embedding-raw-format-v2).
    internal init(client: any EmbeddingProducing, model: String, storageKey: String,
                  endpointRevision: String, legacyEndpointUnverified: Bool = false, rawFormat: String = "1") {
        self.backend = .raw(client: client, model: model, format: rawFormat)
        self.storageKey = storageKey
        self.endpointRevision = endpointRevision
        self.legacyEndpointUnverified = legacyEndpointUnverified
        self.identity = nil
    }

    /// Captured modern session for a named profile (WP7). No settings reference.
    internal init(storageKey: String, endpointRevision: String, identity: GenerationIdentity,
                  profile: EmbeddingProfile, pipeline: StrictEmbeddingPipeline, effectiveLimit: Int) {
        self.backend = .profile(profile: profile, pipeline: pipeline, effectiveLimit: effectiveLimit)
        self.storageKey = storageKey
        self.endpointRevision = endpointRevision
        self.legacyEndpointUnverified = false
        self.identity = identity
    }

    /// The named profile of a modern session, else nil.
    public var profile: EmbeddingProfile? {
        if case let .profile(profile, _, _) = backend { return profile }
        return nil
    }

    /// Query purpose. Formats `legacy` and `1` leave input text unchanged; `2` adds the task prefix.
    public func embed(inputs: [String]) async throws -> [[Float]] {
        try await embed(inputs, purpose: .query)
    }

    /// Document purpose. Legacy sessions keep their unchanged raw-input behavior.
    public func embedDocuments(inputs: [String]) async throws -> [[Float]] {
        try await embed(inputs, purpose: .document)
    }

    /// Strict complete-input result (parts and counts) for one input of a named profile.
    public func embedInput(_ text: String, purpose: EmbeddingPurpose) async throws -> EmbeddedInput {
        guard case let .profile(profile, pipeline, limit) = backend else {
            throw EmbeddingProfileError(code: "unsupportedEmbeddingProfile")
        }
        return try await pipeline.embed(text, profile: profile, purpose: purpose, effectiveLimit: limit)
    }

    private func embed(_ inputs: [String], purpose: EmbeddingPurpose) async throws -> [[Float]] {
        switch backend {
        case let .raw(client, model, format):
            let formatted = inputs.map {
                purpose == .query ? RawEmbeddingFormat.query($0, model: model, format: format)
                                  : RawEmbeddingFormat.document($0, model: model, format: format)
            }
            return try await client.embed(model: model, inputs: formatted)
        case let .profile(profile, pipeline, limit):
            var out: [[Float]] = []
            out.reserveCapacity(inputs.count)
            for input in inputs {
                try Task.checkCancellation()
                out.append(try await pipeline.embed(input, profile: profile, purpose: purpose,
                                                    effectiveLimit: limit).vector)
            }
            return out
        }
    }
}

extension ProviderEmbeddingSession {
    /// The one raw-input adapter mapping, shared by router query sessions and WP6
    /// folder captures. The adapter owns only the captured root and key.
    static func rawAdapter(type: ProviderType, root: String, apiKey: String?,
                           session: URLSession) throws -> any EmbeddingProducing {
        switch type {
        case .ollama:
            guard let url = URL(string: try ProviderAPIRoot.normalize(root)) else {
                throw ProviderConfigurationError.invalidBaseURL
            }
            return OllamaClient(baseURL: url, session: session)
        case .openai, .openaiCompatible:
            return OpenAIEmbeddingAdapter(baseURL: root, apiKey: apiKey, session: session)
        case .anthropic, .openwebui:
            throw ProviderConfigurationError.unsupportedEndpoint
        }
    }

    /// Captures a raw-input (`legacy`/`1`) session for an already validated provider
    /// configuration: normalized root, shared endpoint revision, `providerId:model` key.
    static func captureRaw(config: ProviderConfig, model: String, apiKey: String?,
                           session: URLSession, format: String = "1") throws -> ProviderEmbeddingSession {
        let root = try ProviderAPIRoot.normalize(config.baseURL)
        return ProviderEmbeddingSession(client: try rawAdapter(type: config.type, root: root, apiKey: apiKey, session: session),
                                        model: model, storageKey: config.id + ":" + model,
                                        endpointRevision: EmbeddingEndpointRevision.make(type: config.type, normalizedRoot: root),
                                        rawFormat: format)
    }
}

/// Deterministic endpoint identity shared with generation builders: lowercase
/// hex SHA-256 of the provider type's storage value, LF, and the normalized API
/// root. Credentials are excluded, so key rotation never demands re-embedding.
public enum EmbeddingEndpointRevision {
    public static func make(type: ProviderType, normalizedRoot: String) -> String {
        let bytes = Array(type.rawValue.utf8) + [UInt8(0x0A)] + Array(normalizedRoot.utf8)
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Raw query input formats. WP7 named-profile formats (`wp7:<profileId>:...`) are
/// resolved by exact catalog ID in `ProviderRouter`; none is inferred from model names.
public enum EmbeddingQueryFormat {
    public static let supported: Set<String> = ["legacy", "1", "2"]

    public static func validate(_ version: String) throws {
        guard supported.contains(version) else { throw RetrievalError.unsupportedQueryFormat }
    }
}

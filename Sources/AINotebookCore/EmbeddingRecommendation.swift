import Foundation

/// Core embedding-default policy error (independent of eval code).
public struct EmbeddingRecommendationError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public init(code: String) { self.code = code }
    public var description: String { "EmbeddingRecommendationError(\(code))" }
}

/// Signals that an installation is not fresh. Any one of them preserves current behavior.
public struct EmbeddingInstallEvidence: Codable, Equatable, Sendable {
    public let databaseExists: Bool
    public let preferencesExist: Bool
    public let completedOnboarding: Bool
    public let explicitSelection: Bool
    public let convertedChatOnly: Bool

    public init(databaseExists: Bool, preferencesExist: Bool, completedOnboarding: Bool,
                explicitSelection: Bool, convertedChatOnly: Bool) {
        self.databaseExists = databaseExists
        self.preferencesExist = preferencesExist
        self.completedOnboarding = completedOnboarding
        self.explicitSelection = explicitSelection
        self.convertedChatOnly = convertedChatOnly
    }
}

/// `embedding-decision-v1.json` (benchmark-v1 §1). Extra keys (`parameters`) are read by
/// `RagRuntimeTuning`.
public struct EmbeddingDecision: Codable, Equatable, Sendable {
    public let contract: String
    public let version: Int
    public let status: String
    public let profileId: String?

    public init(contract: String = "embedding-decision", version: Int = 1, status: String, profileId: String?) {
        self.contract = contract
        self.version = version
        self.status = status
        self.profileId = profileId
    }

    public static func bundled() throws -> EmbeddingDecision {
        try JSONDecoder().decode(EmbeddingDecision.self, from: resourceData())
    }

    static func resourceData() throws -> Data {
        guard let url = Bundle.module.url(forResource: "embedding-decision-v1", withExtension: "json",
                                          subdirectory: "Benchmark") else {
            throw EmbeddingRecommendationError(code: "invalidDecision")
        }
        return try Data(contentsOf: url)
    }

    private enum CodingKeys: String, CodingKey { case contract, version, status, profileId }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(contract, forKey: .contract); try c.encode(version, forKey: .version)
        try c.encode(status, forKey: .status); try c.encode(profileId, forKey: .profileId)
    }
}

public struct EmbeddingModelChoice: Codable, Equatable, Sendable {
    public let providerId: String
    public let model: String
    /// Nil is the caller's existing legacy path (raw input), never a modern identity.
    public let profileId: String?

    public init(providerId: String, model: String, profileId: String?) {
        self.providerId = providerId
        self.model = model
        self.profileId = profileId
    }
}

public enum EmbeddingRecommendation {
    /// The accepted profile only for a truly fresh install; pending or malformed data never
    /// resets an existing selection.
    public static func initial(evidence e: EmbeddingInstallEvidence,
                               decision d: EmbeddingDecision) throws -> EmbeddingModelChoice? {
        guard d.contract == "embedding-decision", d.version == 1, ["pending", "accepted"].contains(d.status) else {
            throw EmbeddingRecommendationError(code: "invalidDecision")
        }
        guard d.status == "accepted" else {
            guard d.profileId == nil else { throw EmbeddingRecommendationError(code: "invalidDecision") }
            return nil
        }
        guard let id = d.profileId else { throw EmbeddingRecommendationError(code: "invalidDecision") }
        let recommended = try selection(profileId: id) // validated even when this install is preserved
        guard !e.databaseExists, !e.preferencesExist, !e.completedOnboarding, !e.explicitSelection,
              !e.convertedChatOnly else { return nil }
        return recommended
    }

    /// Exact catalog ID → local Ollama plus the profile's model; never inferred from a model name.
    public static func selection(profileId: String) throws -> EmbeddingModelChoice {
        let profile = try EmbeddingProfiles.require(profileId)
        return EmbeddingModelChoice(providerId: ProviderConfig.ollamaId, model: profile.model, profileId: profile.id)
    }

    public static func identity(selection: EmbeddingModelChoice, endpointRevision: String, modelDigest: String?,
                                chunkerVersion: String, effectiveLimit: Int? = nil) throws -> GenerationIdentity {
        guard let id = selection.profileId else { throw EmbeddingRecommendationError(code: "profileRequired") }
        let profile = try EmbeddingProfiles.require(id)
        guard Data(selection.model.utf8) == Data(profile.model.utf8) else {
            throw EmbeddingRecommendationError(code: "profileIdentityMismatch")
        }
        if let effectiveLimit, !(1...profile.maxInputTokens).contains(effectiveLimit) {
            throw EmbeddingRecommendationError(code: "profileIdentityMismatch")
        }
        return GenerationIdentity(providerId: selection.providerId, endpointRevision: endpointRevision,
                                  model: profile.model, modelDigest: modelDigest, dims: profile.dims,
                                  normalization: "l2",
                                  queryFormatVersion: profile.formatVersion(.query, effectiveLimit: effectiveLimit),
                                  docFormatVersion: profile.formatVersion(.document, effectiveLimit: effectiveLimit),
                                  chunkerVersion: chunkerVersion)
    }
}

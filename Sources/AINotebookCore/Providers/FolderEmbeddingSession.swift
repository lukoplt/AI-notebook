import Foundation

/// WP6 background-indexing view of one captured `ProviderEmbeddingSession`.
///
/// The provider session (WP5/WP7) is the single source of truth for endpoint
/// identity, format versions and document/query embedding; this adapter adds
/// only the nonsecret WP6 `EmbeddingSelection` that jobs persist. Later
/// settings changes never alter an in-flight session, and the key lives only
/// inside the provider session's private adapter.
public struct FolderEmbeddingSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Nonsecret identity of the captured space; dims stay nil until a response verifies them
    /// (a named profile knows them up front).
    public let selection: EmbeddingSelection
    /// The shared session every request goes through (document purpose).
    public let provider: ProviderEmbeddingSession

    /// Raw-input capture (`legacy`/`1` formats) from a provider configuration.
    public init(config: ProviderConfig, model: String, apiKey: String?, modelDigest: String?,
                queryFormatVersion: String, docFormatVersion: String, session: URLSession = .shared) throws {
        guard config.type.supportsEmbeddings else { throw IngestionError(code: "unsupportedEndpoint") }
        guard config.enabled else { throw IngestionError(code: "providerDisabled") }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw IngestionError(code: "invalidModel") }
        guard !config.type.isCloud || config.privacyAcknowledged else { throw ProviderError.consentRequired }
        guard !queryFormatVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !docFormatVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IngestionError(code: "invalidValue")
        }
        // Named WP7 formats need a prepared profile session (`init(profileSession:)`).
        try EmbeddingQueryFormat.validate(queryFormatVersion)
        try EmbeddingQueryFormat.validate(docFormatVersion)
        // A raw space pairs one format for both purposes (embedding-raw-format-v2 §2).
        guard queryFormatVersion == docFormatVersion else { throw RetrievalError.unsupportedQueryFormat }
        provider = try ProviderEmbeddingSession.captureRaw(config: config, model: model, apiKey: apiKey, session: session,
                                                           format: docFormatVersion)
        selection = EmbeddingSelection(providerId: config.id, endpointRevision: provider.endpointRevision,
                                       model: model, modelDigest: modelDigest, dims: nil, normalization: "l2",
                                       queryFormatVersion: queryFormatVersion, docFormatVersion: docFormatVersion,
                                       chunkerVersion: "2")
    }

    /// Adapts a prepared WP7 named-profile session; its identity is the selection.
    public init(profileSession: ProviderEmbeddingSession) throws {
        guard profileSession.profile != nil, let identity = profileSession.identity else {
            throw EmbeddingProfileError(code: "unsupportedEmbeddingProfile")
        }
        provider = profileSession
        selection = EmbeddingSelection(identity: identity)
    }

    /// Test seam: a captured selection with an injected raw embedder.
    init(selection: EmbeddingSelection, embedder: any EmbeddingProducing) {
        self.selection = selection
        provider = ProviderEmbeddingSession(client: embedder, model: selection.model,
                                            storageKey: selection.providerId + ":" + selection.model,
                                            endpointRevision: selection.endpointRevision, rawFormat: selection.docFormatVersion)
    }

    public func identity(dims: Int) throws -> GenerationIdentity {
        guard dims > 0 else { throw IngestionError(code: "invalidVector") }
        if let known = selection.dims, known != dims { throw IngestionError(code: "invalidVector") }
        return GenerationIdentity(providerId: selection.providerId, endpointRevision: selection.endpointRevision,
                                  model: selection.model, modelDigest: selection.modelDigest, dims: dims,
                                  normalization: selection.normalization, queryFormatVersion: selection.queryFormatVersion,
                                  docFormatVersion: selection.docFormatVersion, chunkerVersion: selection.chunkerVersion)
    }

    /// Document-purpose embedding through the shared session.
    public func embed(inputs: [String]) async throws -> [[Float]] {
        try await provider.embedDocuments(inputs: inputs)
    }

    /// Every field must match; an unknown dimension matches any known one.
    public static func compatible(_ lhs: EmbeddingSelection, _ rhs: EmbeddingSelection) -> Bool {
        let left = EmbeddingSelection(providerId: lhs.providerId, endpointRevision: lhs.endpointRevision, model: lhs.model,
            modelDigest: lhs.modelDigest, dims: nil, normalization: lhs.normalization, queryFormatVersion: lhs.queryFormatVersion,
            docFormatVersion: lhs.docFormatVersion, chunkerVersion: lhs.chunkerVersion)
        let right = EmbeddingSelection(providerId: rhs.providerId, endpointRevision: rhs.endpointRevision, model: rhs.model,
            modelDigest: rhs.modelDigest, dims: nil, normalization: rhs.normalization, queryFormatVersion: rhs.queryFormatVersion,
            docFormatVersion: rhs.docFormatVersion, chunkerVersion: rhs.chunkerVersion)
        guard left == right else { return false }
        if let a = lhs.dims, let b = rhs.dims { return a == b }
        return true
    }

    public var description: String {
        "FolderEmbeddingSession(providerId: \(selection.providerId), model: \(selection.model))"
    }
    public var debugDescription: String { description }
}

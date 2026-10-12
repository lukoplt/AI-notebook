import Foundation

/// Captures selection, configuration, credentials and limits together on MainActor.
/// A returned session owns its adapter; later settings edits affect only new turns.
public final class ProviderRouter: Sendable {
    private let store: NotebookStore
    private let secrets: any SecretStoring
    private let selection: any ProviderSelectionReading
    private let session: URLSession

    public init(store: NotebookStore, secrets: any SecretStoring,
                selection: any ProviderSelectionReading, session: URLSession = .shared) {
        self.store = store
        self.secrets = secrets
        self.selection = selection
        self.session = session
    }

    private struct Capture: Sendable {
        let config: ProviderConfig
        let key: String?
        let model: String
        let limits: ProviderModelLimits?
    }

    @MainActor
    private func config(_ providerId: String) throws -> ProviderConfig {
        guard let value = try store.provider(id: providerId) else { throw ProviderConfigurationError.missingProvider }
        guard value.enabled else { throw ProviderConfigurationError.disabledProvider }
        var normalized = value
        normalized.baseURL = try ProviderAPIRoot.normalize(value.baseURL)
        return normalized
    }

    private func apiKey(for config: ProviderConfig) throws -> String? {
        config.type.isCloud ? try secrets.load(providerId: config.id) : nil
    }

    private func checkConsent(_ config: ProviderConfig) throws {
        if config.type.isCloud && !config.privacyAcknowledged { throw ProviderError.consentRequired }
    }

    private static func parseCompositeKey(_ model: String) -> (providerId: String, rawModel: String)? {
        guard let colon = model.firstIndex(of: ":"), colon != model.startIndex else { return nil }
        return (String(model[..<colon]), String(model[model.index(after: colon)...]))
    }

    @MainActor
    private func isQualified(_ value: (providerId: String, rawModel: String), selectedId: String) throws -> Bool {
        // Persisted/selected IDs and UUID provider keys remain recognizable if deleted.
        if value.providerId == selectedId || UUID(uuidString: value.providerId) != nil { return true }
        return try store.provider(id: value.providerId) != nil
    }

    @MainActor
    private func captureChat(model: String?, legacyDirect: Bool = false) throws -> Capture {
        var (providerId, activeModel) = selection.chatSelection()
        if let model {
            if let parsed = Self.parseCompositeKey(model), try isQualified(parsed, selectedId: providerId) {
                (providerId, activeModel) = parsed
            } else if !legacyDirect {
                activeModel = model
            }
        }
        return try capture(providerId: providerId, model: activeModel)
    }

    @MainActor
    private func capture(providerId: String, model: String) throws -> Capture {
        let cfg = try config(providerId)
        try checkConsent(cfg)
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderConfigurationError.invalidLimits
        }
        return Capture(config: cfg, key: try apiKey(for: cfg), model: model,
                       limits: try store.providerModelLimits(providerId: providerId, model: model))
    }

    private func ollamaClient(baseURL: String) throws -> OllamaClient {
        let root = try ProviderAPIRoot.normalize(baseURL)
        guard let url = URL(string: root) else { throw ProviderConfigurationError.invalidBaseURL }
        return OllamaClient(baseURL: url, session: session)
    }

    private func chatAdapter(for capture: Capture) throws -> any ChatStreaming {
        let cfg = capture.config
        switch cfg.type {
        case .ollama: return try ollamaClient(baseURL: cfg.baseURL)
        case .anthropic: return AnthropicChatAdapter(baseURL: cfg.baseURL, apiKey: capture.key ?? "", session: session)
        case .openai, .openaiCompatible: return OpenAIChatAdapter(baseURL: cfg.baseURL, apiKey: capture.key, session: session)
        case .openwebui: return OpenWebUIChatAdapter(baseURL: cfg.baseURL, apiKey: capture.key, session: session)
        }
    }

    private func resolvedLimits(_ captured: Capture, refresh: Bool = false) async throws -> ProviderModelLimits {
        try Task.checkCancellation()
        if let limits = captured.limits, limits.source == "user" || !refresh { return limits }
        let cfg = captured.config
        var window: Int?
        var listed = false
        if refresh, ProviderLimitPolicy.listingTypes.contains(cfg.type) {
            // provider-listing-limits-v1: an explicit refresh reads the model listing; any failure
            // other than cancellation leaves the window unknown.
            do {
                let data = try await ProviderDiscovery.listing(type: cfg.type, baseURL: cfg.baseURL,
                                                               apiKey: captured.key, session: session)
                try Task.checkCancellation()
                window = try ProviderLimitPolicy.contextWindow(fromModelListing: data, model: captured.model)
                listed = window != nil
            } catch {
                try Task.checkCancellation()
                if (error as? URLError)?.code == .cancelled { throw error }
            }
        } else if cfg.type == .ollama {
            do {
                let data = try await ollamaClient(baseURL: cfg.baseURL).show(model: captured.model)
                try Task.checkCancellation()
                window = try ProviderLimitPolicy.contextWindow(fromOllamaShow: data)
            } catch {
                try Task.checkCancellation()
                guard case let OllamaError.httpStatus(code, _) = error,
                      [404, 405, 501].contains(code) else { throw error }
            }
        }
        let automatic = try ProviderLimitPolicy.automatic(providerId: cfg.id, type: cfg.type,
                                                          model: captured.model, contextWindow: window, listed: listed)
        return try await MainActor.run {
            // Explicit user edits still win metadata refresh races, even across
            // endpoint edits. Automatic results must stay with their captured root.
            if let current = try self.store.providerModelLimits(providerId: cfg.id, model: captured.model),
               current.source == "user" { return current }
            guard let currentConfig = try self.store.provider(id: cfg.id),
                  ProviderLimitPolicy.hasSameEndpoint(cfg, currentConfig) else { return automatic }
            try self.store.saveProviderModelLimits(automatic)
            // The conditional upsert protects a user edit made during metadata I/O.
            return try self.store.providerModelLimits(providerId: cfg.id, model: captured.model) ?? automatic
        }
    }

    private func prepare(_ captured: Capture) async throws -> ProviderChatSession {
        let adapter = try chatAdapter(for: captured)
        let limits = try await resolvedLimits(captured)
        return ProviderChatSession(providerId: captured.config.id, model: captured.model, limits: limits, adapter: adapter)
    }

    public func resolveLimits(providerId: String, model: String, refresh: Bool = false) async throws -> ProviderModelLimits {
        let captured = try await capture(providerId: providerId, model: model)
        return try await resolvedLimits(captured, refresh: refresh)
    }

    public func discoverModels(providerId: String) async throws -> [ProviderModelInfo] {
        let (cfg, key) = try await MainActor.run {
            let cfg = try self.config(providerId)
            return (cfg, try self.apiKey(for: cfg))
        }
        let models = try await ProviderDiscovery.models(type: cfg.type, baseURL: cfg.baseURL, apiKey: key, session: session)
        // provider-listing-limits-v1: advertised windows become automatic limits (never over a user
        // choice, and only while the endpoint that answered is still the configured one).
        let listed = models.filter { $0.contextWindow != nil }
        if ProviderLimitPolicy.listingTypes.contains(cfg.type), !listed.isEmpty {
            try await MainActor.run {
                guard let current = try self.store.provider(id: cfg.id), ProviderLimitPolicy.hasSameEndpoint(cfg, current) else { return }
                for model in listed {
                    guard let limits = try? ProviderLimitPolicy.automatic(providerId: cfg.id, type: cfg.type, model: model.id,
                                                                         contextWindow: model.contextWindow, listed: true) else { continue }
                    try self.store.saveProviderModelLimits(limits)
                }
            }
        }
        return models
    }

    public func probe(type: ProviderType, baseURL: String, apiKey: String?) async throws -> ProviderProbeResult {
        try await ProviderDiscovery.probe(type: type, baseURL: baseURL, apiKey: apiKey, session: session)
    }
}

extension ProviderRouter: ChatSessionPreparing {
    public func prepareChat(model: String? = nil) async throws -> ProviderChatSession {
        let captured = try await captureChat(model: model)
        return try await prepare(captured)
    }
}

extension ProviderRouter: ChatStreaming {
    public func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        directStream(model: model, messages: messages, options: nil)
    }

    public func stream(model: String, messages: [ChatTurn], options: ChatRequestOptions) -> AsyncThrowingStream<String, Error> {
        directStream(model: model, messages: messages, options: options)
    }

    private func directStream(model: String, messages: [ChatTurn], options: ChatRequestOptions?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try options?.validate()
                    let captured = try await self.captureChat(model: model, legacyDirect: true)
                    var prepared = try await self.prepare(captured)
                    if let options { prepared = try prepared.withOptions(options) }
                    for try await token in prepared.stream(messages: messages) {
                        try Task.checkCancellation()
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension ProviderRouter: EmbeddingProducing {
    public func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        let captured = try await MainActor.run {
            let target = Self.parseCompositeKey(model)
            let (id, activeModel) = target.map { ($0.providerId, $0.rawModel) } ?? self.selection.embeddingSelection()
            let cfg = try self.config(id)
            try self.checkConsent(cfg)
            // Validate before unsupportedEndpoint, with no silent endpoint substitution.
            _ = try ProviderAPIRoot.build(type: cfg.type, baseURL: cfg.baseURL, endpoint: .embeddings)
            return Capture(config: cfg, key: try self.apiKey(for: cfg), model: activeModel, limits: nil)
        }
        try Task.checkCancellation()
        switch captured.config.type {
        case .openai, .openaiCompatible:
            return try await OpenAIEmbeddingAdapter(baseURL: captured.config.baseURL, apiKey: captured.key, session: session)
                .embed(model: captured.model, inputs: inputs)
        case .ollama:
            let vectors = try await ollamaClient(baseURL: captured.config.baseURL).embed(model: captured.model, input: inputs)
            try Task.checkCancellation()
            return vectors.map { $0.map(Float.init) }
        case .anthropic, .openwebui:
            throw ProviderConfigurationError.unsupportedEndpoint
        }
    }
}

extension ProviderRouter: EmbeddingSessionPreparing {
    /// Captures provider configuration, credential and raw model in one MainActor
    /// step, before any suspension that could observe a Settings edit. Format,
    /// consent, capability and endpoint identity are checked before a request
    /// can be constructed; there is no fallback provider.
    public func prepareEmbedding(identity: GenerationIdentity) async throws -> ProviderEmbeddingSession {
        if let profileId = OllamaBenchmarkClient.profileId(fromFormatVersion: identity.queryFormatVersion) {
            return try await prepareNamedProfileEmbedding(identity: identity, profileId: profileId)
        }
        try EmbeddingQueryFormat.validate(identity.queryFormatVersion)
        let captured = try await MainActor.run { try self.captureEmbedding(identity: identity) }
        try Task.checkCancellation()
        return ProviderEmbeddingSession(client: try embeddingAdapter(for: captured.capture),
                                        model: captured.capture.model, storageKey: captured.storageKey,
                                        endpointRevision: captured.endpointRevision,
                                        legacyEndpointUnverified: captured.legacy, rawFormat: identity.queryFormatVersion)
    }

    private struct EmbeddingCapture: Sendable {
        let capture: Capture
        let storageKey: String
        let endpointRevision: String
        let legacy: Bool
    }

    @MainActor
    private func captureEmbedding(identity: GenerationIdentity) throws -> EmbeddingCapture {
        let legacy = identity.providerId == "legacy"
        let target = legacy ? try legacyTarget(storedKey: identity.model)
                            : (providerId: identity.providerId, rawModel: identity.model)
        let cfg = try config(target.providerId)
        try checkConsent(cfg)
        guard cfg.type.supportsEmbeddings else { throw ProviderConfigurationError.unsupportedEndpoint }
        _ = try ProviderAPIRoot.build(type: cfg.type, baseURL: cfg.baseURL, endpoint: .embeddings)
        // The fingerprint excludes the secret; adapter identity still captures the key.
        let revision = EmbeddingEndpointRevision.make(type: cfg.type, normalizedRoot: cfg.baseURL)
        if !legacy && revision != identity.endpointRevision { throw RetrievalError.endpointRevisionMismatch }
        return EmbeddingCapture(
            capture: Capture(config: cfg, key: try apiKey(for: cfg), model: target.rawModel, limits: nil),
            storageKey: legacy ? identity.model : target.providerId + ":" + target.rawModel,
            endpointRevision: revision, legacy: legacy)
    }

    /// Legacy keys: a registered provider-id prefix is split at the first colon
    /// and the tagged raw model stays byte-for-byte intact. A prefix that is a
    /// provider id by shape (UUID) or a provider type, but not registered, names
    /// a removed provider and stays lexical-only. Any other key — including a bare
    /// Ollama tag such as `nomic-embed-text:latest` — is, whole, a bare model of
    /// today's selected embedding provider.
    @MainActor
    private func legacyTarget(storedKey: String) throws -> (providerId: String, rawModel: String) {
        if let colon = storedKey.firstIndex(of: ":"), colon != storedKey.startIndex {
            let prefix = String(storedKey[..<colon])
            if try store.provider(id: prefix) != nil {
                return (prefix, String(storedKey[storedKey.index(after: colon)...]))
            }
            if UUID(uuidString: prefix) != nil || ProviderType(rawValue: prefix) != nil {
                throw RetrievalError.legacyProviderUnresolved
            }
        }
        return (selection.embeddingSelection().providerId, storedKey)
    }

    /// Builds an adapter owning only captured values; no settings reference.
    private func embeddingAdapter(for captured: Capture) throws -> any EmbeddingProducing {
        try ProviderEmbeddingSession.rawAdapter(type: captured.config.type, root: captured.config.baseURL,
                                                apiKey: captured.key, session: session)
    }
}

/// A named WP7 profile prepared once on a captured provider snapshot.
public struct PreparedEmbeddingProfile: Sendable {
    public let identity: GenerationIdentity
    public let session: ProviderEmbeddingSession
    public let effectiveLimit: Int

    public init(identity: GenerationIdentity, session: ProviderEmbeddingSession, effectiveLimit: Int) {
        self.identity = identity
        self.session = session
        self.effectiveLimit = effectiveLimit
    }
}

extension ProviderRouter {
    /// Single discovery API for benchmark, Settings and fresh imports: snapshots the
    /// provider row/root exactly once, then `/api/tags` + `/api/show` on that captured
    /// root. Only an enabled, consented, embedding-capable Ollama provider qualifies;
    /// there is never a substituted provider or raw-input fallback.
    public func prepareEmbeddingProfile(providerId: String, profileId: String,
                                        observer: (any EmbeddingTelemetryObserving)? = nil,
                                        counter: (any ExactTokenCounting)? = nil) async throws -> PreparedEmbeddingProfile {
        let profile = try EmbeddingProfiles.require(profileId)
        let snapshot = try await MainActor.run { try self.embeddingProviderSnapshot(providerId) }
        try Task.checkCancellation()
        guard snapshot.type == .ollama, snapshot.enabled, snapshot.consented, snapshot.embeddingCapable else {
            throw EmbeddingProfileError(code: "unsupportedEmbeddingProfile")
        }
        let client = try benchmarkClient(root: snapshot.root)
        let prepared = try await OllamaBenchmarkClient.prepareProfile(profile, provider: snapshot, client: client)
        let session = ProviderEmbeddingSession(
            storageKey: providerId + ":" + profile.model, endpointRevision: prepared.identity.endpointRevision,
            identity: prepared.identity, profile: profile,
            pipeline: StrictEmbeddingPipeline(transport: client, counter: counter, observer: observer),
            effectiveLimit: prepared.effectiveLimit)
        return PreparedEmbeddingProfile(identity: prepared.identity, session: session,
                                        effectiveLimit: prepared.effectiveLimit)
    }

    /// Re-opens a stored named-profile identity: exact catalog profile, captured
    /// endpoint check, `/api/tags` digest revalidation only (ctx parsed, never re-probed).
    public func prepareEmbeddingProfileSession(identity: GenerationIdentity,
                                               observer: (any EmbeddingTelemetryObserving)? = nil,
                                               counter: (any ExactTokenCounting)? = nil) async throws -> ProviderEmbeddingSession {
        guard let profileId = OllamaBenchmarkClient.profileId(fromFormatVersion: identity.queryFormatVersion) else {
            throw EmbeddingProfileError(code: "profileIdentityMismatch")
        }
        return try await prepareNamedProfileEmbedding(identity: identity, profileId: profileId,
                                                      observer: observer, counter: counter)
    }

    fileprivate func prepareNamedProfileEmbedding(identity: GenerationIdentity, profileId: String,
                                                  observer: (any EmbeddingTelemetryObserving)? = nil,
                                                  counter: (any ExactTokenCounting)? = nil) async throws -> ProviderEmbeddingSession {
        let profile = try EmbeddingProfiles.require(profileId)
        try profile.validateIdentity(model: identity.model, dims: identity.dims,
                                     queryFormatVersion: identity.queryFormatVersion,
                                     docFormatVersion: identity.docFormatVersion)
        guard identity.providerId != "legacy" else { throw EmbeddingProfileError(code: "profileIdentityMismatch") }
        let snapshot = try await MainActor.run { () throws -> EmbeddingProviderSnapshot in
            let snapshot = try self.embeddingProviderSnapshot(identity.providerId)
            guard snapshot.type == .ollama, snapshot.enabled, snapshot.consented, snapshot.embeddingCapable else {
                throw EmbeddingProfileError(code: "unsupportedEmbeddingProfile")
            }
            let revision = EmbeddingEndpointRevision.make(type: snapshot.type, normalizedRoot: snapshot.root)
            guard revision == identity.endpointRevision else { throw RetrievalError.endpointRevisionMismatch }
            return snapshot
        }
        try Task.checkCancellation()
        let client = try benchmarkClient(root: snapshot.root)
        let limit = try await OllamaBenchmarkClient.revalidate(identity, profile: profile, client: client)
        return ProviderEmbeddingSession(
            storageKey: identity.providerId + ":" + identity.model, endpointRevision: identity.endpointRevision,
            identity: identity, profile: profile,
            pipeline: StrictEmbeddingPipeline(transport: client, counter: counter, observer: observer),
            effectiveLimit: limit)
    }

    @MainActor
    private func embeddingProviderSnapshot(_ providerId: String) throws -> EmbeddingProviderSnapshot {
        guard let row = try store.provider(id: providerId) else { throw ProviderConfigurationError.missingProvider }
        return EmbeddingProviderSnapshot(providerId: row.id, type: row.type,
                                         root: try ProviderAPIRoot.normalize(row.baseURL), enabled: row.enabled,
                                         consented: !row.type.isCloud || row.privacyAcknowledged,
                                         embeddingCapable: row.type.supportsEmbeddings)
    }

    private func benchmarkClient(root: String) throws -> OllamaBenchmarkClient {
        guard let url = URL(string: root) else { throw ProviderConfigurationError.invalidBaseURL }
        return OllamaBenchmarkClient(baseURL: url, session: session)
    }
}

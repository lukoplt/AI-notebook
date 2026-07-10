import Foundation

/// Routes `ChatStreaming` / `EmbeddingProducing` calls to the active
/// provider. Adapters are cheap value types constructed per call and the API
/// key is read from the secret store each time: no cache, no staleness.
///
/// The two protocols are handled differently:
///
/// - `stream` (chat): the `model` parameter is ignored. It reads the live
///   (provider, model) selection on every call, since chat callers capture
///   their model at launch and the router is what makes Settings changes
///   effective immediately.
/// - `embed`: the `model` parameter is HONORED as a composite
///   `"{providerId}:{rawModel}"` key when it contains a colon. `Embedder`
///   snapshots this composite key once per drain for storage (`FR-A11`); if
///   the router instead re-sampled the live selection, a settings change
///   mid-drain could route the network call to a NEW provider while rows
///   get labeled with the OLD key — silently mislabeled vectors. Honoring
///   the passed key keeps the storage label and the network call from ever
///   diverging within a drain. Callers that pass a plain (colon-free) model
///   string — the legacy/direct convenience path used by some tests — still
///   get today's live-selection behavior.
public final class ProviderRouter: @unchecked Sendable {
    private let store: NotebookStore
    private let secrets: any SecretStoring
    private let selection: any ProviderSelectionReading
    private let session: URLSession

    public init(
        store: NotebookStore,
        secrets: any SecretStoring,
        selection: any ProviderSelectionReading,
        session: URLSession = .shared
    ) {
        self.store = store
        self.secrets = secrets
        self.selection = selection
        self.session = session
    }

    // MARK: - Resolution

    private func config(_ providerId: String) async -> ProviderConfig {
        let storeRef = store
        let cfg = try? await MainActor.run { try storeRef.provider(id: providerId) }
        return (cfg ?? nil) ?? .builtInOllama()
    }

    private func apiKey(for cfg: ProviderConfig) -> String? {
        guard cfg.type.isCloud else { return nil }
        return (try? secrets.load(providerId: cfg.id)) ?? nil
    }

    /// Splits a composite `"{providerId}:{rawModel}"` embedding key on the
    /// FIRST colon only, so Ollama tags that themselves contain colons
    /// (`llama3.2:3b`) survive intact in `rawModel`. Returns `nil` when the
    /// string has no colon, or the prefix before the first colon is empty —
    /// both signal "not a composite key" (legacy/direct callers), and the
    /// caller should fall back to the live selection.
    private static func parseCompositeKey(_ model: String) -> (providerId: String, rawModel: String)? {
        guard let colonIndex = model.firstIndex(of: ":") else { return nil }
        let providerId = String(model[model.startIndex..<colonIndex])
        guard !providerId.isEmpty else { return nil }
        let rawModel = String(model[model.index(after: colonIndex)...])
        return (providerId, rawModel)
    }

    private func ollamaClient(baseURL: String) -> OllamaClient {
        let url = URL(string: ProviderWire.trimBase(baseURL))
            ?? URL(string: ProviderType.ollama.defaultBaseURL)!
        return OllamaClient(baseURL: url, session: session)
    }

    private func chatAdapter(for cfg: ProviderConfig) -> any ChatStreaming {
        switch cfg.type {
        case .ollama:
            ollamaClient(baseURL: cfg.baseURL)
        case .anthropic:
            AnthropicChatAdapter(baseURL: cfg.baseURL, apiKey: apiKey(for: cfg) ?? "", session: session)
        case .openai, .openaiCompatible:
            OpenAIChatAdapter(baseURL: cfg.baseURL, apiKey: apiKey(for: cfg), session: session)
        case .openwebui:
            OpenWebUIChatAdapter(baseURL: cfg.baseURL, apiKey: apiKey(for: cfg), session: session)
        }
    }
}

// MARK: - ChatStreaming

extension ProviderRouter: ChatStreaming {
    public func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (providerId, activeModel) = self.selection.chatSelection()
                    let cfg = await self.config(providerId)
                    // FR-A8 defense-in-depth: without consent, a cloud/network
                    // provider must not receive data — checked here (not just
                    // at the add-provider gate) so a picker re-selection can
                    // never bypass it. The built-in Ollama fallback config
                    // is never cloud, so it is unaffected.
                    guard !(cfg.type.isCloud && !cfg.privacyAcknowledged) else {
                        throw ProviderError.consentRequired
                    }
                    let adapter = self.chatAdapter(for: cfg)
                    for try await token in adapter.stream(model: activeModel, messages: messages) {
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - EmbeddingProducing

extension ProviderRouter: EmbeddingProducing {
    public func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        let providerId: String
        let activeModel: String
        if let parsed = Self.parseCompositeKey(model) {
            (providerId, activeModel) = parsed
        } else {
            (providerId, activeModel) = selection.embeddingSelection()
        }
        let cfg = await config(providerId)
        // FR-A8 defense-in-depth: same gate as `stream` above.
        guard !(cfg.type.isCloud && !cfg.privacyAcknowledged) else {
            throw ProviderError.consentRequired
        }
        switch cfg.type {
        case .openai, .openaiCompatible:
            return try await OpenAIEmbeddingAdapter(
                baseURL: cfg.baseURL, apiKey: apiKey(for: cfg), session: session
            ).embed(model: activeModel, inputs: inputs)
        case .ollama:
            let doubles = try await ollamaClient(baseURL: cfg.baseURL)
                .embed(model: activeModel, input: inputs)
            return doubles.map { $0.map(Float.init) }
        case .anthropic, .openwebui:
            // Chat-only types never appear in the embedding picker; if the
            // selection points here anyway, fall back to local Ollama
            // (Windows parity — same treatment as Anthropic on Windows).
            let doubles = try await ollamaClient(baseURL: ProviderType.ollama.defaultBaseURL)
                .embed(model: activeModel, input: inputs)
            return doubles.map { $0.map(Float.init) }
        }
    }
}

// MARK: - Settings-UI surface

extension ProviderRouter {

    /// Models for the pickers. UI-safe: failures collapse to an empty list
    /// (Anthropic gets its static fallback list per FR-A3).
    public func listModels(providerId: String) async -> [ProviderModelInfo] {
        let cfg = await config(providerId)
        do {
            switch cfg.type {
            case .ollama:
                return try await ollamaClient(baseURL: cfg.baseURL).listModels()
                    .map { ProviderModelInfo(id: $0.name) }
                    .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
            case .anthropic:
                return try await AnthropicChatAdapter.listModels(
                    baseURL: cfg.baseURL, apiKey: apiKey(for: cfg) ?? "", session: session)
            case .openai, .openaiCompatible:
                return try await OpenAIChatAdapter.listModels(
                    baseURL: cfg.baseURL, apiKey: apiKey(for: cfg), session: session)
            case .openwebui:
                return try await OpenWebUIChatAdapter.listModels(
                    baseURL: cfg.baseURL, apiKey: apiKey(for: cfg), session: session)
            }
        } catch {
            return cfg.type == .anthropic ? AnthropicChatAdapter.defaultModels : []
        }
    }

    /// nil = success. Otherwise returns the underlying error — 401, HTTP
    /// failures, and network errors all surface (FR-A9; Phase 1 lesson: a
    /// typo'd LAN URL must not show a green checkmark). The UI maps
    /// `ProviderError` cases to localized strings.
    public func testConnection(type: ProviderType, baseURL: String, apiKey: String?) async -> Error? {
        do {
            switch type {
            case .ollama:
                _ = try await ollamaClient(baseURL: baseURL).listModels()
            case .anthropic:
                _ = try await AnthropicChatAdapter.listModels(
                    baseURL: baseURL, apiKey: apiKey ?? "", session: session)
            case .openai, .openaiCompatible:
                _ = try await OpenAIChatAdapter.listModels(
                    baseURL: baseURL, apiKey: apiKey, session: session)
            case .openwebui:
                _ = try await OpenWebUIChatAdapter.listModels(
                    baseURL: baseURL, apiKey: apiKey, session: session)
            }
            return nil
        } catch {
            return error
        }
    }
}

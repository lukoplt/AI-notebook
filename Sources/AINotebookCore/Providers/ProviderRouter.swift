import Foundation

/// Routes `ChatStreaming` / `EmbeddingProducing` calls to the active
/// provider. Reads the live (provider, model) selection on every call — the
/// `model` parameter passed by engines is ignored (they capture it at
/// launch; the router is what makes Settings changes effective immediately).
/// Adapters are cheap value types constructed per call and the API key is
/// read from the secret store each time: no cache, no staleness.
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
        let (providerId, activeModel) = selection.embeddingSelection()
        let cfg = await config(providerId)
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

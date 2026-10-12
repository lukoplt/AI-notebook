import Foundation

/// OpenWebUI network adapter. OpenWebUI aggregates models (local Ollama,
/// cloud backends, functions) behind an OpenAI-shape API rooted at /api,
/// NOT /v1: POST {base}/api/chat/completions, GET {base}/api/models.
/// Bearer key optional — instances may run with auth disabled. Chat-only:
/// OpenWebUI exposes no OpenAI-compatible embeddings endpoint.
public struct OpenWebUIChatAdapter: ChatStreaming {
    let baseURL: String
    let apiKey: String?
    let session: URLSession

    public init(baseURL: String, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        stream(model: model, messages: messages, options: .defaults)
    }

    public func stream(model: String, messages: [ChatTurn], options: ChatRequestOptions)
        -> AsyncThrowingStream<String, Error> {
        let request: URLRequest
        do {
            request = try ProviderWire.openAIStyleChatRequest(
                base: baseURL, type: .openwebui,
                apiKey: apiKey, model: model, messages: messages, options: options
            )
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return ProviderWire.openAIStyleStream(request: request, session: session)
    }

    public static func listModels(
        baseURL: String, apiKey: String?, session: URLSession = .shared
    ) async throws -> [ProviderModelInfo] {
        try await ProviderWire.listOpenAIStyleModels(
            base: baseURL, type: .openwebui, apiKey: apiKey, session: session
        )
    }
}

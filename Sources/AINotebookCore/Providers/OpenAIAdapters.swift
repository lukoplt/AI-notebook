import Foundation

/// OpenAI-compatible streaming chat adapter (OpenAI, LM Studio, OpenRouter,
/// vLLM). The system turn stays in the messages array as role:"system".
/// Covers both the `openai` and `openai_compatible` provider types.
public struct OpenAIChatAdapter: ChatStreaming {
    let baseURL: String
    let apiKey: String?
    let session: URLSession

    public init(baseURL: String, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let request: URLRequest
        do {
            request = try ProviderWire.openAIStyleChatRequest(
                base: baseURL, path: "/v1/chat/completions",
                apiKey: apiKey, model: model, messages: messages
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
            base: baseURL, path: "/v1/models", apiKey: apiKey, session: session
        )
    }
}

/// `POST {base}/v1/embeddings` — OpenAI and compatible servers.
public struct OpenAIEmbeddingAdapter: EmbeddingProducing {
    let baseURL: String
    let apiKey: String?
    let session: URLSession

    public init(baseURL: String, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    private struct RequestBody: Encodable {
        let model: String
        let input: [String]
    }

    private struct ResponseBody: Decodable {
        struct Item: Decodable { let embedding: [Double] }
        let data: [Item]
    }

    public func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        var req = URLRequest(url: try ProviderWire.url(base: baseURL, path: "/v1/embeddings"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(RequestBody(model: model, input: inputs))
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse,
           let err = ProviderWire.error(
            forStatus: http.statusCode,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
            body: String(data: data, encoding: .utf8) ?? ""
           ) {
            throw err
        }
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw ProviderError.decoding("Unexpected /embeddings response shape")
        }
        return decoded.data.map { $0.embedding.map(Float.init) }
    }
}

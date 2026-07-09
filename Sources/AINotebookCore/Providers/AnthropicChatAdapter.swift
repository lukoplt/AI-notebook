import Foundation

/// Anthropic Messages API streaming adapter. Differs from the OpenAI shape:
/// the system prompt is a top-level `system` field (never a message), auth is
/// `x-api-key` + `anthropic-version`, and a `stop_reason` of "refusal" is
/// surfaced as `ProviderError.refusal` instead of an empty answer (FR-A10).
public struct AnthropicChatAdapter: ChatStreaming {
    static let apiVersion = "2023-06-01"
    static let maxTokens = 8192

    /// Offered when GET /v1/models is unreachable (roadmap FR-A3 fallback).
    public static let defaultModels: [ProviderModelInfo] = [
        ProviderModelInfo(id: "claude-opus-4-8", displayName: "Claude Opus 4.8"),
        ProviderModelInfo(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
        ProviderModelInfo(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
        ProviderModelInfo(id: "claude-fable-5", displayName: "Claude Fable 5")
    ]

    let baseURL: String
    let apiKey: String
    let session: URLSession

    public init(baseURL: String, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    private struct RequestBody: Encodable {
        let model: String
        let maxTokens: Int
        let system: String?
        let messages: [ProviderWire.WireMessage]
        let stream: Bool
        enum CodingKeys: String, CodingKey {
            case model, system, messages, stream
            case maxTokens = "max_tokens"
        }
    }

    func makeRequest(model: String, messages: [ChatTurn]) throws -> URLRequest {
        let systemTexts = messages.filter { $0.role == .system }.map(\.content)
        let system = systemTexts.isEmpty ? nil : systemTexts.joined(separator: "\n\n")
        let wire = messages
            .filter { $0.role != .system }
            .map { ProviderWire.WireMessage(role: ProviderWire.wireRole($0.role), content: $0.content) }

        var req = URLRequest(url: try ProviderWire.url(base: baseURL, path: "/v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONEncoder().encode(RequestBody(
            model: model, maxTokens: Self.maxTokens, system: system, messages: wire, stream: true
        ))
        return req
    }

    public func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(model: model, messages: messages)
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse,
                       let err = ProviderWire.error(
                        forStatus: http.statusCode,
                        retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                        body: ""
                       ) {
                        continuation.finish(throwing: err)
                        return
                    }
                    for try await line in bytes.lines {
                        guard let payload = SSE.dataPayload(of: line),
                              let event = SSE.anthropicEvent(inPayload: payload)
                        else { continue }
                        switch event {
                        case .textDelta(let text):
                            continuation.yield(text)
                        case .stopReason(let reason):
                            if reason == "refusal" {
                                continuation.finish(throwing: ProviderError.refusal)
                                return
                            }
                        case .messageStop:
                            continuation.finish()
                            return
                        case .other:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct ModelsResponse: Decodable {
        struct Item: Decodable {
            let id: String
            let displayName: String?
            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }
        }
        let data: [Item]
    }

    /// Throws on any failure (401 → .auth, network → URLError). The router
    /// substitutes `defaultModels` for the picker path only.
    public static func listModels(
        baseURL: String, apiKey: String, session: URLSession = .shared
    ) async throws -> [ProviderModelInfo] {
        var req = URLRequest(url: try ProviderWire.url(base: baseURL, path: "/v1/models"))
        req.httpMethod = "GET"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse,
           let err = ProviderWire.error(
            forStatus: http.statusCode,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
            body: String(data: data, encoding: .utf8) ?? ""
           ) {
            throw err
        }
        guard let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            throw ProviderError.decoding("Unexpected /v1/models response shape")
        }
        return decoded.data.map { ProviderModelInfo(id: $0.id, displayName: $0.displayName) }
    }
}

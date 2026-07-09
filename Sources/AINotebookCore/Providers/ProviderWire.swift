import Foundation

/// Shared request building, status mapping, and the single OpenAI-shape SSE
/// stream runner used by the OpenAI, OpenAI-compatible, and OpenWebUI
/// adapters. Networking is allowed here: this file lives under Providers/,
/// which the core-ci privacy-grep job allowlists.
enum ProviderWire {

    static func trimBase(_ baseURL: String) -> String {
        var s = baseURL
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func url(base: String, path: String) throws -> URL {
        let trimmed = trimBase(base)
        guard !trimmed.isEmpty, let url = URL(string: trimmed + path) else {
            throw ProviderError.decoding("Invalid base URL: '\(base)'")
        }
        return url
    }

    static func wireRole(_ role: ChatRole) -> String {
        switch role {
        case .system: "system"
        case .assistant: "assistant"
        case .user: "user"
        }
    }

    /// nil for 2xx; otherwise the FR-A10 mapping.
    static func error(forStatus code: Int, retryAfter: String?, body: String) -> ProviderError? {
        switch code {
        case 200..<300: nil
        case 401: .auth("Invalid API key (401).")
        case 429: .rateLimit(retryAfterSeconds: retryAfter.flatMap(Double.init))
        default: .http(code: code, body: body)
        }
    }

    struct WireMessage: Encodable {
        let role: String
        let content: String
    }

    private struct OpenAIChatBody: Encodable {
        let model: String
        let messages: [WireMessage]
        let stream: Bool
    }

    static func openAIStyleChatRequest(
        base: String,
        path: String,
        apiKey: String?,
        model: String,
        messages: [ChatTurn]
    ) throws -> URLRequest {
        var req = URLRequest(url: try url(base: base, path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let wire = messages.map { WireMessage(role: wireRole($0.role), content: $0.content) }
        req.httpBody = try JSONEncoder().encode(OpenAIChatBody(model: model, messages: wire, stream: true))
        return req
    }

    /// The one OpenAI-shape SSE runner: send, map status, split lines, parse
    /// deltas, honor [DONE]. Task cancellation propagates via onTermination.
    static func openAIStyleStream(request: URLRequest, session: URLSession) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse,
                       let err = error(
                        forStatus: http.statusCode,
                        retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                        body: ""
                       ) {
                        continuation.finish(throwing: err)
                        return
                    }
                    for try await line in bytes.lines {
                        guard let payload = SSE.dataPayload(of: line) else { continue }
                        if payload == SSE.done { break }
                        for token in SSE.openAITokens(inPayload: payload) {
                            continuation.yield(token)
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
            let name: String?
        }
        let data: [Item]
    }

    /// GET {base}{path} → {"data":[{"id", "name"?}]}. Throws on ANY failure —
    /// 401 → .auth, other statuses → .http, network errors → URLError.
    /// Sorted case-insensitively by label.
    static func listOpenAIStyleModels(
        base: String,
        path: String,
        apiKey: String?,
        session: URLSession
    ) async throws -> [ProviderModelInfo] {
        var req = URLRequest(url: try url(base: base, path: path))
        req.httpMethod = "GET"
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse,
           let err = error(
            forStatus: http.statusCode,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
            body: String(data: data, encoding: .utf8) ?? ""
           ) {
            throw err
        }
        guard let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            throw ProviderError.decoding("Unexpected /models response shape")
        }
        return decoded.data
            .map { ProviderModelInfo(id: $0.id, displayName: $0.name) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}

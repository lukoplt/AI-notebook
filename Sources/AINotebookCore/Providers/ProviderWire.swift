import Foundation

/// Shared request building, status mapping, and the single OpenAI-shape SSE
/// stream runner used by the OpenAI, OpenAI-compatible, and OpenWebUI
/// adapters. Networking is allowed here: this file lives under Providers/,
/// which the core-ci privacy-grep job allowlists.
enum ProviderWire {

    // Kept for the existing router until Task 6 replaces its config capture.
    // Every transport request validates with ProviderAPIRoot before dispatch.
    static func trimBase(_ baseURL: String) -> String {
        var root = baseURL
        while root.hasSuffix("/") { root.removeLast() }
        return root
    }

    /// Auxiliary Ollama endpoints use the same exact-root validation.
    static func url(base: String, path: String) throws -> URL {
        let root = try ProviderAPIRoot.normalize(base)
        guard let url = URL(string: root + path) else {
            throw ProviderConfigurationError.invalidBaseURL
        }
        return url
    }

    static func canonicalMessages(_ turns: [ChatTurn]) -> [ChatTurn] {
        let systems = turns.filter { $0.role == .system }.map(\.content)
        let rest = turns.filter { $0.role != .system }
        return systems.isEmpty ? rest
            : [.init(role: .system, content: systems.joined(separator: "\n\n"))] + rest
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

    static func readErrorBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes.prefix(65_536) { data.append(byte) }
        return data
    }

    static func isContextTooLong(status: Int, body: Data, anthropic: Bool = false) -> Bool {
        if status == 413 { return true }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return false }
        if let code = error["code"] as? String,
           code == "context_length_exceeded" || code == "prompt_too_long" { return true }
        return anthropic && error["type"] as? String == "invalid_request_error"
            && (error["message"] as? String)?.hasPrefix("prompt is too long") == true
    }

    static func chatError(response: HTTPURLResponse, body: Data, anthropic: Bool = false) -> Error? {
        guard !(200..<300).contains(response.statusCode) else { return nil }
        if isContextTooLong(status: response.statusCode, body: body, anthropic: anthropic) {
            return ProviderRequestError.contextTooLong
        }
        return error(forStatus: response.statusCode,
                     retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
                     body: String(data: body, encoding: .utf8) ?? "")
    }

    struct WireMessage: Encodable {
        let role: String
        let content: String
    }

    private struct OpenAIChatBody: Encodable {
        let model: String
        let messages: [WireMessage]
        let stream: Bool
        let max_tokens: Int
    }

    static func openAIStyleChatRequest(
        base: String,
        type: ProviderType,
        apiKey: String?,
        model: String,
        messages: [ChatTurn],
        options: ChatRequestOptions
    ) throws -> URLRequest {
        try options.validate()
        var req = URLRequest(url: try ProviderAPIRoot.build(type: type, baseURL: base, endpoint: .chat))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let wire = canonicalMessages(messages).map { WireMessage(role: wireRole($0.role), content: $0.content) }
        req.httpBody = try JSONEncoder().encode(OpenAIChatBody(
            model: model, messages: wire, stream: true, max_tokens: options.maxOutputTokens))
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
                       !(200..<300).contains(http.statusCode) {
                        let body = try await readErrorBody(bytes)
                        continuation.finish(throwing: chatError(response: http, body: body))
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

    /// GET the provider's models endpoint → {"data":[{"id", "name"?}]}.
    /// Throws on ANY failure —
    /// 401 → .auth, other statuses → .http, network errors → URLError.
    /// Sorted case-insensitively by label.
    static func listOpenAIStyleModels(
        base: String,
        type: ProviderType,
        apiKey: String?,
        session: URLSession
    ) async throws -> [ProviderModelInfo] {
        var req = URLRequest(url: try ProviderAPIRoot.build(type: type, baseURL: base, endpoint: .models))
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

import Foundation

/// Final prompt/output counts of one non-streaming chat or raw generate request.
public struct ChatTokenObservation: Codable, Equatable, Sendable {
    public let text: String
    public let promptTokens: Int?
    public let outputTokens: Int?

    public init(text: String, promptTokens: Int?, outputTokens: Int?) {
        self.text = text
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
    }
}

public struct ObservedPromptCount: Equatable, Sendable {
    public let tokens: Int
    public let method: String
    /// Tokenizer provenance when `method == documented-tokenizer`.
    public let tokenizer: OfflineTokenCount?

    public init(tokens: Int, method: String, tokenizer: OfflineTokenCount?) {
        self.tokens = tokens
        self.method = method
        self.tokenizer = tokenizer
    }
}

/// Captured preparation of a named profile on an Ollama endpoint.
public struct PreparedProfileIdentity: Equatable, Sendable {
    public let identity: GenerationIdentity
    public let effectiveLimit: Int

    public init(identity: GenerationIdentity, effectiveLimit: Int) {
        self.identity = identity
        self.effectiveLimit = effectiveLimit
    }
}

/// Provider snapshot consumed by profile preparation; captured once by the router.
public struct EmbeddingProviderSnapshot: Equatable, Sendable {
    public let providerId: String
    public let type: ProviderType
    public let root: String
    public let enabled: Bool
    public let consented: Bool
    public let embeddingCapable: Bool

    public init(providerId: String, type: ProviderType, root: String, enabled: Bool, consented: Bool,
                embeddingCapable: Bool) {
        self.providerId = providerId
        self.type = type
        self.root = root
        self.enabled = enabled
        self.consented = consented
        self.embeddingCapable = embeddingCapable
    }
}

/// Strict Ollama wire for WP7 (benchmark-v1 §3): complete-input `/api/embed`,
/// count-only `/api/generate` (raw) and `/api/chat`, plus `/api/tags` digests and
/// `/api/show` context metadata. The legacy `OllamaClient` path is untouched.
public final class OllamaBenchmarkClient: StrictEmbeddingTransport, Sendable {
    public static let lengthRejectionError = "the input length exceeds the context length"
    public static let rawMethod = "ollama-raw-prompt"
    public static let chatMethod = "ollama-chat-prompt"
    public static let embedMethod = "ollama-embed-prompt"
    public static let documentedTokenizerMethod = "documented-tokenizer"

    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Embedding

    public func embed(model: String, input: String, nativeDims: Int, inputLimit: Int) async throws -> StrictEmbeddingResult {
        let body: [String: Any] = ["model": model, "input": [input], "dimensions": nativeDims, "truncate": false,
                                   "options": ["num_ctx": inputLimit]]
        let (data, status) = try await post("/api/embed", body: body)
        guard status == 200 else {
            if status == 400, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["error"] as? String == Self.lengthRejectionError {
                throw EmbeddingInputTooLong()
            }
            throw Self.providerError(status: status, data: data)
        }
        let object = try Self.object(data)
        guard let rows = object["embeddings"] as? [Any], rows.count == 1, let row = rows[0] as? [Any],
              row.count == nativeDims else { throw EmbeddingProfileError(code: "invalidEmbedding") }
        var vector: [Float] = []
        vector.reserveCapacity(row.count)
        for value in row {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                  Float(n.doubleValue).isFinite else { throw EmbeddingProfileError(code: "invalidEmbedding") }
            vector.append(Float(n.doubleValue))
        }
        return StrictEmbeddingResult(vector: vector, promptTokens: try Self.optionalCount(object["prompt_eval_count"]),
                                     totalDurationNs: try Self.optionalDuration(object["total_duration"]),
                                     loadDurationNs: try Self.optionalDuration(object["load_duration"]))
    }

    // MARK: - Chat token observation

    public func observeRaw(model: String, text: String, options: ChatRequestOptions) async throws -> ChatTokenObservation {
        try options.validate()
        let body: [String: Any] = ["model": model, "prompt": text, "raw": true, "stream": false,
                                   "options": Self.chatOptions(options)]
        let object = try await postSuccess("/api/generate", body: body)
        guard let response = object["response"] as? String else { throw EmbeddingProfileError(code: "invalidResponse") }
        return ChatTokenObservation(text: response, promptTokens: try Self.optionalCount(object["prompt_eval_count"]),
                                    outputTokens: try Self.optionalCount(object["eval_count"]))
    }

    public func observeChat(model: String, messages: [ChatTurn], options: ChatRequestOptions) async throws -> ChatTokenObservation {
        try options.validate()
        let wire = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        let body: [String: Any] = ["model": model, "messages": wire, "stream": false,
                                   "options": Self.chatOptions(options)]
        let object = try await postSuccess("/api/chat", body: body)
        guard let message = object["message"] as? [String: Any], let content = message["content"] as? String else {
            throw EmbeddingProfileError(code: "invalidResponse")
        }
        return ChatTokenObservation(text: content, promptTokens: try Self.optionalCount(object["prompt_eval_count"]),
                                    outputTokens: try Self.optionalCount(object["eval_count"]))
    }

    /// Prompt count of one observation: the provider count as-is (method
    /// `providerMethod`), else the documented offline tokenizer (`documented-tokenizer`,
    /// never labeled Ollama-exact), else nil (unmeasured).
    public static func resolvePromptCount(
        _ observation: ChatTokenObservation, providerMethod: String,
        fallback: (@Sendable () async throws -> OfflineTokenCount)? = nil
    ) async throws -> ObservedPromptCount? {
        if let tokens = observation.promptTokens {
            return ObservedPromptCount(tokens: tokens, method: providerMethod, tokenizer: nil)
        }
        guard let fallback else { return nil }
        let count = try await fallback()
        return ObservedPromptCount(tokens: count.tokens, method: documentedTokenizerMethod, tokenizer: count)
    }

    private static func chatOptions(_ options: ChatRequestOptions) -> [String: Any] {
        ["num_ctx": options.runtimeContext, "num_predict": options.maxOutputTokens, "temperature": 0]
    }

    // MARK: - Model discovery

    public struct TagRow: Equatable, Sendable {
        public let name: String
        public let digest: String
    }

    /// `GET /api/tags` rows (`name`, raw `digest`).
    public func tags() async throws -> [TagRow] {
        var request = URLRequest(url: try ProviderWire.url(base: baseURL.absoluteString, path: "/api/tags"))
        request.httpMethod = "GET"
        let (data, status) = try await send(request)
        guard status == 200 else { throw Self.providerError(status: status, data: data) }
        let object = try Self.object(data)
        guard let models = object["models"] as? [[String: Any]] else { throw EmbeddingProfileError(code: "invalidResponse") }
        return models.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return TagRow(name: name, digest: row["digest"] as? String ?? "")
        }
    }

    /// `POST /api/show` raw metadata.
    public func show(model: String) async throws -> Data {
        let (data, status) = try await post("/api/show", body: ["model": model])
        guard status == 200 else { throw Self.providerError(status: status, data: data) }
        return data
    }

    /// Lowercase SHA-256 of the model's `/api/show` `template` (report provenance), or nil.
    public func templateSha256(model: String) async throws -> String? {
        let object = try Self.object(try await show(model: model))
        return (object["template"] as? String).map(sha256LowerHex)
    }

    /// `GET /api/version` → `version`, or nil when unavailable.
    public func version() async throws -> String? {
        var request = URLRequest(url: try ProviderWire.url(base: baseURL.absoluteString, path: "/api/version"))
        request.httpMethod = "GET"
        let (data, status) = try await send(request)
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["version"] as? String
    }

    /// Context limit from `/api/show` (WP2 parser); nil when absent or invalid.
    public func contextLength(model: String) async throws -> Int? {
        (try? ProviderLimitPolicy.contextWindow(fromOllamaShow: try await show(model: model))) ?? nil
    }

    /// Exact digest for `model`: one row whose name equals the model, or — only for an
    /// untagged model — `model + ":latest"`. No prefix/substring matching.
    public static func exactDigest(model: String, rows: [TagRow]) -> String? {
        let names = model.contains(":") ? [model] : [model, model + ":latest"]
        let matches = rows.filter { row in names.contains { Data($0.utf8) == Data(row.name.utf8) } }
        guard matches.count == 1 else { return nil }
        return normalizeDigest(matches[0].digest)
    }

    /// `<64 lowercase hex>` or `sha256:<64 lowercase hex>` → `sha256:<hex>`; else nil.
    public static func normalizeDigest(_ raw: String) -> String? {
        let hex = raw.hasPrefix("sha256:") ? String(raw.dropFirst(7)) : raw
        return isLowerHex64(hex) ? "sha256:" + hex : nil
    }

    static func isLowerHex64(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// Captured preparation: `/api/tags` exact digest, `/api/show` context limit,
    /// `effectiveLimit = min(maxInputTokens, context)`, full generation identity.
    public static func prepareProfile(_ profile: EmbeddingProfile, provider: EmbeddingProviderSnapshot,
                                      client: OllamaBenchmarkClient) async throws -> PreparedProfileIdentity {
        guard provider.type == .ollama, provider.enabled, provider.consented, provider.embeddingCapable else {
            throw EmbeddingProfileError(code: "unsupportedEmbeddingProfile")
        }
        let root = try ProviderAPIRoot.normalize(provider.root)
        guard let digest = exactDigest(model: profile.model, rows: try await client.tags()) else {
            throw EmbeddingProfileError(code: "embeddingModelUnavailable")
        }
        try Task.checkCancellation()
        let metadata = try await client.show(model: profile.model)
        try Task.checkCancellation()
        guard let context = (try? ProviderLimitPolicy.contextWindow(fromOllamaShow: metadata)) ?? nil else {
            throw EmbeddingProfileError(code: "modelMetadataUnavailable")
        }
        let limit = min(profile.maxInputTokens, context)
        let identity = GenerationIdentity(
            providerId: provider.providerId,
            endpointRevision: EmbeddingEndpointRevision.make(type: provider.type, normalizedRoot: root),
            model: profile.model, modelDigest: digest, dims: profile.dims, normalization: "l2",
            queryFormatVersion: profile.formatVersion(.query, effectiveLimit: limit),
            docFormatVersion: profile.formatVersion(.document, effectiveLimit: limit), chunkerVersion: "2")
        return PreparedProfileIdentity(identity: identity, effectiveLimit: limit)
    }

    /// Resume/publication check of a stored named-profile identity: only `/api/tags`
    /// is re-read; the ctx suffix comes from the stored identity and is never re-probed.
    public static func revalidate(_ identity: GenerationIdentity, profile: EmbeddingProfile,
                                  client: OllamaBenchmarkClient) async throws -> Int {
        let limit = try profile.validateIdentity(model: identity.model, dims: identity.dims,
                                                 queryFormatVersion: identity.queryFormatVersion,
                                                 docFormatVersion: identity.docFormatVersion)
        guard identity.normalization == "l2", identity.chunkerVersion == "2" else {
            throw EmbeddingProfileError(code: "profileIdentityMismatch")
        }
        guard let stored = identity.modelDigest else { throw EmbeddingProfileError(code: "embeddingModelChanged") }
        let current = exactDigest(model: profile.model, rows: try await client.tags())
        try Task.checkCancellation()
        guard let current, Data(current.utf8) == Data(stored.utf8) else {
            throw EmbeddingProfileError(code: "embeddingModelChanged")
        }
        return limit
    }

    /// Profile ID named by a `wp7:<id>:<purpose>:...` format string, else nil.
    public static func profileId(fromFormatVersion value: String) -> String? {
        guard value.hasPrefix("wp7:") else { return nil }
        let rest = value.dropFirst(4)
        guard let colon = rest.firstIndex(of: ":"), colon != rest.startIndex else { return nil }
        return String(rest[..<colon])
    }

    // MARK: - Wire helpers

    private func post(_ path: String, body: [String: Any]) async throws -> (Data, Int) {
        var request = URLRequest(url: try ProviderWire.url(base: baseURL.absoluteString, path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return try await send(request)
    }

    private func postSuccess(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let (data, status) = try await post(path, body: body)
        guard status == 200 else { throw Self.providerError(status: status, data: data) }
        return try Self.object(data)
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        try Task.checkCancellation()
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
            throw OllamaError.notReachable
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw EmbeddingProfileError(code: "invalidResponse") }
        return (data, http.statusCode)
    }

    private static func providerError(status: Int, data: Data) -> ProviderError {
        // Sanitized, bounded body; never request text or credentials.
        let body = String(decoding: data.prefix(512), as: UTF8.self)
        return .http(code: status, body: body)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EmbeddingProfileError(code: "invalidResponse")
        }
        return object
    }

    /// Missing/null → nil; a negative, fractional or non-numeric count → `invalidTokenCount`.
    static func optionalCount(_ value: Any?) throws -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        guard let count = nonnegativeInteger(value) else { throw EmbeddingProfileError(code: "invalidTokenCount") }
        return count
    }

    private static func optionalDuration(_ value: Any?) throws -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        guard let n = nonnegativeInteger(value) else { throw EmbeddingProfileError(code: "invalidResponse") }
        return Int64(n)
    }

    static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: n.objCType)) || n.doubleValue.rounded() == n.doubleValue && n.doubleValue.isFinite
        else { return nil }
        let d = n.doubleValue
        guard d >= 0, d <= Double(Int64.max / 2), d == d.rounded() else { return nil }
        return Int(n.int64Value)
    }
}

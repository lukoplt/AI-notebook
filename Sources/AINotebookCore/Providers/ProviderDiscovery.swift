import Foundation

public enum ProviderProbeStatus: String, Sendable {
    case verified, listingUnsupported, failed
}

/// A connection check verifies model listing only; it never sends generation input.
public struct ProviderProbeResult: Sendable {
    public let status: ProviderProbeStatus
    public let models: [ProviderModelInfo]
    public let errorCode: String?
    public let detail: String?
    public var generationVerified: Bool { false }

    public init(status: ProviderProbeStatus, models: [ProviderModelInfo],
                errorCode: String? = nil, detail: String? = nil) {
        self.status = status
        self.models = models
        self.errorCode = errorCode
        self.detail = detail
    }
}

public struct ProviderListingUnsupported: Error, Sendable {
    public init() {}
}

/// Discovery has no static model fallback and shares exact-root validation with
/// generation. Errors stay typed until a UI probe turns them into safe details.
enum ProviderDiscovery {
    private struct OllamaModels: Decodable {
        struct Item: Decodable { let name: String }
        let models: [Item]
    }

    private struct CloudModels: Decodable {
        struct Item: Decodable {
            let id: String
            let name: String?
            let displayName: String?

            enum CodingKeys: String, CodingKey {
                case id, name
                case displayName = "display_name"
            }
        }
        let data: [Item]
    }

    static func models(type: ProviderType, baseURL: String, apiKey: String?,
                       session: URLSession) async throws -> [ProviderModelInfo] {
        let data = try await listing(type: type, baseURL: baseURL, apiKey: apiKey, session: session)
        let models: [ProviderModelInfo]
        do {
            if type == .ollama {
                models = try JSONDecoder().decode(OllamaModels.self, from: data).models
                    .map { ProviderModelInfo(id: $0.name) }
            } else {
                let items = try JSONDecoder().decode(CloudModels.self, from: data).data
                // provider-listing-limits-v1: OpenWebUI / OpenAI-compatible items may advertise a window
                // (the decoded items are the raw array's elements, in order).
                var windows = [Int?](repeating: nil, count: items.count)
                if ProviderLimitPolicy.listingTypes.contains(type),
                   let raw = (try? JSONSerialization.jsonObject(with: data)).flatMap({ ($0 as? [String: Any])?["data"] as? [Any] }),
                   raw.count == items.count {
                    windows = raw.map { ($0 as? [String: Any]).flatMap(ProviderLimitPolicy.contextWindow(fromListingItem:)) }
                }
                models = zip(items, windows).map { item, window in
                    ProviderModelInfo(id: item.id, displayName: type == .anthropic ? item.displayName : item.name,
                                      contextWindow: window)
                }
            }
        } catch is DecodingError {
            throw ProviderError.decoding("Unexpected model listing response shape.")
        }
        guard models.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ProviderError.decoding("Model listing contains an empty model ID.")
        }
        return type == .anthropic ? models : models.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    /// The raw model listing body after status mapping (discovery and limit refresh share it).
    static func listing(type: ProviderType, baseURL: String, apiKey: String?,
                        session: URLSession) async throws -> Data {
        try Task.checkCancellation()
        let url = try ProviderAPIRoot.build(type: type, baseURL: baseURL, endpoint: .models)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if type == .anthropic {
            request.setValue(apiKey ?? "", forHTTPHeaderField: "x-api-key")
            request.setValue(AnthropicChatAdapter.apiVersion, forHTTPHeaderField: "anthropic-version")
        } else if type != .ollama, let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200..<300:
            break
        case 404, 405, 501:
            throw ProviderListingUnsupported()
        case 401, 403:
            throw ProviderError.auth("Authentication failed (HTTP \(http.statusCode)).")
        case 429:
            throw ProviderError.rateLimit(
                retryAfterSeconds: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        default:
            // Server bodies may echo credentials or user input; discovery does
            // not need them to preserve the HTTP status for callers.
            throw ProviderError.http(code: http.statusCode, body: "")
        }
        return data
    }

    static func probe(type: ProviderType, baseURL: String, apiKey: String?,
                      session: URLSession) async throws -> ProviderProbeResult {
        do {
            let models = try await models(type: type, baseURL: baseURL, apiKey: apiKey, session: session)
            return .init(status: .verified, models: models)
        } catch {
            // URLSession reports cancellation as URLError; neither it nor task
            // cancellation should become a failed connection-check result.
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw error
            }
            try Task.checkCancellation()
            if error is ProviderListingUnsupported {
                return .init(status: .listingUnsupported, models: [],
                             detail: "Model listing is not supported by this endpoint.")
            }
            if error as? ProviderConfigurationError == .invalidBaseURL {
                return failed("invalidBaseURL", "The API root is invalid.")
            }
            if let providerError = error as? ProviderError {
                switch providerError {
                case .auth:
                    return failed("auth", "Authentication failed.")
                case .rateLimit:
                    return failed("http", "The provider rate limit was reached.")
                case .http(let code, _):
                    return failed("http", "HTTP \(code).")
                case .decoding:
                    return failed("decoding", "Unexpected model listing response shape.")
                case .refusal, .consentRequired:
                    break
                }
            }
            return failed("transport", "The provider could not be reached.")
        }
    }

    private static func failed(_ code: String, _ detail: String) -> ProviderProbeResult {
        .init(status: .failed, models: [], errorCode: code, detail: detail)
    }
}

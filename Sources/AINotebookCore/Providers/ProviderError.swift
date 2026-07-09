import Foundation

/// Wire-level provider failures, mapped per FR-A10.
/// `auth` and `refusal` are terminal — `ChatEngine` must not retry them.
public enum ProviderError: Error, Equatable, Sendable {
    case auth(String)
    case rateLimit(retryAfterSeconds: Double?)
    case http(code: Int, body: String)
    case refusal
    case decoding(String)
}

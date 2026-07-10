import Foundation

/// Wire-level provider failures, mapped per FR-A10.
/// `auth` and `refusal` are terminal — `ChatEngine` must not retry them.
public enum ProviderError: Error, Equatable, Sendable {
    case auth(String)
    case rateLimit(retryAfterSeconds: Double?)
    case http(code: Int, body: String)
    case refusal
    case decoding(String)
    /// Thrown by `ProviderRouter` (FR-A8) when a cloud/network provider is
    /// selected for chat or embeddings but the user has never acknowledged
    /// the privacy gate for it. Terminal — `ChatEngine` must not retry it,
    /// since retrying cannot grant consent.
    case consentRequired
}

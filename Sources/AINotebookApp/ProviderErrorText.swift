import Foundation
import AINotebookCore

/// Maps wire-level provider failures to localized user-facing text.
/// Used by the chat error row and the Add-provider sheet's Test button.
func providerErrorText(_ error: Error, text: AppText) -> String {
    if let configuration = error as? ProviderConfigurationError {
        switch configuration {
        case .invalidBaseURL: return text.string(.providerInvalidRoot)
        case .invalidLimits: return text.string(.providerLimitsInvalid)
        case .missingProvider, .disabledProvider: return text.string(.providerSelectionUnavailable)
        case .unsupportedEndpoint: return text.string(.providerEndpointUnsupported)
        }
    }
    if let request = error as? ProviderRequestError {
        switch request {
        case .contextTooLong: return text.string(.providerContextTooLong)
        }
    }
    if error is ProviderListingUnsupported {
        return text.string(.providerListingUnsupported)
    }
    if let pe = error as? ProviderError {
        switch pe {
        case .auth: return text.string(.errorInvalidApiKey)
        case .rateLimit: return text.string(.errorRateLimited)
        case .refusal: return text.string(.errorModelRefusal)
        case .consentRequired: return text.string(.errorConsentRequired)
        case .http(let code, _): return "HTTP \(code)"
        case .decoding: return text.string(.providerResponseInvalid)
        }
    }
    if error is URLError { return text.string(.providerConnectionFailed) }
    // Arbitrary localizedDescription values can contain response bodies, SQL,
    // paths or user input. Present only known, localized failure categories.
    return text.string(.providerRequestFailed)
}

/// The probe's status describes listing only, never generation or embeddings.
/// Do not display arbitrary detail strings even if a caller supplies one.
func providerProbeText(_ result: ProviderProbeResult, text: AppText) -> String {
    switch result.status {
    case .verified:
        return text.string(.providerListingVerified)
    case .listingUnsupported:
        return text.string(.providerListingUnsupported)
    case .failed:
        switch result.errorCode {
        case "invalidBaseURL": return text.string(.providerInvalidRoot)
        case "auth": return text.string(.errorInvalidApiKey)
        case "transport": return text.string(.providerConnectionFailed)
        case "decoding": return text.string(.providerResponseInvalid)
        case "http":
            if result.detail == "The provider rate limit was reached." {
                return text.string(.errorRateLimited)
            }
            // Core emits HTTP status text without bodies. Parse and rebuild
            // only that narrow format so no remote text reaches the view.
            if let detail = result.detail, detail.hasPrefix("HTTP "), detail.hasSuffix("."),
               let status = Int(detail.dropFirst(5).dropLast()), (100...599).contains(status) {
                return "HTTP \(status)"
            }
            return text.string(.providerRequestFailed)
        default:
            return text.string(.providerRequestFailed)
        }
    }
}

import AINotebookCore

/// Maps wire-level provider failures to localized user-facing text.
/// Used by the chat error row and the Add-provider sheet's Test button.
func providerErrorText(_ error: Error, text: AppText) -> String {
    if let pe = error as? ProviderError {
        switch pe {
        case .auth: return text.string(.errorInvalidApiKey)
        case .rateLimit: return text.string(.errorRateLimited)
        case .refusal: return text.string(.errorModelRefusal)
        case .http(let code, _): return "HTTP \(code)"
        case .decoding(let message): return message
        }
    }
    return error.localizedDescription
}

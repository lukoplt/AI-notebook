import Foundation

/// UserDefaults keys for the active provider/model selection. Shared between
/// `AppSettings` (writes, @MainActor) and `DefaultsProviderSelection`
/// (reads from any context — UserDefaults is thread-safe).
public enum ProviderSettingsKeys {
    public static let chatProviderId = "selectedChatProviderId"
    public static let embeddingProviderId = "selectedEmbeddingProviderId"
    public static let chatModel = "selectedChatModel"
    public static let embeddingModel = "selectedEmbeddingModel"
}

/// Live (provider, model) selection, readable from any isolation context.
/// The router consults this on EVERY call, which is what makes provider and
/// model switches take effect without rebuilding engines.
public protocol ProviderSelectionReading: Sendable {
    func chatSelection() -> (providerId: String, model: String)
    func embeddingSelection() -> (providerId: String, model: String)
}

public extension ProviderSelectionReading {
    /// Fully qualified `chunk_embeddings.model` key (FR-A11).
    func embeddingKey() -> String {
        let s = embeddingSelection()
        return "\(s.providerId):\(s.model)"
    }
}

public final class DefaultsProviderSelection: ProviderSelectionReading, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func chatSelection() -> (providerId: String, model: String) {
        (defaults.string(forKey: ProviderSettingsKeys.chatProviderId) ?? ProviderConfig.ollamaId,
         defaults.string(forKey: ProviderSettingsKeys.chatModel) ?? "llama3.2:3b")
    }

    public func embeddingSelection() -> (providerId: String, model: String) {
        (defaults.string(forKey: ProviderSettingsKeys.embeddingProviderId) ?? ProviderConfig.ollamaId,
         defaults.string(forKey: ProviderSettingsKeys.embeddingModel) ?? "nomic-embed-text")
    }
}

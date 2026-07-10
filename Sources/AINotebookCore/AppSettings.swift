import Foundation

/// Observable settings store backed by `UserDefaults`. Owns the user's
/// language preference. Created once at app launch and injected as an
/// `@EnvironmentObject` into SwiftUI views.
///
/// The `defaults` and `preferredLanguages` parameters exist so tests can
/// inject an isolated suite + a controlled locale list. Production code
/// calls `AppSettings()` with defaults.
@MainActor
public final class AppSettings: ObservableObject {
    private enum Keys {
        static let language = "language"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let selectedChatModel = ProviderSettingsKeys.chatModel
        static let selectedEmbeddingModel = ProviderSettingsKeys.embeddingModel
        static let selectedChatProviderId = ProviderSettingsKeys.chatProviderId
        static let selectedEmbeddingProviderId = ProviderSettingsKeys.embeddingProviderId
        static let autoCheckUpdates = "autoCheckUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
    }

    private let defaults: UserDefaults

    @Published public var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
        }
    }

    @Published public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    @Published public var selectedChatModel: String {
        didSet { defaults.set(selectedChatModel, forKey: Keys.selectedChatModel) }
    }

    @Published public var selectedEmbeddingModel: String {
        didSet { defaults.set(selectedEmbeddingModel, forKey: Keys.selectedEmbeddingModel) }
    }

    @Published public var selectedChatProviderId: String {
        didSet { defaults.set(selectedChatProviderId, forKey: Keys.selectedChatProviderId) }
    }

    @Published public var selectedEmbeddingProviderId: String {
        didSet { defaults.set(selectedEmbeddingProviderId, forKey: Keys.selectedEmbeddingProviderId) }
    }

    @Published public var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates) }
    }

    /// Stored as a unix timestamp; nil until the first successful check.
    @Published public var lastUpdateCheck: Date? {
        didSet {
            if let lastUpdateCheck {
                defaults.set(lastUpdateCheck.timeIntervalSince1970, forKey: Keys.lastUpdateCheck)
            } else {
                defaults.removeObject(forKey: Keys.lastUpdateCheck)
            }
        }
    }

    public init(
        defaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.defaults = defaults

        if let raw = defaults.string(forKey: Keys.language),
           let stored = AppLanguage(rawValue: raw) {
            self.language = stored
        } else {
            self.language = detectInitialLanguage(preferredLanguages: preferredLanguages)
        }

        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        self.selectedChatModel =
            defaults.string(forKey: Keys.selectedChatModel) ?? "llama3.2:3b"
        self.selectedEmbeddingModel =
            defaults.string(forKey: Keys.selectedEmbeddingModel) ?? "nomic-embed-text"
        self.selectedChatProviderId =
            defaults.string(forKey: Keys.selectedChatProviderId) ?? ProviderConfig.ollamaId
        self.selectedEmbeddingProviderId =
            defaults.string(forKey: Keys.selectedEmbeddingProviderId) ?? ProviderConfig.ollamaId

        if defaults.object(forKey: Keys.autoCheckUpdates) == nil {
            self.autoCheckUpdates = true
        } else {
            self.autoCheckUpdates = defaults.bool(forKey: Keys.autoCheckUpdates)
        }
        if let stamp = defaults.object(forKey: Keys.lastUpdateCheck) as? Double {
            self.lastUpdateCheck = Date(timeIntervalSince1970: stamp)
        } else {
            self.lastUpdateCheck = nil
        }
    }

    public var text: AppText {
        AppText(language: language)
    }
}

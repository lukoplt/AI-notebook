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
        static let selectedChatModel = "selectedChatModel"
        static let selectedEmbeddingModel = "selectedEmbeddingModel"
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
    }

    public var text: AppText {
        AppText(language: language)
    }
}

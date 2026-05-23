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
    }

    private let defaults: UserDefaults

    @Published public var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
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
    }

    public var text: AppText {
        AppText(language: language)
    }
}

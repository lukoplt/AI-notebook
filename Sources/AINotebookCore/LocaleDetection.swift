/// Maps the user's preferred-language list (from `Locale.preferredLanguages`)
/// to an `AppLanguage`. Czech if any preferred entry starts with "cs",
/// otherwise English.
///
/// Pulled out into a free function so it can be tested without touching the
/// real `Locale` singleton.
public func detectInitialLanguage(preferredLanguages: [String]) -> AppLanguage {
    for entry in preferredLanguages {
        if entry.lowercased().hasPrefix("cs") {
            return .czech
        }
    }
    return .english
}

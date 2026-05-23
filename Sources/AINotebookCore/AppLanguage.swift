public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case czech = "cs"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .english:
            "English"
        case .czech:
            "Čeština"
        }
    }
}

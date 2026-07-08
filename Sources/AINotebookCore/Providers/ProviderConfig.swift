import Foundation

public struct ProviderConfig: Equatable, Sendable, Identifiable {
    /// Well-known id of the built-in Ollama provider — never deleted.
    /// Same GUID as the Windows port.
    public static let ollamaId = "00000000-0000-0000-0000-000000000000"

    public let id: String
    public var type: ProviderType
    public var name: String
    public var baseURL: String
    public var enabled: Bool
    public var privacyAcknowledged: Bool
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        type: ProviderType,
        name: String,
        baseURL: String,
        enabled: Bool = true,
        privacyAcknowledged: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.baseURL = baseURL
        self.enabled = enabled
        self.privacyAcknowledged = privacyAcknowledged
        self.createdAt = createdAt
    }

    public var isBuiltInOllama: Bool { id == Self.ollamaId }

    /// In-memory fallback used when the DB row is unexpectedly missing.
    public static func builtInOllama() -> ProviderConfig {
        ProviderConfig(
            id: ollamaId,
            type: .ollama,
            name: "Ollama (local)",
            baseURL: ProviderType.ollama.defaultBaseURL,
            enabled: true,
            privacyAcknowledged: true
        )
    }
}

public struct ProviderModelInfo: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String?

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }

    public var label: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return id
    }
}

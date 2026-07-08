import Foundation

/// Provider registry types. Storage strings match the Windows port exactly
/// (`windows/src/AINotebook.Core/Providers/ProviderType.cs`).
public enum ProviderType: String, CaseIterable, Sendable {
    case ollama
    case anthropic
    case openai
    case openaiCompatible = "openai_compatible"
    case openwebui

    /// Unknown storage strings fall back to `.openaiCompatible` (Windows parity).
    public static func fromStorage(_ raw: String) -> ProviderType {
        ProviderType(rawValue: raw) ?? .openaiCompatible
    }

    public var defaultBaseURL: String {
        switch self {
        case .ollama: "http://127.0.0.1:11434"
        case .anthropic: "https://api.anthropic.com"
        case .openai: "https://api.openai.com"
        case .openaiCompatible, .openwebui: ""
        }
    }

    /// Anthropic has no embeddings API; OpenWebUI is chat-only by design.
    public var supportsEmbeddings: Bool {
        switch self {
        case .anthropic, .openwebui: false
        case .ollama, .openai, .openaiCompatible: true
        }
    }

    /// True when requests leave this machine — the privacy gate applies.
    public var isCloud: Bool { self != .ollama }
}

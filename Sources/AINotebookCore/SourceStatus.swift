import Foundation

public enum SourceStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case chunking
    case ready
    case error

    public var isTerminal: Bool {
        switch self {
        case .pending, .chunking: return false
        case .ready, .error:      return true
        }
    }
}

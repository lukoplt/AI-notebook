import Foundation

public struct OllamaPullEvent: Codable, Equatable, Sendable {
    public let status: String
    public let digest: String?
    public let total: Int64?
    public let completed: Int64?

    public init(status: String, digest: String? = nil, total: Int64? = nil, completed: Int64? = nil) {
        self.status = status
        self.digest = digest
        self.total = total
        self.completed = completed
    }

    public var fractionComplete: Double? {
        guard let total, let completed, total > 0 else { return nil }
        return Double(completed) / Double(total)
    }

    public var isTerminalSuccess: Bool {
        status == "success"
    }
}

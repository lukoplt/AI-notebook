import Foundation

/// A named, reusable subset of a notebook's sources used to scope chat
/// retrieval (Epic C, FR-C2). Mirrors the Windows `SourceSet` record.
public struct SourceSet: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64
    public var notebookId: Int64
    public var name: String
    public var createdAt: Date

    public init(id: Int64, notebookId: Int64, name: String, createdAt: Date) {
        self.id = id
        self.notebookId = notebookId
        self.name = name
        self.createdAt = createdAt
    }
}

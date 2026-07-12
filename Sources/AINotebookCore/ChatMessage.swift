import Foundation
import GRDB

public enum ChatRole: String, Codable, Sendable, CaseIterable {
    case system
    case user
    case assistant
}

public struct Citation: Equatable, Hashable, Codable, Sendable {
    public let marker: Int
    public let chunkId: Int64
    public let sourceId: Int64
    public let snippet: String

    public init(marker: Int, chunkId: Int64, sourceId: Int64, snippet: String) {
        self.marker = marker
        self.chunkId = chunkId
        self.sourceId = sourceId
        self.snippet = snippet
    }
}

public struct ChatMessage: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var sessionId: Int64
    public var role: ChatRole
    public var content: String
    public var citations: [Citation]
    /// The provider-qualified model that generated this (assistant) message,
    /// shown as a badge after a regenerate with a different model (FR-C3).
    /// Nil for user messages and pre-v13 rows.
    public var model: String?
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        sessionId: Int64,
        role: ChatRole,
        content: String,
        citations: [Citation] = [],
        model: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.citations = citations
        self.model = model
        self.createdAt = createdAt
    }
}

extension ChatMessage: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "messages"

    public enum Columns: String {
        case id
        case sessionId     = "session_id"
        case role
        case content
        case citationsJson = "citations_json"
        case model
        case createdAt     = "created_at"

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(row: Row) throws {
        let cits: [Citation]
        if let raw: String = row[Columns.citationsJson.rawValue],
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([Citation].self, from: data) {
            cits = decoded
        } else {
            cits = []
        }
        let roleRaw: String = row[Columns.role.rawValue]
        self.init(
            id: row[Columns.id.rawValue],
            sessionId: row[Columns.sessionId.rawValue],
            role: ChatRole(rawValue: roleRaw) ?? .user,
            content: row[Columns.content.rawValue],
            citations: cits,
            model: row[Columns.model.rawValue],
            createdAt: row[Columns.createdAt.rawValue]
        )
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.sessionId.rawValue] = sessionId
        container[Columns.role.rawValue]      = role.rawValue
        container[Columns.content.rawValue]   = content
        container[Columns.citationsJson.rawValue] =
            citations.isEmpty
                ? nil
                : String(data: try JSONEncoder().encode(citations), encoding: .utf8)
        container[Columns.model.rawValue] = model
        container[Columns.createdAt.rawValue] = createdAt
    }
}

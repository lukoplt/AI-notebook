import Foundation
import GRDB

public struct ChatSession: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var notebookId: Int64
    public var title: String
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        notebookId: Int64,
        title: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.notebookId = notebookId
        self.title = title
        self.createdAt = createdAt
    }
}

extension ChatSession: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "chat_sessions"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case notebookId = "notebook_id"
        case title
        case createdAt  = "created_at"

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

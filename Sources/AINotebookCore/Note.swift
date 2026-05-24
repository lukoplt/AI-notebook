import Foundation
import GRDB

public enum NoteOrigin: String, Codable, Sendable, CaseIterable {
    case manual
    case chat
    case transformation
}

public struct Note: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var notebookId: Int64
    public var title: String
    public var bodyMd: String
    public var origin: NoteOrigin
    public var originRef: Int64?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        notebookId: Int64,
        title: String,
        bodyMd: String,
        origin: NoteOrigin = .manual,
        originRef: Int64? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.notebookId = notebookId
        self.title = title
        self.bodyMd = bodyMd
        self.origin = origin
        self.originRef = originRef
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

extension Note: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "notes"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case notebookId = "notebook_id"
        case title
        case bodyMd    = "body_md"
        case origin
        case originRef = "origin_ref"
        case createdAt = "created_at"
        case updatedAt = "updated_at"

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

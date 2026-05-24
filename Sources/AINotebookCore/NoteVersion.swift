import Foundation
import GRDB

public enum NoteVersionReason: String, Codable, Sendable, CaseIterable {
    case autosave
    case manual
    case restore
}

public struct NoteVersion: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var noteId: Int64
    public var title: String
    public var bodyMd: String
    public var savedAt: Date
    public var reason: NoteVersionReason

    public init(
        id: Int64? = nil,
        noteId: Int64,
        title: String,
        bodyMd: String,
        savedAt: Date = Date(),
        reason: NoteVersionReason
    ) {
        self.id = id
        self.noteId = noteId
        self.title = title
        self.bodyMd = bodyMd
        self.savedAt = savedAt
        self.reason = reason
    }
}

extension NoteVersion: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "note_versions"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case noteId  = "note_id"
        case title
        case bodyMd  = "body_md"
        case savedAt = "saved_at"
        case reason

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

import Foundation
import GRDB

public struct NoteAttachment: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var noteId: Int64
    public var noteUuid: String
    public var filename: String
    public var mime: String
    public var byteSize: Int64
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        noteId: Int64,
        noteUuid: String,
        filename: String,
        mime: String,
        byteSize: Int64,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.noteId = noteId
        self.noteUuid = noteUuid
        self.filename = filename
        self.mime = mime
        self.byteSize = byteSize
        self.createdAt = createdAt
    }
}

extension NoteAttachment: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "attachments"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case noteId    = "note_id"
        case noteUuid  = "note_uuid"
        case filename
        case mime
        case byteSize  = "byte_size"
        case createdAt = "created_at"

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

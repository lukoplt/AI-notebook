import Foundation
import GRDB

public struct SourceChunk: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var sourceId: Int64
    public var ord: Int
    public var text: String
    public var tokenCount: Int
    public var pageHint: Int?

    public init(
        id: Int64? = nil,
        sourceId: Int64,
        ord: Int,
        text: String,
        tokenCount: Int,
        pageHint: Int? = nil
    ) {
        self.id = id
        self.sourceId = sourceId
        self.ord = ord
        self.text = text
        self.tokenCount = tokenCount
        self.pageHint = pageHint
    }
}

extension SourceChunk: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "source_chunks"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case sourceId   = "source_id"
        case ord
        case text
        case tokenCount = "token_count"
        case pageHint   = "page_hint"

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

import Foundation
import GRDB

public struct TransformationRun: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var transformationId: Int64
    public var sourceId: Int64?
    public var resultNoteId: Int64?
    public var ranAt: Date

    public init(
        id: Int64? = nil,
        transformationId: Int64,
        sourceId: Int64? = nil,
        resultNoteId: Int64? = nil,
        ranAt: Date = Date()
    ) {
        self.id = id
        self.transformationId = transformationId
        self.sourceId = sourceId
        self.resultNoteId = resultNoteId
        self.ranAt = ranAt
    }
}

extension TransformationRun: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "transformation_runs"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case transformationId = "transformation_id"
        case sourceId         = "source_id"
        case resultNoteId     = "result_note_id"
        case ranAt            = "ran_at"

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

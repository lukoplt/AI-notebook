import Foundation
import GRDB

public struct Notebook: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var name: String
    public var description: String
    /// Per-notebook chat instructions injected into the system prompt (FR-C1).
    public var instructions: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        name: String,
        description: String = "",
        instructions: String = "",
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.instructions = instructions
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

extension Notebook: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "notebooks"

    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case name
        case description
        case instructions
        case createdAt = "created_at"
        case updatedAt = "updated_at"

        var column: Column {
            Column(self.rawValue)
        }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

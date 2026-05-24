import Foundation
import GRDB

public enum TransformationScope: String, Codable, Sendable, CaseIterable {
    case source
    case notebook
}

public struct Transformation: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var name: String
    public var promptTemplate: String
    public var scope: TransformationScope
    public var isBuiltin: Bool

    public init(
        id: Int64? = nil,
        name: String,
        promptTemplate: String,
        scope: TransformationScope = .source,
        isBuiltin: Bool = false
    ) {
        self.id = id
        self.name = name
        self.promptTemplate = promptTemplate
        self.scope = scope
        self.isBuiltin = isBuiltin
    }
}

extension Transformation: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "transformations"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case name
        case promptTemplate = "prompt_template"
        case scope
        case isBuiltin      = "is_builtin"

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

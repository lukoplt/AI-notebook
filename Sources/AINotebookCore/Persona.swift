import Foundation

/// A named, reusable chat preset (Epic C5): instructions + an optional source
/// set + an optional model. Applied from the chat persona picker.
public struct Persona: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64
    public var notebookId: Int64
    public var name: String
    public var instructions: String
    public var sourceSetId: Int64?
    public var model: String?
    public var createdAt: Date

    public init(
        id: Int64,
        notebookId: Int64,
        name: String,
        instructions: String = "",
        sourceSetId: Int64? = nil,
        model: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.notebookId = notebookId
        self.name = name
        self.instructions = instructions
        self.sourceSetId = sourceSetId
        self.model = model
        self.createdAt = createdAt
    }
}

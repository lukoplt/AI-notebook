import Foundation
import GRDB

/// A user-defined label attachable to notes and sources (Epic B, FR-B8).
/// Mirrors the Windows `Tag` record. Tag names are unique (enforced by the
/// `tags.name UNIQUE` constraint from MigrationV12).
public struct Tag: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64
    public var name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

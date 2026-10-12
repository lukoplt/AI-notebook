import Foundation
import GRDB

/// One page of a persisted folder's member sources (contract `folder-members-v1`).
public struct FolderMemberPage: Equatable, Sendable {
    public let members: [Source]
    public let offset: Int
    /// Every member of the folder, not just this page.
    public let total: Int

    public init(members: [Source], offset: Int, total: Int) {
        self.members = members
        self.offset = offset
        self.total = total
    }

    public var nextOffset: Int { offset + members.count }
    public var hasMore: Bool { nextOffset < total }
}

extension NotebookStore {
    /// Largest page `folderMembers` accepts.
    public static let folderMembersMaxLimit = 500
    /// Page size the Sources list requests when a folder is expanded or extended.
    public static let folderMembersPageSize = 200

    /// Members of one folder ordered by `rel_path` in SQLite BINARY (UTF-8 byte) order, then id.
    /// Page and total come from one read transaction, so they are mutually consistent.
    public func folderMembers(folderId: Int64, offset: Int, limit: Int) throws -> FolderMemberPage {
        guard offset >= 0, (1...Self.folderMembersMaxLimit).contains(limit) else { throw StorageV19Error.invalidValue }
        return try dbQueue.read { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM folder_sources WHERE id=?", arguments: [folderId]) != nil else {
                throw StorageV19Error.notFound
            }
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sources WHERE folder_id=? AND type<>'note'",
                                         arguments: [folderId]) ?? 0
            let members = try Source.fetchAll(db, sql: """
                SELECT * FROM sources WHERE folder_id=? AND type<>'note' ORDER BY rel_path, id LIMIT ? OFFSET ?
                """, arguments: [folderId, limit, offset])
            return FolderMemberPage(members: members, offset: offset, total: total)
        }
    }

    /// Non-note sources that belong to no folder, newest first (the ungrouped part of the Sources list).
    public func looseSources(notebookId: Int64) throws -> [Source] {
        try dbQueue.read { db in
            try Source.fetchAll(db, sql: """
                SELECT * FROM sources WHERE notebook_id=? AND folder_id IS NULL AND type<>'note'
                ORDER BY ingested_at DESC, id DESC
                """, arguments: [notebookId])
        }
    }
}

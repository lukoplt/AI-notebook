import Foundation
import GRDB

public struct Source: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var notebookId: Int64
    public var type: SourceType
    public var title: String
    public var uri: String?
    public var rawPath: String?
    public var status: SourceStatus
    public var error: String?
    public var ingestedAt: Date
    /// Last successful re-sync of a live source (folder watch / URL re-crawl,
    /// FR-E1/E2). Nil for static sources.
    public var lastSyncedAt: Date?
    /// Content hash used to skip unchanged live sources on re-sync (FR-E1/E2).
    public var contentHash: String?

    public init(
        id: Int64? = nil,
        notebookId: Int64,
        type: SourceType,
        title: String,
        uri: String? = nil,
        rawPath: String? = nil,
        status: SourceStatus = .pending,
        error: String? = nil,
        ingestedAt: Date = Date(),
        lastSyncedAt: Date? = nil,
        contentHash: String? = nil
    ) {
        self.id = id
        self.notebookId = notebookId
        self.type = type
        self.title = title
        self.uri = uri
        self.rawPath = rawPath
        self.status = status
        self.error = error
        self.ingestedAt = ingestedAt
        self.lastSyncedAt = lastSyncedAt
        self.contentHash = contentHash
    }
}

extension Source: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "sources"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case notebookId  = "notebook_id"
        case type
        case title
        case uri
        case rawPath     = "raw_path"
        case status
        case error
        case ingestedAt   = "ingested_at"
        case lastSyncedAt = "last_synced_at"
        case contentHash  = "content_hash"

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// In-memory chunk produced by the chunker, not yet persisted.
public struct ChunkDraft: Equatable, Hashable, Sendable {
    public var text: String
    public var tokenCount: Int
    public var pageHint: Int?

    public init(text: String, tokenCount: Int, pageHint: Int? = nil) {
        self.text = text
        self.tokenCount = tokenCount
        self.pageHint = pageHint
    }
}

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

    public var folderId: Int64?
    public var relPath: String?
    public var mtime: Int64?
    public var sizeBytes: Int64?
    public var availability: String
    public var eligible: Bool
    public var lang: String?
    public var langCoverage: String?
    public var descriptor: String?
    public var currentRevision: Int64?
    public var publishedRevisionId: Int64?
    public var encoding: String?

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
        contentHash: String? = nil,
        folderId: Int64? = nil,
        relPath: String? = nil,
        mtime: Int64? = nil,
        sizeBytes: Int64? = nil,
        availability: String = "present",
        eligible: Bool = true,
        lang: String? = nil,
        langCoverage: String? = nil,
        descriptor: String? = nil,
        currentRevision: Int64? = nil,
        publishedRevisionId: Int64? = nil,
        encoding: String? = nil
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
        self.folderId = folderId
        self.relPath = relPath
        self.mtime = mtime
        self.sizeBytes = sizeBytes
        self.availability = availability
        self.eligible = eligible
        self.lang = lang
        self.langCoverage = langCoverage
        self.descriptor = descriptor
        self.currentRevision = currentRevision
        self.publishedRevisionId = publishedRevisionId
        self.encoding = encoding
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

        case folderId = "folder_id"
        case relPath = "rel_path"
        case mtime = "mtime"
        case sizeBytes = "size_bytes"
        case availability = "availability"
        case eligible = "eligible"
        case lang = "lang"
        case langCoverage = "lang_coverage"
        case descriptor = "descriptor"
        case currentRevision = "current_revision"
        case publishedRevisionId = "published_revision_id"
        case encoding = "encoding"

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

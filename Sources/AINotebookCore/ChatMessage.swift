import Foundation
import GRDB

public enum ChatRole: String, Codable, Sendable, CaseIterable {
    case system
    case user
    case assistant
}

public struct CitationSpan: Equatable, Hashable, Codable, Sendable {
    public let start: Int
    public let end: Int
    public let pageFrom: Int?
    public let pageTo: Int?

    public init(start: Int, end: Int, pageFrom: Int?, pageTo: Int?) {
        self.start = start
        self.end = end
        self.pageFrom = pageFrom
        self.pageTo = pageTo
    }
}

public struct Citation: Equatable, Hashable, Codable, Sendable {
    public let marker: Int
    public let chunkId: Int64
    public let sourceId: Int64
    public let snippet: String
    // v2 (context pack) — all optional so legacy rows decode unchanged.
    public var folderId: Int64? = nil
    public var relPath: String? = nil
    public var displayName: String? = nil
    public var revisionId: Int64? = nil
    public var spans: [CitationSpan] = []
    public var chunkIds: [Int64] = []
    public var text: String? = nil

    public init(marker: Int, chunkId: Int64, sourceId: Int64, snippet: String) {
        self.marker = marker
        self.chunkId = chunkId
        self.sourceId = sourceId
        self.snippet = snippet
    }

    var isV2: Bool {
        folderId != nil || relPath != nil || displayName != nil || revisionId != nil
            || !spans.isEmpty || !chunkIds.isEmpty || text != nil
    }

    private enum CodingKeys: String, CodingKey {
        case marker, chunkId, sourceId, snippet
        case folderId, relPath, displayName, revisionId, spans, chunkIds, text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        marker = try c.decode(Int.self, forKey: .marker)
        chunkId = try c.decode(Int64.self, forKey: .chunkId)
        sourceId = try c.decode(Int64.self, forKey: .sourceId)
        snippet = try c.decode(String.self, forKey: .snippet)
        folderId = try c.decodeIfPresent(Int64.self, forKey: .folderId)
        relPath = try c.decodeIfPresent(String.self, forKey: .relPath)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        revisionId = try c.decodeIfPresent(Int64.self, forKey: .revisionId)
        spans = try c.decodeIfPresent([CitationSpan].self, forKey: .spans) ?? []
        chunkIds = try c.decodeIfPresent([Int64].self, forKey: .chunkIds) ?? []
        text = try c.decodeIfPresent(String.self, forKey: .text)
        guard (1...Int(Int32.max)).contains(marker), chunkId >= 0, sourceId >= 0,
              spans.allSatisfy({ $0.start >= 0 && $0.start < $0.end
                  && ($0.pageFrom == nil || $0.pageTo == nil || $0.pageFrom! <= $0.pageTo!) })
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "citation out of contract range"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(marker, forKey: .marker)
        try c.encode(chunkId, forKey: .chunkId)
        try c.encode(sourceId, forKey: .sourceId)
        try c.encode(snippet, forKey: .snippet)
        try c.encodeIfPresent(folderId, forKey: .folderId)
        try c.encodeIfPresent(relPath, forKey: .relPath)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encodeIfPresent(revisionId, forKey: .revisionId)
        if !spans.isEmpty { try c.encode(spans, forKey: .spans) }
        if !chunkIds.isEmpty { try c.encode(chunkIds, forKey: .chunkIds) }
        try c.encodeIfPresent(text, forKey: .text)
    }
}

public struct ChatMessage: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var sessionId: Int64
    public var role: ChatRole
    public var content: String
    public var citations: [Citation]
    /// The provider-qualified model that generated this (assistant) message,
    /// shown as a badge after a regenerate with a different model (FR-C3).
    /// Nil for user messages and pre-v13 rows.
    public var model: String?
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        sessionId: Int64,
        role: ChatRole,
        content: String,
        citations: [Citation] = [],
        model: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.citations = citations
        self.model = model
        self.createdAt = createdAt
    }
}

extension ChatMessage: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "messages"

    public enum Columns: String {
        case id
        case sessionId     = "session_id"
        case role
        case content
        case citationsJson = "citations_json"
        case model
        case createdAt     = "created_at"

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(row: Row) throws {
        let cits = CitationsCodec.decode(row[Columns.citationsJson.rawValue] as String?)
        let roleRaw: String = row[Columns.role.rawValue]
        self.init(
            id: row[Columns.id.rawValue],
            sessionId: row[Columns.sessionId.rawValue],
            role: ChatRole(rawValue: roleRaw) ?? .user,
            content: row[Columns.content.rawValue],
            citations: cits,
            model: row[Columns.model.rawValue],
            createdAt: row[Columns.createdAt.rawValue]
        )
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.sessionId.rawValue] = sessionId
        container[Columns.role.rawValue]      = role.rawValue
        container[Columns.content.rawValue]   = content
        container[Columns.citationsJson.rawValue] = CitationsCodec.encode(citations)
        container[Columns.model.rawValue] = model
        container[Columns.createdAt.rawValue] = createdAt
    }
}

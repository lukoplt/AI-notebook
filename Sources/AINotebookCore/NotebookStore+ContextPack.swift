import Foundation
import CryptoKit
import GRDB

/// Metadata the context-pack adapters materialize under the store boundary.
public struct ContextSourceDetail: Equatable, Sendable {
    public let sourceId: Int64
    public let notebookId: Int64
    public let type: SourceType
    public let title: String
    public let folderId: Int64?
    public let relPath: String?
    public let lang: String?
    public let descriptor: String?
}

public struct ContextFolderDetail: Equatable, Sendable {
    public let id: Int64
    public let displayName: String
    public let scanState: String
    public let lastFullScanAt: Int64?
}

/// One read snapshot of a turn's store inputs (`NotebookStore.contextReadSnapshot`).
/// The materialized fields are filled only for a pin.
public struct ContextReadSnapshot: Sendable {
    public let historyFingerprint: String
    public let scopeFingerprint: String
    public let notebookName: String
    public let notebookInstructions: String
    public let evidenceBudgetCap: Int?
    public var messages: [ChatMessage] = []
    public var coverage = CoverageSnapshot(searchable: 0, pending: 0, error: 0, skipped: 0, missing: 0, unavailable: 0,
                                           refreshPending: 0, refreshError: 0, isLowerBound: false,
                                           notSearchable: 0, current: 0)
    public var folders: [Int64: ContextFolderDetail] = [:]

    init(historyFingerprint: String, scopeFingerprint: String, notebookName: String, notebookInstructions: String,
         evidenceBudgetCap: Int?) {
        self.historyFingerprint = historyFingerprint
        self.scopeFingerprint = scopeFingerprint
        self.notebookName = notebookName
        self.notebookInstructions = notebookInstructions
        self.evidenceBudgetCap = evidenceBudgetCap
    }
}

/// The live identity an original-opening request is checked against.
public struct ContextOriginalRecord: Sendable {
    public let source: ContextSourceDetail
    public let rawPath: String?
    public let currentRevisionId: Int64?
    public let folder: FolderSource?
    public let noteId: Int64?
}

extension NotebookStore {
    // MARK: Freshness fingerprints

    /// SHA-256 over every persisted message (ID, role, content, model and
    /// citations JSON) ordered by ID. An in-place edit changes the digest.
    public func contextHistoryFingerprint(sessionId: Int64) throws -> String {
        try dbQueue.read { try Self.contextHistoryFingerprint($0, sessionId: sessionId) }
    }

    /// SHA-256 over the selection, the notebook's folder set and the scope's
    /// REVOKED sources (not present, or not eligible): their folder membership,
    /// availability and eligibility. Revision freshness is excluded, and so are
    /// usable sources: a file a running folder check discovers, or whose
    /// extraction publishes, only adds evidence and never makes a prepared turn
    /// stale; a source that became missing, unavailable or ineligible does
    /// (`chat-during-scan-v1` §3). Removing a folder changes the folder set; a
    /// loose source deleted while a turn is in flight is not detected here (its
    /// citation then resolves as unavailable).
    public func contextScopeFingerprint(notebookId: Int64, scope: RetrievalScope) throws -> String {
        try dbQueue.read { try Self.contextScopeFingerprint($0, notebookId: notebookId, scope: scope) }
    }

    nonisolated static func contextHistoryFingerprint(_ db: Database, sessionId: Int64) throws -> String {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id,role,content,model,citations_json FROM messages WHERE session_id=? ORDER BY id
            """, arguments: [sessionId])
        let items: [Any] = rows.map { row -> NSDictionary in
            let model: String? = row["model"], citations: String? = row["citations_json"]
            return ["id": row["id"] as Int64, "role": row["role"] as String, "content": row["content"] as String,
                    "model": model.map { $0 as Any } ?? NSNull(),
                    "citations": citations.map { $0 as Any } ?? NSNull()] as NSDictionary
        }
        return try digest(["sessionId": sessionId, "messages": items] as NSDictionary)
    }

    nonisolated static func contextScopeFingerprint(_ db: Database, notebookId: Int64, scope: RetrievalScope) throws -> String {
        let kind: String, sourceIds: [Int64], folderIds: [Int64]
        switch scope {
        case .all: kind = "all"; sourceIds = []; folderIds = []
        case let .selection(s, f): kind = "selection"; sourceIds = s.sorted(); folderIds = f.sorted()
        }
        let rows = scope.isEmptySelection ? [] : try Row.fetchAll(db, sql: """
            SELECT id,folder_id,availability,eligible FROM sources s
            WHERE s.notebook_id=$nb AND (s.availability<>'present' OR s.eligible=0)
              AND ($all=1 OR s.id IN (SELECT CAST(value AS INTEGER) FROM json_each($sourceIds))
                   OR s.folder_id IN (SELECT CAST(value AS INTEGER) FROM json_each($folderIds)))
            ORDER BY id
            """, arguments: RetrievalSQL.arguments(notebookId: notebookId, scope: scope))
        let sources: [Any] = rows.map { row -> NSDictionary in
            let folder: Int64? = row["folder_id"]
            return ["id": row["id"] as Int64, "folderId": folder.map { $0 as Any } ?? NSNull(),
                    "availability": row["availability"] as String, "eligible": row["eligible"] as Bool] as NSDictionary
        }
        let folders = try Int64.fetchAll(db, sql: "SELECT id FROM folder_sources WHERE notebook_id=? ORDER BY id",
                                         arguments: [notebookId])
        return try digest(["notebookId": notebookId, "kind": kind, "sourceIds": sourceIds,
                           "folderIds": folderIds, "sources": sources, "folders": folders] as NSDictionary)
    }

    /// Everything a turn's capture or pin reads from the store, from ONE read
    /// snapshot (`chat-during-scan-v1` §2): a concurrent scan, extraction or
    /// embedding commit can never make the fingerprints, history, instructions
    /// and coverage disagree with each other. Runs on any thread; with the WAL
    /// pool it never waits for a background write.
    public func contextReadSnapshot(notebookId: Int64, sessionId: Int64, scope: RetrievalScope,
                                    includeMaterialized: Bool) throws -> ContextReadSnapshot {
        try dbQueue.read { db in
            guard let notebook = try Row.fetchOne(db, sql: """
                SELECT name,instructions,evidence_budget_cap FROM notebooks WHERE id=?
                """, arguments: [notebookId]) else { throw StorageV19Error.notFound }
            var snapshot = ContextReadSnapshot(
                historyFingerprint: try Self.contextHistoryFingerprint(db, sessionId: sessionId),
                scopeFingerprint: try Self.contextScopeFingerprint(db, notebookId: notebookId, scope: scope),
                notebookName: notebook["name"], notebookInstructions: notebook["instructions"] ?? "",
                evidenceBudgetCap: notebook["evidence_budget_cap"])
            guard includeMaterialized else { return snapshot }
            guard let owner = try Int64.fetchOne(db, sql: "SELECT notebook_id FROM chat_sessions WHERE id=?",
                                                 arguments: [sessionId]) else { throw StorageV19Error.notFound }
            guard owner == notebookId else { throw StorageV19Error.notebookMismatch }
            snapshot.messages = try ChatMessage
                .filter(ChatMessage.Columns.sessionId.column == sessionId)
                .order(ChatMessage.Columns.createdAt.column.asc)
                .fetchAll(db)
            snapshot.coverage = try Self.coverage(db, notebookId: notebookId, scope: scope)
            snapshot.folders = try Self.contextFolders(db, notebookId: notebookId)
            return snapshot
        }
    }

    private nonisolated static func digest(_ object: NSDictionary) throws -> String {
        let bytes = try PreparedContextRequestJSON.canonicalData(object)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Turn persistence

    /// Inserts the current user turn and returns it with its real ID.
    public func appendContextUser(sessionId: Int64, text: String) throws -> ChatMessage {
        var message = ChatMessage(sessionId: sessionId, role: .user, content: text)
        try dbQueue.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chat_sessions WHERE id=?)",
                                    arguments: [sessionId]) == true else { throw StorageV19Error.notFound }
            try message.insert(db)
        }
        return message
    }

    /// Removes a user turn that never got an answer (a new turn stopped before
    /// any text streamed). Deletes only when `messageId` is a user row of
    /// `sessionId` and nothing newer follows it in the session; returns whether
    /// the row was removed. Inverse of `appendContextUser`.
    @discardableResult
    public func deleteUnansweredQuestion(sessionId: Int64, messageId: Int64) throws -> Bool {
        try dbQueue.write { db in
            guard try String.fetchOne(db, sql: "SELECT role FROM messages WHERE id=? AND session_id=?",
                                      arguments: [messageId, sessionId]) == ChatRole.user.rawValue,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE session_id=? AND id>?)",
                                    arguments: [sessionId, messageId]) == false else { return false }
            try db.execute(sql: "DELETE FROM messages WHERE id=?", arguments: [messageId])
            return true
        }
    }

    /// One transaction, run only after a successful stream: optionally
    /// rewrites the edited user text, deletes the replaced assistant and
    /// inserts the new answer. IDs must belong to `sessionId` with the right roles.
    public func commitContextAssistant(sessionId: Int64, content: String, citations: [Citation], model: String,
                                       replacesAssistantId: Int64?, replacesUserId: Int64?,
                                       replacementUserText: String?) throws -> ChatMessage {
        var message = ChatMessage(sessionId: sessionId, role: .assistant, content: content,
                                  citations: citations, model: model)
        try dbQueue.write { db in
            func owned(_ id: Int64, role: ChatRole) throws -> Row {
                guard let row = try Row.fetchOne(db, sql: "SELECT role,content FROM messages WHERE id=? AND session_id=?",
                                                 arguments: [id, sessionId]),
                      row["role"] as String == role.rawValue else { throw StorageV19Error.notebookMismatch }
                return row
            }
            if let userId = replacesUserId {
                let row = try owned(userId, role: .user)
                if let text = replacementUserText, !(row["content"] as String).utf8.elementsEqual(text.utf8) {
                    try db.execute(sql: "UPDATE messages SET content=? WHERE id=?", arguments: [text, userId])
                }
            } else if replacementUserText != nil {
                throw StorageV19Error.invalidValue
            }
            if let assistantId = replacesAssistantId {
                _ = try owned(assistantId, role: .assistant)
                try db.execute(sql: "DELETE FROM messages WHERE id=?", arguments: [assistantId])
            }
            try message.insert(db)
        }
        return message
    }

    // MARK: Pinned-read metadata

    func contextValidateSession(notebookId: Int64, sessionId: Int64) throws {
        try dbQueue.read { db in
            guard let owner = try Int64.fetchOne(db, sql: "SELECT notebook_id FROM chat_sessions WHERE id=?",
                                                 arguments: [sessionId]) else { throw StorageV19Error.notFound }
            guard owner == notebookId else { throw StorageV19Error.notebookMismatch }
        }
    }

    func contextNotebookName(id: Int64) throws -> String {
        try dbQueue.read { db in
            guard let name = try String.fetchOne(db, sql: "SELECT name FROM notebooks WHERE id=?", arguments: [id]) else {
                throw StorageV19Error.notFound
            }
            return name
        }
    }

    func contextSourceDetails(ids: [Int64]) throws -> [Int64: ContextSourceDetail] {
        guard !ids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id,notebook_id,type,title,folder_id,rel_path,lang,descriptor FROM sources
                WHERE id IN (SELECT CAST(value AS INTEGER) FROM json_each(?))
                """, arguments: [try RetrievalSQL.json(Set(ids).sorted())])
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let detail = Self.detail(row)
                return (detail.sourceId, detail)
            })
        }
    }

    private nonisolated static func detail(_ row: Row) -> ContextSourceDetail {
        let rawType: String = row["type"]
        return ContextSourceDetail(sourceId: row["id"], notebookId: row["notebook_id"],
                                   type: SourceType(rawValue: rawType) ?? .text, title: row["title"],
                                   folderId: row["folder_id"], relPath: row["rel_path"], lang: row["lang"],
                                   descriptor: row["descriptor"])
    }

    func contextFolders(notebookId: Int64) throws -> [Int64: ContextFolderDetail] {
        try dbQueue.read { try Self.contextFolders($0, notebookId: notebookId) }
    }

    nonisolated static func contextFolders(_ db: Database, notebookId: Int64) throws -> [Int64: ContextFolderDetail] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id,display_name,scan_state,last_full_scan_at FROM folder_sources WHERE notebook_id=?
            """, arguments: [notebookId])
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            (row["id"] as Int64, ContextFolderDetail(id: row["id"], displayName: row["display_name"],
                                                     scanState: row["scan_state"], lastFullScanAt: row["last_full_scan_at"]))
        })
    }

    func contextChunkLanguages(chunkIds: [Int64]) throws -> [Int64: String] {
        guard !chunkIds.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id,lang FROM source_chunks WHERE lang IS NOT NULL
                  AND id IN (SELECT CAST(value AS INTEGER) FROM json_each(?))
                """, arguments: [try RetrievalSQL.json(Set(chunkIds).sorted())])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as Int64, $0["lang"] as String) })
        }
    }

    /// The first chunk (ordinal 0) of each given published revision.
    func contextFirstChunks(revisions: [Int64: Int64]) throws -> [ChunkReference] {
        guard !revisions.isEmpty else { return [] }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT sc.id,sc.source_id,sc.revision_id,sc.ord FROM source_chunks sc
                JOIN json_each(?) p ON CAST(json_extract(p.value,'$.sourceId') AS INTEGER)=sc.source_id
                  AND CAST(json_extract(p.value,'$.revisionId') AS INTEGER)=sc.revision_id
                WHERE sc.ord=0 ORDER BY sc.source_id
                """, arguments: [try RetrievalSQL.pairs(revisions)]).map(RetrievalSQL.reference)
        }
    }

    /// Refetches the live source, its folder and current revision for one click.
    func contextOriginal(notebookId: Int64, sourceId: Int64) throws -> ContextOriginalRecord? {
        let found = try dbQueue.read { db -> (ContextSourceDetail, String?, Int64?, Int64?)? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id,notebook_id,type,title,folder_id,rel_path,lang,descriptor,raw_path,current_revision,
                       published_revision_id FROM sources WHERE id=? AND notebook_id=?
                """, arguments: [sourceId, notebookId]) else { return nil }
            let detail = Self.detail(row)
            let current: Int64? = row["current_revision"], published: Int64? = row["published_revision_id"]
            let noteId = detail.type == .note
                ? try Int64.fetchOne(db, sql: "SELECT id FROM notes WHERE auto_source_id=? AND notebook_id=?",
                                     arguments: [sourceId, notebookId])
                : nil
            return (detail, row["raw_path"], current ?? published, noteId)
        }
        guard let (detail, rawPath, revision, noteId) = found else { return nil }
        let folder = try detail.folderId.flatMap { id in try folders(notebookId: notebookId).first { $0.id == id } }
        return ContextOriginalRecord(source: detail, rawPath: rawPath, currentRevisionId: revision,
                                     folder: folder, noteId: noteId)
    }
}

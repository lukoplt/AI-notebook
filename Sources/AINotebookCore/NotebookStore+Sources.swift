import Foundation
import CryptoKit
import GRDB

extension NotebookStore {

    @discardableResult
    public func createSource(
        notebookId: Int64,
        type: SourceType,
        title: String,
        uri: String?,
        rawPath: String?
    ) throws -> Source {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StoreError.invalidSourceTitle(title)
        }
        var source = Source(
            notebookId: notebookId,
            type: type,
            title: trimmed,
            uri: uri,
            rawPath: rawPath,
            status: .pending,
            error: nil,
            ingestedAt: Date()
        )
        try runOnDatabase { db in
            try source.insert(db)
        }
        return source
    }

    public func sources(notebookId: Int64) throws -> [Source] {
        try dbQueue.read { db in
            try Source
                .filter(Source.Columns.notebookId.column == notebookId)
                .filter(Source.Columns.type.column != SourceType.note.rawValue)
                .order(Source.Columns.ingestedAt.column.desc)
                .fetchAll(db)
        }
    }

    public func sourcesIncludingShadow(notebookId: Int64) throws -> [Source] {
        try dbQueue.read { db in
            try Source
                .filter(Source.Columns.notebookId.column == notebookId)
                .order(Source.Columns.ingestedAt.column.desc)
                .fetchAll(db)
        }
    }

    public func source(id: Int64) throws -> Source? {
        try dbQueue.read { db in
            try Source.fetchOne(db, key: id)
        }
    }

    public func updateSourceStatus(
        id: Int64,
        status: SourceStatus,
        error: String?
    ) throws {
        try runOnDatabase { db in
            guard var s = try Source.fetchOne(db, key: id) else {
                throw StoreError.sourceNotFound(id)
            }
            s.status = status
            s.error  = error
            try s.update(db)
        }
    }

    public func deleteSource(id: Int64) throws {
        try runOnDatabase { db in
            let removed = try Source.deleteOne(db, key: id)
            guard removed else { throw StoreError.sourceNotFound(id) }
        }
    }

    public func replaceChunks(
        sourceId: Int64,
        chunks: [ChunkDraft]
    ) throws {
        try runOnDatabase { db in
            let canonical = chunks.map(\.text).joined(separator: "\n\n")
            let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
            _ = try RevisionJobSQL.commitForegroundRevision(db, sourceId: sourceId,
                draft: RevisionDraft(contentHash: hash, canonicalText: canonical, textFormatVersion: 1, chunkerVersion: 1),
                chunks: chunks.map { RevisionChunkDraft(text: $0.text, tokenCount: $0.tokenCount,
                    pageHint: $0.pageHint, charStart: nil, charEnd: nil, lang: nil, langInherited: false) },
                now: Int64(Date().timeIntervalSince1970), leaseToken: UUID().uuidString)
        }
    }

    public func chunks(sourceId: Int64) throws -> [SourceChunk] {
        try dbQueue.read { db in
            try SourceChunk.fetchAll(db, sql: """
                SELECT c.* FROM source_chunks c JOIN sources s ON s.id=c.source_id
                WHERE s.id=? AND c.revision_id=s.published_revision_id ORDER BY c.ord
                """, arguments: [sourceId])
        }
    }

    /// The persisted summary for a source, or `nil` if not yet computed.
    public func sourceSummary(id: Int64) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT summary FROM sources WHERE id = ?",
                arguments: [id]
            )
        }
    }

    public func setSourceSummary(id: Int64, text: String) throws {
        try runOnDatabase { db in
            try db.execute(
                sql: "UPDATE sources SET summary = ? WHERE id = ?",
                arguments: [text, id]
            )
        }
    }
}

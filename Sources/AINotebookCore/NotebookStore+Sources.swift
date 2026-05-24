import Foundation
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
        try runOnDatabase { db in
            try Source
                .filter(Source.Columns.notebookId.column == notebookId)
                .filter(Source.Columns.type.column != SourceType.note.rawValue)
                .order(Source.Columns.ingestedAt.column.desc)
                .fetchAll(db)
        }
    }

    public func sourcesIncludingShadow(notebookId: Int64) throws -> [Source] {
        try runOnDatabase { db in
            try Source
                .filter(Source.Columns.notebookId.column == notebookId)
                .order(Source.Columns.ingestedAt.column.desc)
                .fetchAll(db)
        }
    }

    public func source(id: Int64) throws -> Source? {
        try runOnDatabase { db in
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
            try SourceChunk
                .filter(SourceChunk.Columns.sourceId.column == sourceId)
                .deleteAll(db)
            for (ord, draft) in chunks.enumerated() {
                var row = SourceChunk(
                    sourceId: sourceId,
                    ord: ord,
                    text: draft.text,
                    tokenCount: draft.tokenCount,
                    pageHint: draft.pageHint
                )
                try row.insert(db)
            }
        }
    }

    public func chunks(sourceId: Int64) throws -> [SourceChunk] {
        try runOnDatabase { db in
            try SourceChunk
                .filter(SourceChunk.Columns.sourceId.column == sourceId)
                .order(SourceChunk.Columns.ord.column.asc)
                .fetchAll(db)
        }
    }
}

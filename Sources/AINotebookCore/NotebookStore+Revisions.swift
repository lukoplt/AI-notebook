import Foundation
import GRDB

extension NotebookStore {
    public func insertRevision(sourceId: Int64, draft: RevisionDraft, now: Int64) throws -> SourceRevision {
        try dbQueue.write { try RevisionJobSQL.insertRevision($0, sourceId: sourceId, draft: draft, now: now) }
    }

    public func revision(id: Int64) throws -> SourceRevision? {
        try dbQueue.read { try RevisionJobSQL.revision($0, id: id) }
    }

    public func revisionPages(revisionId: Int64) throws -> [PageBoundary] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.page,p.char_start,p.char_end
                FROM revision_pages p JOIN source_revisions r ON r.id=p.revision_id
                WHERE r.id=? ORDER BY p.page
                """, arguments: [revisionId]).map { row in
                    PageBoundary(page: row["page"], start: row["char_start"], end: row["char_end"])
                }
        }
    }

    public func publishRevision(sourceId: Int64, revisionId: Int64, chunks: [RevisionChunkDraft], fence: JobFence, now: Int64) throws -> Bool {
        try dbQueue.write { try RevisionJobSQL.publishRevision($0, sourceId: sourceId, revisionId: revisionId, chunks: chunks, fence: fence, now: now) }
    }

    public func commitForegroundRevision(sourceId: Int64, draft: RevisionDraft, chunks: [RevisionChunkDraft], now: Int64, leaseToken: String) throws -> SourceRevision {
        try dbQueue.write { try RevisionJobSQL.commitForegroundRevision($0, sourceId: sourceId, draft: draft, chunks: chunks, now: now, leaseToken: leaseToken) }
    }

    public func beginExtraction(sourceId: Int64, now: Int64, leaseToken: String) throws -> JobFence {
        try dbQueue.write { try RevisionJobSQL.beginExtraction($0, sourceId: sourceId, now: now, leaseToken: leaseToken) }
    }

    public func commitExtraction(sourceId: Int64, draft: RevisionDraft, chunks: [RevisionChunkDraft], fence: JobFence, now: Int64) throws -> SourceRevision? {
        try dbQueue.write { try RevisionJobSQL.commitExtraction($0, sourceId: sourceId, draft: draft, chunks: chunks, fence: fence, now: now) }
    }
}

/// Kernels use the caller's transaction; async work never holds a database transaction.
enum RevisionJobSQL {
    static func revision(_ db: Database, id: Int64) throws -> SourceRevision? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM source_revisions WHERE id=?", arguments: [id]) else { return nil }
        let date: Date = row["created_at"]
        return SourceRevision(id: row["id"], sourceId: row["source_id"], revision: row["revision"],
            draft: RevisionDraft(contentHash: row["content_hash"], canonicalText: row["canonical_text"],
                                 textFormatVersion: row["text_format_version"], chunkerVersion: row["chunker_version"]),
            createdAt: Int64(date.timeIntervalSince1970))
    }

    static func insertRevision(_ db: Database, sourceId: Int64, draft: RevisionDraft, now: Int64) throws -> SourceRevision {
        guard !draft.contentHash.isEmpty, [1, SpreadsheetText.formatVersion].contains(draft.textFormatVersion), [1, 2].contains(draft.chunkerVersion) else { throw StorageV19Error.invalidValue }
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM sources WHERE id=?", arguments: [sourceId]) != nil else { throw StorageV19Error.notFound }
        let ordinal = try Int.fetchOne(db, sql: "SELECT coalesce(max(revision),0)+1 FROM source_revisions WHERE source_id=?", arguments: [sourceId])!
        try db.execute(sql: """
            INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
            VALUES(?,?,?,?,?,?,?)
            """, arguments: [sourceId, ordinal, draft.contentHash, draft.canonicalText, draft.textFormatVersion,
                              draft.chunkerVersion, Date(timeIntervalSince1970: TimeInterval(now))])
        let id = db.lastInsertedRowID
        try db.execute(sql: "UPDATE sources SET current_revision=? WHERE id=?", arguments: [id, sourceId])
        return SourceRevision(id: id, sourceId: sourceId, revision: ordinal, draft: draft, createdAt: now)
    }

    static func insertChunkSet(_ db: Database, revisionId: Int64, chunks: [RevisionChunkDraft]) throws {
        guard let revision = try revision(db, id: revisionId) else { throw StorageV19Error.notFound }
        let scalars = Array(revision.draft.canonicalText.unicodeScalars)
        // Validate the entire set before the first insertion, even within the enclosing transaction.
        for chunk in chunks {
            guard chunk.tokenCount >= 0,
                  chunk.lang.map({ ["cs", "sk", "en", "de", "und"].contains($0) }) ?? true,
                  !chunk.langInherited || chunk.lang != nil else { throw StorageV19Error.invalidValue }
            if revision.draft.chunkerVersion == 2 {
                guard let start = chunk.charStart, let end = chunk.charEnd,
                      start >= 0, start < end, end <= scalars.count,
                      String(String.UnicodeScalarView(scalars[start..<end])).utf8.elementsEqual(chunk.text.utf8) else {
                    throw StorageV19Error.invalidSpan
                }
            } else if chunk.charStart != nil || chunk.charEnd != nil {
                throw StorageV19Error.invalidSpan
            }
        }
        guard try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM source_chunks WHERE revision_id=?)
                OR EXISTS(SELECT 1 FROM sources WHERE published_revision_id=?)
            """, arguments: [revisionId, revisionId]) == false else { throw StorageV19Error.immutableRevision }
        let insert = try db.makeStatement(sql: """
            INSERT INTO source_chunks(source_id,revision_id,ord,text,token_count,page_hint,char_start,char_end,lang,lang_inherited)
            VALUES(?,?,?,?,?,?,?,?,?,?)
            """)
        for (ord, chunk) in chunks.enumerated() {
            try insert.execute(arguments: [revision.sourceId, revisionId, ord, chunk.text, chunk.tokenCount,
                                           chunk.pageHint, chunk.charStart, chunk.charEnd, chunk.lang, chunk.langInherited])
        }
    }

    static func publishRevision(_ db: Database, sourceId: Int64, revisionId: Int64,
                               chunks: [RevisionChunkDraft], fence: JobFence, now: Int64) throws -> Bool {
        guard let job = try validateFence(db, fence: fence, now: now) else { return false }
        guard let revision = try revision(db, id: revisionId) else { throw StorageV19Error.notFound }
        guard revision.sourceId == sourceId, job.draft.kind == "extract",
              job.draft.target == "source:\(sourceId)", job.draft.targetRevision == revisionId else {
            throw StorageV19Error.staleRevision
        }
        guard let source = try Row.fetchOne(db, sql: "SELECT current_revision FROM sources WHERE id=?", arguments: [sourceId]) else { throw StorageV19Error.notFound }
        let current: Int64? = source["current_revision"]
        guard current == revisionId else {
            try cancelSuperseded(db, jobId: job.id)
            return false
        }
        try insertChunkSet(db, revisionId: revisionId, chunks: chunks)
        try db.execute(sql: "UPDATE sources SET published_revision_id=?,content_hash=?,status='ready',error=NULL WHERE id=?",
                       arguments: [revisionId, revision.draft.contentHash, sourceId])
        try RetryBudgetSQL.clear(db, sourceId: sourceId)
        // Extraction can only complete together with publication, never via generic completeJob.
        try db.execute(sql: "UPDATE ingest_jobs SET state='done',lease_until=NULL,lease_token=NULL,next_retry_at=NULL WHERE id=?", arguments: [job.id])
        return true
    }

    static func beginExtraction(_ db: Database, sourceId: Int64, now: Int64, leaseToken: String) throws -> JobFence {
        guard let source = try Row.fetchOne(db, sql: "SELECT current_revision FROM sources WHERE id=?", arguments: [sourceId]) else { throw StorageV19Error.notFound }
        // A foreground (re)ingestion is a user action on new or explicitly retried content (ingestion-retry-cap-v1 §5).
        try RetryBudgetSQL.resetIfGaveUp(db, sourceId: sourceId)
        let expectedRevision: Int64? = source["current_revision"]
        try db.execute(sql: """
            UPDATE ingest_jobs SET state='cancelled',lease_until=NULL,lease_token=NULL,next_retry_at=NULL
            WHERE kind='extract' AND target=? AND (state IN ('queued','running','paused') OR (state='failed' AND next_retry_at IS NOT NULL))
            """, arguments: ["source:\(sourceId)"])
        let id = try enqueueJob(db, draft: IngestJobDraft(kind: "extract", target: "source:\(sourceId)", targetRevision: expectedRevision), now: now)
        guard try claimJob(db, now: now, leaseToken: leaseToken, id: id) != nil else { throw StorageV19Error.staleLease }
        try db.execute(sql: "UPDATE sources SET status='chunking',error=NULL WHERE id=?", arguments: [sourceId])
        return JobFence(jobId: id, leaseToken: leaseToken)
    }

    static func commitExtraction(_ db: Database, sourceId: Int64, draft: RevisionDraft,
                                 chunks: [RevisionChunkDraft], fence: JobFence, now: Int64) throws -> SourceRevision? {
        guard let job = try validateFence(db, fence: fence, now: now), job.draft.kind == "extract",
              job.draft.target == "source:\(sourceId)" else { return nil }
        guard let source = try Row.fetchOne(db, sql: "SELECT current_revision FROM sources WHERE id=?", arguments: [sourceId]) else { return nil }
        let current: Int64? = source["current_revision"]
        guard current == job.draft.targetRevision else {
            try cancelSuperseded(db, jobId: job.id)
            return nil
        }
        let revision = try insertRevision(db, sourceId: sourceId, draft: draft, now: now)
        try db.execute(sql: "UPDATE ingest_jobs SET target_revision=? WHERE id=?", arguments: [revision.id, job.id])
        guard try publishRevision(db, sourceId: sourceId, revisionId: revision.id, chunks: chunks, fence: fence, now: now) else {
            throw StorageV19Error.staleLease
        }
        return revision
    }

    static func commitForegroundRevision(_ db: Database, sourceId: Int64, draft: RevisionDraft,
                                         chunks: [RevisionChunkDraft], now: Int64, leaseToken: String) throws -> SourceRevision {
        let fence = try beginExtraction(db, sourceId: sourceId, now: now, leaseToken: leaseToken)
        guard let result = try commitExtraction(db, sourceId: sourceId, draft: draft, chunks: chunks, fence: fence, now: now) else {
            throw StorageV19Error.staleLease
        }
        return result
    }

    private static func cancelSuperseded(_ db: Database, jobId: Int64) throws {
        try db.execute(sql: "UPDATE ingest_jobs SET state='cancelled',lease_until=NULL,lease_token=NULL,next_retry_at=NULL WHERE id=?", arguments: [jobId])
    }
}

import Foundation
import GRDB

extension NotebookStore {
    public func enqueueJob(_ draft: IngestJobDraft, now: Int64) throws -> Int64 {
        try dbQueue.write { try RevisionJobSQL.enqueueJob($0, draft: draft, now: now) }
    }

    public func job(id: Int64) throws -> IngestJob? {
        try dbQueue.read { try RevisionJobSQL.job($0, id: id) }
    }

    /// Posts `folderIngestionDidChange` for the claimed job's notebook and for
    /// every notebook whose expired lease the claim recovered.
    public func claimJob(now: Int64, leaseToken: String, id: Int64? = nil) throws -> IngestJob? {
        let (job, notebooks) = try dbQueue.write { db -> (IngestJob?, Set<Int64>) in
            var notebooks = try RevisionJobSQL.notebookIds(db, sql: RevisionJobSQL.expiredSQL, arguments: [now])
            let job = try RevisionJobSQL.claimJob(db, now: now, leaseToken: leaseToken, id: id)
            if let job, let notebook = try RevisionJobSQL.notebookId(db, draft: job.draft) { notebooks.insert(notebook) }
            return (job, notebooks)
        }
        notifyIndexingStatusChanged(notebookIds: notebooks)
        return job
    }

    public func recoverExpiredJobs(now: Int64) throws -> Int {
        let (count, notebooks) = try dbQueue.write { db -> (Int, Set<Int64>) in
            let notebooks = try RevisionJobSQL.notebookIds(db, sql: RevisionJobSQL.expiredSQL, arguments: [now])
            return (try RevisionJobSQL.recoverExpiredJobs(db, now: now), notebooks)
        }
        notifyIndexingStatusChanged(notebookIds: notebooks)
        return count
    }

    public func requeueRetryableJobs(now: Int64) throws -> Int {
        let (count, notebooks) = try dbQueue.write { db -> (Int, Set<Int64>) in
            let notebooks = try RevisionJobSQL.notebookIds(db, sql: RevisionJobSQL.retryableSQL, arguments: [now])
            return (try RevisionJobSQL.requeueRetryableJobs(db, now: now), notebooks)
        }
        notifyIndexingStatusChanged(notebookIds: notebooks)
        return count
    }

    /// The caller supplies the coalesced payload; a claimed job's captured options never change.
    public func updateQueuedJobOptions(id: Int64, optionsJSON: String) throws -> Bool {
        try dbQueue.write { try RevisionJobSQL.updateQueuedJobOptions($0, id: id, optionsJSON: optionsJSON) }
    }

    public func renewJob(fence: JobFence, now: Int64) throws -> Bool {
        try dbQueue.write { try RevisionJobSQL.renewJob($0, fence: fence, now: now) }
    }

    public func completeJob(fence: JobFence, now: Int64, targetGenerationId: Int64? = nil) throws -> Bool {
        try dbQueue.write { try RevisionJobSQL.completeJob($0, fence: fence, now: now, targetGenerationId: targetGenerationId) }
    }

    public func retargetEmbedJob(fence: JobFence, generationId: Int64, now: Int64) throws -> Bool {
        try dbQueue.write { try RevisionJobSQL.retargetEmbedJob($0, fence: fence, generationId: generationId, now: now) }
    }

    public func failJob(fence: JobFence, error: String, now: Int64) throws -> Bool {
        let (failed, notebookId) = try dbQueue.write { db -> (Bool, Int64?) in
            let job = try RevisionJobSQL.job(db, id: fence.jobId)
            guard try RevisionJobSQL.failJob(db, fence: fence, error: error, now: now) else { return (false, nil) }
            return (true, try job.flatMap { try RevisionJobSQL.notebookId(db, draft: $0.draft) })
        }
        if let notebookId { notifyIndexingStatusChanged(notebookId: notebookId) }
        return failed
    }

    public func retryJob(id: Int64, now: Int64) throws -> Bool {
        try dbQueue.write { try RevisionJobSQL.retryJob($0, id: id, now: now) }
    }

    public func pauseJob(id: Int64) throws {
        try dbQueue.write { try RevisionJobSQL.pauseJob($0, id: id) }
    }

    public func resumeJob(id: Int64, now: Int64) throws {
        try dbQueue.write { try RevisionJobSQL.resumeJob($0, id: id, now: now) }
    }

    public func cancelJob(id: Int64) throws {
        try dbQueue.write { try RevisionJobSQL.cancelJob($0, id: id) }
    }

    public func cancelJob(fence: JobFence, now: Int64) throws -> Bool {
        try dbQueue.write { try RevisionJobSQL.cancelJob($0, fence: fence, now: now) }
    }
}

extension RevisionJobSQL {
    /// Running jobs whose lease expired (recovered by `recoverExpiredJobs`).
    static let expiredSQL = "SELECT kind,target FROM ingest_jobs WHERE state='running' AND lease_until<=?"
    /// Failed jobs whose automatic retry is due (requeued by `requeueRetryableJobs`).
    static let retryableSQL = """
        SELECT kind,target FROM ingest_jobs WHERE state='failed' AND attempts<5 AND next_retry_at IS NOT NULL AND next_retry_at<=?
        """

    /// The notebook a job belongs to, from its target; nil when the target row is gone.
    static func notebookId(_ db: Database, draft: IngestJobDraft) throws -> Int64? {
        guard let colon = draft.target.firstIndex(of: ":"),
              let id = Int64(draft.target[draft.target.index(after: colon)...]) else { return nil }
        switch draft.target[..<colon] {
        case "folder": return try Int64.fetchOne(db, sql: "SELECT notebook_id FROM folder_sources WHERE id=?", arguments: [id])
        case "source": return try Int64.fetchOne(db, sql: "SELECT notebook_id FROM sources WHERE id=?", arguments: [id])
        case "notebook": return try Int64.fetchOne(db, sql: "SELECT id FROM notebooks WHERE id=?", arguments: [id])
        case "generation": return try Int64.fetchOne(db, sql: "SELECT notebook_id FROM index_generations WHERE id=?", arguments: [id])
        default: return nil
        }
    }

    /// Notebooks of the jobs a `SELECT kind,target …` query returns.
    static func notebookIds(_ db: Database, sql: String, arguments: StatementArguments) throws -> Set<Int64> {
        Set(try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
            try notebookId(db, draft: IngestJobDraft(kind: row["kind"], target: row["target"], targetRevision: nil))
        })
    }

    static func job(_ db: Database, id: Int64) throws -> IngestJob? {
        try Row.fetchOne(db, sql: "SELECT * FROM ingest_jobs WHERE id=?", arguments: [id]).map(decodeJob)
    }

    static func enqueueJob(_ db: Database, draft: IngestJobDraft, now: Int64) throws -> Int64 {
        try validateJobTarget(db, draft: draft)
        try validateJobOptions(draft.optionsJSON)
        try db.execute(sql: """
            INSERT INTO ingest_jobs(kind,target,target_revision,next_retry_at,options_json) VALUES(?,?,?,?,?)
            """, arguments: [draft.kind, draft.target, draft.targetRevision, now, draft.optionsJSON])
        return db.lastInsertedRowID
    }

    static func updateQueuedJobOptions(_ db: Database, id: Int64, optionsJSON: String) throws -> Bool {
        try validateJobOptions(optionsJSON)
        try db.execute(sql: """
            UPDATE ingest_jobs SET options_json=? WHERE id=? AND state='queued' AND attempts=0
            """, arguments: [optionsJSON, id])
        return db.changesCount == 1
    }

    /// The caller owns the write transaction and supplies a fresh token for every attempt.
    static func claimJob(_ db: Database, now: Int64, leaseToken: String, id: Int64?) throws -> IngestJob? {
        guard !leaseToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !leaseToken.contains("\0") else { throw StorageV19Error.invalidValue }
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM ingest_jobs WHERE lease_token=? LIMIT 1",
                               arguments: [leaseToken]) == nil else {
            throw StorageV19Error.invalidValue
        }
        let leaseUntil = try jobDeadline(now: now, delay: 300)
        _ = try recoverExpiredJobs(db, now: now)
        while let candidateId = try Int64.fetchOne(db, sql: """
            SELECT id FROM ingest_jobs
            WHERE state='queued' AND attempts<5 AND (next_retry_at IS NULL OR next_retry_at<=?)
              AND (? IS NULL OR id=?)
            ORDER BY next_retry_at,id LIMIT 1
            """, arguments: [now, id, id]) {
            guard let candidate = try job(db, id: candidateId) else { continue }
            do {
                try validateJobTarget(db, draft: candidate.draft)
            } catch StorageV19Error.notFound {
                // Target strings intentionally have no foreign key: deleted targets must not block the queue.
                try cancelJob(db, id: candidateId)
                continue
            }
            if try cancelStaleExtraction(db, job: candidate) { continue }
            try db.execute(sql: """
                UPDATE ingest_jobs SET state='running',attempts=attempts+1,next_retry_at=NULL,
                    lease_until=?,lease_token=?,error=NULL
                WHERE id=? AND state='queued' AND attempts<5 AND (next_retry_at IS NULL OR next_retry_at<=?)
                """, arguments: [leaseUntil, leaseToken, candidateId, now])
            guard db.changesCount == 1 else { continue }
            if candidate.draft.kind == "extract" {
                let sourceId = try jobTargetId(candidate.draft)
                try db.execute(sql: """
                    UPDATE sources SET status='chunking',error=NULL WHERE id=? AND current_revision IS ?
                    """, arguments: [sourceId, candidate.draft.targetRevision])
            }
            return try job(db, id: candidateId)
        }
        return nil
    }

    static func validateFence(_ db: Database, fence: JobFence, now: Int64) throws -> IngestJob? {
        try Row.fetchOne(db, sql: """
            SELECT * FROM ingest_jobs WHERE id=? AND state='running' AND lease_token=? AND lease_until>?
            """, arguments: [fence.jobId, fence.leaseToken, now]).map(decodeJob)
    }

    static func recoverExpiredJobs(_ db: Database, now: Int64) throws -> Int {
        let expired = try Row.fetchAll(db, sql: """
            SELECT * FROM ingest_jobs WHERE state='running' AND lease_until<=? ORDER BY id
            """, arguments: [now])
        for row in expired {
            let id: Int64 = row["id"]
            let attempts: Int = row["attempts"]
            // A lease expiry is a failed attempt (`ingestion-retry-cap-v1` §3).
            let exhausted = try RetryBudgetSQL.recordFailure(db, job: decodeJob(row))
            let retry = exhausted ? nil : try jobDeadline(now: now, delay: 30 * (Int64(1) << attempts))
            try db.execute(sql: """
                UPDATE ingest_jobs SET state=?,next_retry_at=?,lease_until=NULL,lease_token=NULL,error='leaseExpired'
                WHERE id=? AND state='running' AND lease_until<=?
                """, arguments: [exhausted ? "failed" : "queued", retry, id, now])
            if db.changesCount == 1 {
                // A retryable refresh stays pending; only exhaustion is a source error.
                try updateOwnedExtractionStatus(db, job: decodeJob(row),
                    status: exhausted ? "error" : "pending", error: exhausted ? "leaseExpired" : nil)
            }
        }
        return expired.count
    }

    static func renewJob(_ db: Database, fence: JobFence, now: Int64) throws -> Bool {
        guard try validateFence(db, fence: fence, now: now) != nil else { return false }
        try db.execute(sql: """
            UPDATE ingest_jobs SET lease_until=?
            WHERE id=? AND state='running' AND lease_token=? AND lease_until>?
            """, arguments: [try jobDeadline(now: now, delay: 300), fence.jobId, fence.leaseToken, now])
        return db.changesCount == 1
    }

    static func completeJob(_ db: Database, fence: JobFence, now: Int64, targetGenerationId: Int64? = nil) throws -> Bool {
        guard let owned = try validateFence(db, fence: fence, now: now) else { return false }
        guard owned.draft.kind != "extract" else { throw StorageV19Error.invalidValue }
        if let targetGenerationId {
            guard try retargetEmbedJob(db, fence: fence, generationId: targetGenerationId, now: now) else { return false }
        }
        try db.execute(sql: """
            UPDATE ingest_jobs SET state='done',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
            WHERE id=? AND state='running' AND lease_token=? AND lease_until>?
            """, arguments: [fence.jobId, fence.leaseToken, now])
        return db.changesCount == 1
    }

    /// A bootstrap job continues the same attempt after discovering its generation's dimensions.
    static func retargetEmbedJob(_ db: Database, fence: JobFence, generationId: Int64, now: Int64) throws -> Bool {
        guard let owned = try validateFence(db, fence: fence, now: now) else { return false }
        guard owned.draft.kind == "embed", owned.draft.target.hasPrefix("notebook:") else {
            throw StorageV19Error.invalidValue
        }
        let notebookId = try jobTargetId(owned.draft)
        let target = IngestJobDraft(kind: "embed", target: "generation:\(generationId)",
                                    targetRevision: owned.draft.targetRevision, optionsJSON: owned.draft.optionsJSON)
        try validateJobTarget(db, draft: target)
        guard try Int64.fetchOne(db, sql: "SELECT notebook_id FROM index_generations WHERE id=?", arguments: [generationId]) == notebookId else {
            throw StorageV19Error.notebookMismatch
        }
        try db.execute(sql: """
            UPDATE ingest_jobs SET target=?
            WHERE id=? AND state='running' AND lease_token=? AND lease_until>?
            """, arguments: [target.target, fence.jobId, fence.leaseToken, now])
        return db.changesCount == 1
    }

    static func failJob(_ db: Database, fence: JobFence, error: String, now: Int64) throws -> Bool {
        guard let owned = try validateFence(db, fence: fence, now: now) else { return false }
        let exhausted = try RetryBudgetSQL.recordFailure(db, job: owned)
        let retry = exhausted ? nil : try jobDeadline(now: now, delay: 30 * (Int64(1) << owned.attempts))
        try db.execute(sql: """
            UPDATE ingest_jobs SET state='failed',next_retry_at=?,error=?,lease_until=NULL,lease_token=NULL
            WHERE id=? AND state='running' AND lease_token=? AND lease_until>?
            """, arguments: [retry, error, fence.jobId, fence.leaseToken, now])
        guard db.changesCount == 1 else { return false }
        try updateOwnedExtractionStatus(db, job: owned, status: "error", error: error)
        return true
    }

    private static func updateOwnedExtractionStatus(_ db: Database, job: IngestJob, status: String, error: String?) throws {
        guard job.draft.kind == "extract" else { return }
        // A newer claimed job owns the source status even while it targets the same revision.
        try db.execute(sql: """
            UPDATE sources SET status=?,error=? WHERE id=? AND current_revision IS ?
                AND NOT EXISTS (SELECT 1 FROM ingest_jobs
                    WHERE kind='extract' AND target=? AND id>? AND attempts>0)
            """, arguments: [status, error, try jobTargetId(job.draft), job.draft.targetRevision,
                              job.draft.target, job.id])
    }

    static func retryJob(_ db: Database, id: Int64, now: Int64) throws -> Bool {
        guard let existing = try job(db, id: id), existing.state == "failed", existing.attempts < 5,
              let deadline = existing.nextRetryAt, deadline <= now else { return false }
        guard try !cancelStaleExtraction(db, job: existing) else { return false }
        try db.execute(sql: """
            UPDATE ingest_jobs SET state='queued'
            WHERE id=? AND state='failed' AND attempts<5 AND next_retry_at IS NOT NULL AND next_retry_at<=?
            """, arguments: [id, now])
        guard db.changesCount == 1 else { return false }
        if existing.draft.kind == "extract" {
            try db.execute(sql: """
                UPDATE sources SET status='pending',error=NULL WHERE id=? AND current_revision IS ?
                """, arguments: [try jobTargetId(existing.draft), existing.draft.targetRevision])
        }
        return true
    }

    static func requeueRetryableJobs(_ db: Database, now: Int64) throws -> Int {
        let ids = try Int64.fetchAll(db, sql: """
            SELECT id FROM ingest_jobs WHERE state='failed' AND attempts<5
                AND next_retry_at IS NOT NULL AND next_retry_at<=? ORDER BY id
            """, arguments: [now])
        var count = 0
        for id in ids where try retryJob(db, id: id, now: now) { count += 1 }
        return count
    }

    static func pauseJob(_ db: Database, id: Int64) throws {
        guard let existing = try job(db, id: id) else { throw StorageV19Error.notFound }
        guard existing.state == "queued" else { throw StorageV19Error.invalidValue }
        try db.execute(sql: "UPDATE ingest_jobs SET state='paused' WHERE id=? AND state='queued'", arguments: [id])
    }

    static func resumeJob(_ db: Database, id: Int64, now: Int64) throws {
        guard let existing = try job(db, id: id) else { throw StorageV19Error.notFound }
        guard existing.state == "paused" else { throw StorageV19Error.invalidValue }
        // The retry deadline survives a pause, even when resuming before it is due.
        try db.execute(sql: "UPDATE ingest_jobs SET state='queued' WHERE id=? AND state='paused'", arguments: [id])
    }

    static func cancelJob(_ db: Database, id: Int64) throws {
        guard let existing = try job(db, id: id) else { throw StorageV19Error.notFound }
        guard ["queued", "running", "paused"].contains(existing.state) else { throw StorageV19Error.invalidValue }
        try db.execute(sql: """
            UPDATE ingest_jobs SET state='cancelled',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
            WHERE id=? AND state IN ('queued','running','paused')
            """, arguments: [id])
    }

    static func cancelJob(_ db: Database, fence: JobFence, now: Int64) throws -> Bool {
        try db.execute(sql: """
            UPDATE ingest_jobs SET state='cancelled',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
            WHERE id=? AND state='running' AND lease_token=? AND lease_until>?
            """, arguments: [fence.jobId, fence.leaseToken, now])
        return db.changesCount == 1
    }

    private static func decodeJob(_ row: Row) -> IngestJob {
        IngestJob(id: row["id"], draft: IngestJobDraft(kind: row["kind"], target: row["target"], targetRevision: row["target_revision"], optionsJSON: row["options_json"]),
                  attempts: row["attempts"], nextRetryAt: row["next_retry_at"], state: row["state"],
                  leaseUntil: row["lease_until"], leaseToken: row["lease_token"], error: row["error"])
    }

    private static func jobDeadline(now: Int64, delay: Int64) throws -> Int64 {
        let (deadline, overflow) = now.addingReportingOverflow(delay)
        guard !overflow else { throw StorageV19Error.invalidValue }
        return deadline
    }

    private static func jobTargetId(_ draft: IngestJobDraft) throws -> Int64 {
        let prefix: String
        switch draft.kind {
        case "scan": prefix = "folder:"
        case "extract": prefix = "source:"
        case "embed": prefix = draft.target.hasPrefix("notebook:") ? "notebook:" : "generation:"
        case "gc": prefix = "generation:"
        default: throw StorageV19Error.invalidValue
        }
        guard draft.target.hasPrefix(prefix) else { throw StorageV19Error.invalidValue }
        let digits = draft.target.dropFirst(prefix.count)
        guard let first = digits.utf8.first, (49...57).contains(first),
              digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let id = Int64(digits), id > 0 else { throw StorageV19Error.invalidValue }
        return id
    }

    private static func validateJobTarget(_ db: Database, draft: IngestJobDraft) throws {
        let targetId = try jobTargetId(draft)
        let table: String
        switch draft.kind {
        case "scan": table = "folder_sources"
        case "extract": table = "sources"
        case "embed" where draft.target.hasPrefix("notebook:"): table = "notebooks"
        default: table = "index_generations"
        }
        // The table name is selected only from the fixed kind mapping above.
        let ownerColumn = table == "notebooks" ? "id" : "notebook_id"
        guard let notebookId = try Int64.fetchOne(db, sql: "SELECT \(ownerColumn) FROM \(table) WHERE id=?", arguments: [targetId]) else {
            throw StorageV19Error.notFound
        }
        if let revisionId = draft.targetRevision {
            guard let owner = try Row.fetchOne(db, sql: """
                SELECT r.source_id,s.notebook_id FROM source_revisions r JOIN sources s ON s.id=r.source_id WHERE r.id=?
                """, arguments: [revisionId]) else { throw StorageV19Error.notFound }
            let sourceId: Int64 = owner["source_id"]
            let revisionNotebook: Int64 = owner["notebook_id"]
            if draft.kind == "extract" {
                guard sourceId == targetId else { throw StorageV19Error.staleRevision }
            }
            guard revisionNotebook == notebookId else { throw StorageV19Error.notebookMismatch }
        }
    }

    private static func validateJobOptions(_ json: String) throws {
        guard let value = try? JSONSerialization.jsonObject(with: Data(json.utf8)), value is [String: Any] else {
            throw StorageV19Error.invalidValue
        }
    }

    /// Checked inside the claim/retry transaction before changing either the job or source status.
    private static func cancelStaleExtraction(_ db: Database, job: IngestJob) throws -> Bool {
        guard job.draft.kind == "extract" else { return false }
        let matches = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM sources WHERE id=? AND current_revision IS ?
                AND NOT EXISTS (SELECT 1 FROM ingest_jobs
                    WHERE kind='extract' AND target=? AND id>? AND attempts>0))
            """, arguments: [try jobTargetId(job.draft), job.draft.targetRevision,
                              job.draft.target, job.id])!
        guard !matches else { return false }
        try db.execute(sql: """
            UPDATE ingest_jobs SET state='cancelled',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
            WHERE id=? AND state IN ('queued','failed')
            """, arguments: [job.id])
        return true
    }
}

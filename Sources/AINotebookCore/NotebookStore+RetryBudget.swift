import Foundation
import GRDB

/// The extraction failure budget (contract `ingestion-retry-cap-v1`, same values
/// as Windows `ExtractionRetryBudget`). A source — folder member or loose — whose
/// extraction failed `failures` times for the same content is given up: it stays
/// `error`, scans treat it as settled and nothing re-queues it until the content
/// changes or the user explicitly retries.
public enum ExtractionRetryBudget {
    /// Failed attempts per source and content (counted across jobs).
    public static let failures = 3
    /// Attempts of one extract job (folder or loose source). Scan, embed and gc
    /// jobs keep five; the frozen job fixtures that pinned five for extract jobs
    /// are superseded by `ingestion-retry-cap-v1` (§1a).
    public static let extractMaxAttempts = 3
    /// Attempts of every other job (frozen `folder-rag-v1` value).
    static let otherMaxAttempts = 5
    /// Error code of a loose source whose queued retry has nothing to re-read
    /// (no local file and no URL, e.g. pasted text).
    public static let retryUnavailable = "retryUnavailable"
    /// Single switch for automatic (background) re-fetches of a failed loose web
    /// source (§3a). Off (user decision 2026-10-11): only an explicit user action
    /// fetches — a failed URL attempt is never retried automatically (its job ends
    /// terminally, the failure still counts), and the worker fetches a URL only
    /// for the first attempt of a job queued by an explicit Retry
    /// (`userRetryKey`). Same value as Windows.
    public static let backgroundWebRetry = false
    /// `ingest_jobs.options_json` key marking an extract job queued by an explicit
    /// user retry (`retryFailedExtraction(s)`).
    public static let userRetryKey = "userRetry"
}

extension NotebookStore {
    /// Explicit user retry of one failed source: resets its failure budget and
    /// queues extraction. Returns false (changing nothing) unless the source is a
    /// present, eligible source with status `error` that can be re-read: a folder
    /// member, or a loose source with a local file or a URL (§5).
    @discardableResult
    public func retryFailedExtraction(sourceId: Int64, now: Int64) throws -> Bool {
        let notebookId = try dbQueue.write { db -> Int64? in
            guard let notebook = try RetryBudgetSQL.retryable(db, sourceId: sourceId) else { return nil }
            // A loose source is extracted by the folder worker from its file or URL (§3a).
            try RetryBudgetSQL.retry(db, sourceId: sourceId, now: now)
            return notebook
        }
        guard let notebookId else { return false }
        notifyFolderIngestionChanged(notebookId: notebookId)
        return true
    }

    /// "Retry all failed": `retryFailedExtraction` for every retryable failed source
    /// (folder and loose) of the notebook in ascending id. Returns the number of
    /// retried sources.
    @discardableResult
    public func retryFailedExtractions(notebookId: Int64, now: Int64) throws -> Int {
        let count = try dbQueue.write { db -> Int in
            let ids = try Int64.fetchAll(db, sql: """
                SELECT id FROM sources WHERE notebook_id=? AND \(RetryBudgetSQL.retryablePredicate) ORDER BY id
                """, arguments: [notebookId])
            for id in ids { try RetryBudgetSQL.retry(db, sourceId: id, now: now) }
            return ids.count
        }
        if count > 0 { notifyFolderIngestionChanged(notebookId: notebookId) }
        return count
    }

    /// The loose (non-folder) source a queued extract job re-reads, or nil for a
    /// folder member or a missing source (§3a).
    func looseExtractionTarget(sourceId: Int64) throws -> LooseExtractionTarget? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT notebook_id,type,raw_path,uri FROM sources WHERE id=? AND folder_id IS NULL
                """, arguments: [sourceId]) else { return nil }
            let type = SourceType(rawValue: row["type"]) ?? .text
            let raw: String? = row["raw_path"], uri: String? = row["uri"]
            return LooseExtractionTarget(sourceId: sourceId, notebookId: row["notebook_id"], kind: type,
                                         file: type == .web || type == .note ? nil : raw.map { URL(fileURLWithPath: $0) },
                                         url: type == .web ? uri.flatMap(URL.init(string:)) : nil)
        }
    }

    /// A loose source's queued retry has nothing to re-read: the owned job ends
    /// terminally (no attempt is counted) and an owned source becomes `error`
    /// `retryUnavailable` instead of staying `chunking` (§3a).
    @discardableResult
    func abandonLooseExtraction(fence: JobFence, now: Int64) throws -> Bool {
        let notebookId = try dbQueue.write { db -> Int64? in
            guard let job = try RevisionJobSQL.validateFence(db, fence: fence, now: now), job.draft.kind == "extract",
                  let sourceId = Int64(job.draft.target.dropFirst("source:".count)) else { return nil }
            let code = ExtractionRetryBudget.retryUnavailable
            try db.execute(sql: """
                UPDATE ingest_jobs SET state='failed',next_retry_at=NULL,error=?,lease_until=NULL,lease_token=NULL
                WHERE id=? AND state='running' AND lease_token=? AND lease_until>?
                """, arguments: [code, fence.jobId, fence.leaseToken, now])
            guard db.changesCount == 1 else { return nil }
            try db.execute(sql: """
                UPDATE sources SET status='error',error=? WHERE id=? AND current_revision IS ?
                    AND NOT EXISTS (SELECT 1 FROM ingest_jobs WHERE kind='extract' AND target=? AND id>? AND attempts>0)
                """, arguments: [code, sourceId, job.draft.targetRevision, job.draft.target, job.id])
            return try RevisionJobSQL.notebookId(db, draft: job.draft)
        }
        guard let notebookId else { return false }
        notifyFolderIngestionChanged(notebookId: notebookId)
        return true
    }

    /// Ids of the notebook's sources whose extraction was given up.
    public func gaveUpSourceIds(notebookId: Int64) throws -> Set<Int64> {
        try dbQueue.read { db in
            Set(try Int64.fetchAll(db, sql: """
                SELECT id FROM sources WHERE notebook_id=? AND \(RetryBudgetSQL.gaveUpPredicate)
                """, arguments: [notebookId]))
        }
    }
}

/// What the folder worker re-reads for a loose source: its local file, or its URL (web sources).
struct LooseExtractionTarget: Sendable, Equatable {
    let sourceId: Int64
    let notebookId: Int64
    let kind: SourceType
    let file: URL?
    let url: URL?
}

enum RetryBudgetSQL {
    /// The recorded failures of the source whose id is the SQL expression `id` (0 without a budget row).
    static func failures(_ id: String) -> String {
        "coalesce((SELECT b.failures FROM source_extract_budget b WHERE b.source_id=\(id)),0)"
    }
    /// A source (unqualified `sources` columns) whose extraction was given up: status `error`, budget spent.
    static let gaveUpPredicate = "(status='error' AND \(failures("sources.id"))>=\(ExtractionRetryBudget.failures))"
    /// A failed source the user may retry: a folder member, or a loose source the
    /// folder worker can re-read (a local file or a URL; never a note).
    static let retryablePredicate = """
        status='error' AND availability='present' AND eligible=1 AND type<>'note'
          AND (folder_id IS NOT NULL OR raw_path IS NOT NULL OR uri IS NOT NULL)
        """

    static func retryable(_ db: Database, sourceId: Int64) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT notebook_id FROM sources WHERE id=? AND \(retryablePredicate)",
                           arguments: [sourceId])
    }

    /// An explicit retry: a given-up budget starts over, otherwise the attempt simply
    /// counts; the queued job is marked as user-initiated (§5).
    static func retry(_ db: Database, sourceId: Int64, now: Int64) throws {
        try resetIfGaveUp(db, sourceId: sourceId)
        try FolderIngestionSQL.requireExtraction(db, sourceId: sourceId, keepRunning: true, now: now)
        try db.execute(sql: """
            UPDATE ingest_jobs SET options_json=json_set(options_json,'$.\(ExtractionRetryBudget.userRetryKey)',json('true'))
            WHERE kind='extract' AND target=? AND state='queued' AND attempts=0
            """, arguments: ["source:\(sourceId)"])
    }

    /// An explicit user action on unchanged content: a spent budget starts over;
    /// a budget with attempts left keeps counting (§5).
    static func resetIfGaveUp(_ db: Database, sourceId: Int64) throws {
        guard try exhausted(db, sourceId: sourceId) else { return }
        try reset(db, sourceId: sourceId)
    }

    /// Whether `job` was queued by an explicit user retry and this is its first attempt.
    static func userInitiated(_ job: IngestJob) -> Bool {
        guard job.attempts == 1, let data = job.draft.optionsJSON.data(using: .utf8),
              let options = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (options[ExtractionRetryBudget.userRetryKey] as? Bool) == true
    }

    /// Clears the failure count; the recorded content hash stays (same content).
    static func reset(_ db: Database, sourceId: Int64) throws {
        try db.execute(sql: "UPDATE source_extract_budget SET failures=0 WHERE source_id=?", arguments: [sourceId])
    }

    /// Forgets the budget: the source is settled (`ready`).
    static func clear(_ db: Database, sourceId: Int64) throws {
        try db.execute(sql: "DELETE FROM source_extract_budget WHERE source_id=?", arguments: [sourceId])
    }

    static func exhausted(_ db: Database, sourceId: Int64) throws -> Bool {
        (try Int.fetchOne(db, sql: "SELECT failures FROM source_extract_budget WHERE source_id=?",
                          arguments: [sourceId]) ?? 0) >= ExtractionRetryBudget.failures
    }

    /// A scan observed the file: a different content resets the budget (§4).
    /// `hash` is nil when the scanner did not read the file; `sameStamp` compares
    /// the observed mtime/size with the stored ones.
    static func observe(_ db: Database, sourceId: Int64, hash: String?, sameStamp: Bool) throws {
        let stored = try Row.fetchOne(db, sql: "SELECT content_hash FROM source_extract_budget WHERE source_id=?",
                                      arguments: [sourceId])?["content_hash"] as String?
        if let hash {
            if let stored, stored.utf8.elementsEqual(hash.utf8) { return }
            // Unknown content with an unchanged stamp is the same content: adopt the hash.
            let keep = stored == nil && sameStamp
            try db.execute(sql: """
                INSERT INTO source_extract_budget(source_id,failures,content_hash) VALUES(?,0,?)
                ON CONFLICT(source_id) DO UPDATE SET content_hash=excluded.content_hash,
                    failures=CASE WHEN ? THEN failures ELSE 0 END
                """, arguments: [sourceId, hash, keep])
        } else if !sameStamp {
            try clear(db, sourceId: sourceId)
        }
    }

    /// Records one failed attempt of `job` against its folder source when the job
    /// still owns the source status, and returns whether the job is exhausted:
    /// its own attempt cap, or the source budget spent (§3).
    static func recordFailure(_ db: Database, job: IngestJob) throws -> Bool {
        guard job.draft.kind == "extract", let sourceId = Int64(job.draft.target.dropFirst("source:".count)) else {
            return job.attempts >= ExtractionRetryBudget.otherMaxAttempts
        }
        try db.execute(sql: """
            INSERT INTO source_extract_budget(source_id,failures)
            SELECT id,1 FROM sources WHERE id=? AND current_revision IS ? AND type<>'note'
              AND NOT EXISTS (SELECT 1 FROM ingest_jobs WHERE kind='extract' AND target=? AND id>? AND attempts>0)
            ON CONFLICT(source_id) DO UPDATE SET failures=failures+1
            """, arguments: [sourceId, job.draft.targetRevision, job.draft.target, job.id])
        let spent = db.changesCount == 1 ? try exhausted(db, sourceId: sourceId) : false
        // Without background web retries a loose URL's failed attempt is final: only the user fetches again.
        let isLooseWeb = try Bool.fetchOne(db, sql: "SELECT folder_id IS NULL AND type='web' FROM sources WHERE id=?",
                                           arguments: [sourceId]) ?? false
        let looseWeb = !ExtractionRetryBudget.backgroundWebRetry && isLooseWeb
        return spent || looseWeb || job.attempts >= ExtractionRetryBudget.extractMaxAttempts
    }
}

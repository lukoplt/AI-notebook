import Foundation
import GRDB

extension NotebookStore {
    /// Requeues extraction, once per `ExtractorRevision.current`, for every
    /// present, eligible folder source whose extraction failed with a
    /// retryable code and has no unfinished extract job and no extract job
    /// stamped with the current (or a newer) revision. Each new job carries
    /// `{"extractorRevision": current}` so a failure under this revision is
    /// never requeued again. Posts `folderIngestionDidChange` (and thereby
    /// `indexingStatusDidChange`) once per affected notebook. Returns the
    /// number of requeued sources. Contract `ingestion-reextract-v1`.
    @discardableResult
    public func requeueUpgradedExtractions(now: Int64) throws -> Int {
        let notebooks = try dbQueue.write { db -> [Int64] in
            let codes = String(decoding: try JSONEncoder().encode(ExtractorRevision.retryableCodes), as: UTF8.self)
            let rows = try Row.fetchAll(db, sql: ReextractSQL.candidates,
                                        arguments: [codes, ExtractorRevision.optionsKey, ExtractorRevision.optionsKey,
                                                    ExtractorRevision.current])
            var notebooks: [Int64] = []
            for row in rows {
                let sourceId: Int64 = row["id"]
                _ = try FolderIngestionSQL.enqueueDue(db, draft: IngestJobDraft(kind: "extract", target: "source:\(sourceId)",
                    targetRevision: row["current_revision"], optionsJSON: ExtractorRevision.optionsJSON), now: now)
                try db.execute(sql: "UPDATE sources SET status='pending',error=NULL WHERE id=?", arguments: [sourceId])
                notebooks.append(row["notebook_id"])
            }
            return notebooks
        }
        for notebook in Set(notebooks).sorted() { notifyFolderIngestionChanged(notebookId: notebook) }
        return notebooks.count
    }
}

extension NotebookStore {
    /// Throttled re-extraction of ready folder spreadsheets whose published
    /// revision predates the current spreadsheet canonical text
    /// (`text_format_version < ExtractorRevision.spreadsheetTextVersion`). Tops
    /// the unfinished upgrade jobs up to `spreadsheetBatchSize`, in ascending
    /// source id; each job carries `{"spreadsheetTextVersion": 2}`. The source
    /// stays `ready` and its published revision stays searchable until the new
    /// revision is published. Runs at runtime start, on every periodic
    /// reconciliation and after each finished upgrade job, so the batch refills
    /// as extraction drains. Posts `folderIngestionDidChange` once per affected
    /// notebook. Returns the number of requeued sources.
    /// Contract `ingestion-reextract-v1` §7 (fixture `ingestion-reextract-v2`).
    @discardableResult
    public func requeueSpreadsheetUpgrades(now: Int64) throws -> Int {
        let notebooks = try dbQueue.write { db -> [Int64] in
            let key = ExtractorRevision.spreadsheetOptionsKey, version = ExtractorRevision.spreadsheetTextVersion
            let outstanding = try Int.fetchOne(db, sql: ReextractSQL.outstandingSpreadsheetUpgrades,
                                               arguments: [key, key, version]) ?? 0
            let room = ExtractorRevision.spreadsheetBatchSize - outstanding
            guard room > 0 else { return [] }
            let rows = try Row.fetchAll(db, sql: ReextractSQL.spreadsheetCandidates,
                                        arguments: [SourceType.xlsx.rawValue, version, key, key, version, room])
            var notebooks: [Int64] = []
            for row in rows {
                let sourceId: Int64 = row["id"]
                _ = try FolderIngestionSQL.enqueueDue(db, draft: IngestJobDraft(kind: "extract", target: "source:\(sourceId)",
                    targetRevision: row["current_revision"], optionsJSON: ExtractorRevision.spreadsheetOptionsJSON), now: now)
                notebooks.append(row["notebook_id"])
            }
            return notebooks
        }
        for notebook in Set(notebooks).sorted() { notifyFolderIngestionChanged(notebookId: notebook) }
        return notebooks.count
    }
}

enum ReextractSQL {
    /// A job's spreadsheet stamp: its integer `spreadsheetTextVersion` option, else 0. Arguments: key, key.
    private static let spreadsheetStamp = """
        (CASE WHEN json_valid(j.options_json) THEN
             (CASE WHEN json_type(j.options_json,'$.'||?)='integer'
                   THEN json_extract(j.options_json,'$.'||?) ELSE 0 END)
         ELSE 0 END)
        """

    /// Arguments: key, key, version.
    static let outstandingSpreadsheetUpgrades = """
        SELECT count(*) FROM ingest_jobs j WHERE j.kind='extract'
          AND (j.state IN ('queued','running','paused') OR (j.state='failed' AND j.attempts<5 AND j.next_retry_at IS NOT NULL))
          AND \(spreadsheetStamp)>=?
        """

    /// Arguments: type, version, key, key, version, limit.
    static let spreadsheetCandidates = """
        SELECT s.id,s.notebook_id,s.current_revision FROM sources s
        JOIN source_revisions r ON r.id=s.published_revision_id
        WHERE s.folder_id IS NOT NULL AND s.type=? AND s.status='ready' AND s.availability='present' AND s.eligible=1
          AND s.current_revision=s.published_revision_id AND r.text_format_version<?
          AND NOT EXISTS(SELECT 1 FROM ingest_jobs j WHERE j.kind='extract' AND j.target='source:'||s.id
              AND (j.state IN ('queued','running','paused')
                   OR (j.state='failed' AND j.attempts<5 AND j.next_retry_at IS NOT NULL)))
          AND NOT EXISTS(SELECT 1 FROM ingest_jobs j WHERE j.kind='extract' AND j.target='source:'||s.id
              AND j.state='failed' AND \(spreadsheetStamp)>=?)
        ORDER BY s.id LIMIT ?
        """

    /// Arguments: retryable codes (JSON array), options key twice, current revision.
    /// A job's revision is its integer `extractorRevision` option, else 1.
    static let candidates = """
        SELECT s.id,s.notebook_id,s.current_revision FROM sources s
        WHERE s.folder_id IS NOT NULL AND s.status='error' AND s.availability='present' AND s.eligible=1
          AND \(RetryBudgetSQL.failures("s.id"))<\(ExtractionRetryBudget.failures)
          AND s.error IN (SELECT value FROM json_each(?))
          AND NOT EXISTS(SELECT 1 FROM ingest_jobs j WHERE j.kind='extract' AND j.target='source:'||s.id
              AND (j.state IN ('queued','running','paused')
                   OR (j.state='failed' AND j.attempts<5 AND j.next_retry_at IS NOT NULL)))
          AND NOT EXISTS(SELECT 1 FROM ingest_jobs j WHERE j.kind='extract' AND j.target='source:'||s.id
              AND (CASE WHEN json_valid(j.options_json) THEN
                        (CASE WHEN json_type(j.options_json,'$.'||?)='integer'
                              THEN json_extract(j.options_json,'$.'||?) ELSE 1 END)
                   ELSE 1 END)>=?)
        ORDER BY s.id
        """
}

import Foundation
import GRDB

extension NotebookStore {
    /// One read batch of the notebook's indexing inputs (contract `indexing-status-v1` §1).
    /// `availability` and `runtimeError` are runtime facts supplied by the caller.
    public func indexingInputs(notebookId: Int64, now: Int64, availability: EmbeddingAvailability = .ready,
                               runtimeError: String? = nil) throws -> IndexingInputs {
        try dbQueue.read { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM notebooks WHERE id=?", arguments: [notebookId]) != nil else {
                throw StorageV19Error.notFound
            }
            let folders = try Row.fetchAll(db, sql: """
                SELECT id,scan_state,last_scan_error,scan_generation FROM folder_sources WHERE notebook_id=? ORDER BY id
                """, arguments: [notebookId]).map { row -> IndexingFolderInput in
                    let id: Int64 = row["id"], state: String = row["scan_state"], generation: Int64 = row["scan_generation"]
                    let seen = state == "scanning" ? try Int.fetchOne(db, sql: """
                        SELECT count(*) FROM scan_items WHERE folder_id=? AND seen_generation=?
                        """, arguments: [id, generation]) : nil
                    return IndexingFolderInput(folderId: id, scanState: state, lastScanError: row["last_scan_error"], filesSeen: seen)
                }
            let scans = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM ingest_jobs WHERE kind='scan' AND state IN ('queued','running')
                  AND target IN (SELECT 'folder:'||id FROM folder_sources WHERE notebook_id=?)
                """, arguments: [notebookId]) ?? 0
            var extract: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT state,count(*) AS n FROM ingest_jobs WHERE kind='extract' AND state IN ('queued','running')
                  AND target IN (SELECT 'source:'||id FROM sources WHERE notebook_id=?) GROUP BY state
                """, arguments: [notebookId]) { extract[row["state"]] = row["n"] }
            var sources: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT status,count(*) AS n FROM sources WHERE notebook_id=? AND availability='present' AND eligible=1 GROUP BY status
                """, arguments: [notebookId]) { sources[row["status"]] = row["n"] }
            // Addendum §8: a running/unfinished job wins; a bootstrap of a building space reports that build.
            let selected = try IndexingStatusSQL.statusJob(db, notebookId: notebookId)
            var done = 0, total = 0
            if let generationId = selected?.progressGenerationId {
                (done, total) = try IndexingStatusSQL.chunkProgress(db, generationId: generationId)
            }
            let embedJob = selected.map {
                IndexingEmbedJobInput(state: $0.job.state, attempts: $0.job.attempts, nextRetryAt: $0.job.nextRetryAt,
                                      errorCode: $0.job.error, bootstrap: $0.bootstrap)
            }
            return IndexingInputs(now: now, runtimeError: runtimeError, embeddingAvailability: availability, folders: folders,
                                  scanJobsPending: scans, extractQueued: extract["queued"] ?? 0,
                                  extractRunning: extract["running"] ?? 0, sourcesTotal: sources.values.reduce(0, +),
                                  sourcesReady: sources[SourceStatus.ready.rawValue] ?? 0,
                                  sourcesError: sources[SourceStatus.error.rawValue] ?? 0,
                                  needsEmbedding: try IndexingStatusSQL.needsEmbedding(db, notebookId: notebookId),
                                  embedJob: embedJob, embedChunksDone: done, embedChunksTotal: total)
        }
    }

    /// Reads the inputs and derives the notebook's status (pure function, contract §2).
    public func indexingStatus(notebookId: Int64, now: Int64, availability: EmbeddingAvailability = .ready,
                               runtimeError: String? = nil) throws -> IndexingStatus {
        IndexingStatus.derive(try indexingInputs(notebookId: notebookId, now: now, availability: availability,
                                                 runtimeError: runtimeError))
    }

    /// An embed/bootstrap job of the notebook is queued, running, paused, or failed with an automatic retry pending.
    public func hasUnfinishedEmbedJob(notebookId: Int64) throws -> Bool {
        try dbQueue.read { try IndexingStatusSQL.hasUnfinishedEmbedJob($0, notebookId: notebookId) }
    }

    /// "Retry now": the notebook's embed job waiting for its retry deadline becomes due immediately.
    /// Returns false when no job was waiting.
    @discardableResult
    public func expediteEmbedRetry(notebookId: Int64, now: Int64) throws -> Bool {
        let changed = try dbQueue.write { db -> Bool in
            let ids = try IndexingStatusSQL.embedJobIds(db, notebookId: notebookId)
            guard !ids.isEmpty else { return false }
            let list = ids.map { _ in "?" }.joined(separator: ",")
            try db.execute(sql: """
                UPDATE ingest_jobs SET state='queued',next_retry_at=NULL
                WHERE id IN (\(list)) AND state='failed' AND attempts<5 AND next_retry_at IS NOT NULL
                """, arguments: StatementArguments(ids))
            var count = db.changesCount
            try db.execute(sql: """
                UPDATE ingest_jobs SET next_retry_at=NULL
                WHERE id IN (\(list)) AND state='queued' AND next_retry_at IS NOT NULL AND next_retry_at>?
                """, arguments: StatementArguments(ids) + [now])
            count += db.changesCount
            return count > 0
        }
        if changed { notifyFolderIngestionChanged(notebookId: notebookId) }
        return changed
    }

    /// Highest job id so far (0 when none): the baseline of a scan outcome.
    func maxIngestJobId() throws -> Int64 {
        try dbQueue.read { try Int64.fetchOne($0, sql: "SELECT coalesce(max(id),0) FROM ingest_jobs") ?? 0 }
    }

    /// The folder's last scan: extract jobs queued for its sources after `sinceJobId`
    /// and eligible files seen in its current scan generation.
    func folderScanOutcome(folderId: Int64, sinceJobId: Int64, now: Int64) throws -> FolderScanOutcome {
        try dbQueue.read { db in
            let folder = try FolderIngestionSQL.folder(db, id: folderId)
            let changed = try Int.fetchOne(db, sql: """
                SELECT count(DISTINCT target) FROM ingest_jobs WHERE kind='extract' AND id>?
                  AND target IN (SELECT 'source:'||id FROM sources WHERE folder_id=?)
                """, arguments: [sinceJobId, folderId]) ?? 0
            let seen = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM scan_items WHERE folder_id=? AND seen_generation=? AND kind='eligible'
                """, arguments: [folderId, folder.scanGeneration]) ?? 0
            return FolderScanOutcome(folderId: folderId, changedFiles: changed, filesSeen: seen, finishedAt: now)
        }
    }

    func notifyIndexingStatusChanged(notebookIds: Set<Int64>) {
        for notebookId in notebookIds.sorted() { notifyIndexingStatusChanged(notebookId: notebookId) }
    }
}

enum IndexingStatusSQL {
    /// The embed job behind the status and its progress generation (`indexing-status-v1` §8).
    /// Reads only the unfinished jobs plus the newest one: the selection is the same.
    static func statusJob(_ db: Database, notebookId: Int64) throws -> EmbedJobPlanning.StatusJob? {
        let jobs = try Row.fetchAll(db, sql: """
            SELECT id,target,state,attempts,next_retry_at,error,options_json FROM ingest_jobs
            WHERE kind='embed' AND (target=:target OR target IN
                (SELECT 'generation:'||id FROM index_generations WHERE notebook_id=:notebookId))
              AND (state IN ('queued','running','paused') OR (state='failed' AND attempts<5 AND next_retry_at IS NOT NULL)
                OR id=(SELECT max(id) FROM ingest_jobs WHERE kind='embed' AND (target=:target OR target IN
                    (SELECT 'generation:'||id FROM index_generations WHERE notebook_id=:notebookId))))
            ORDER BY id
            """, arguments: ["target": "notebook:\(notebookId)", "notebookId": notebookId]).map(embedJobSnapshot)
        guard !jobs.isEmpty else { return nil }
        return EmbedJobPlanning.statusJob(jobs: jobs, generations: try generationSnapshots(db, notebookId: notebookId))
    }

    static func embedJobSnapshot(_ row: Row) -> EmbedJobSnapshot {
        EmbedJobSnapshot(id: row["id"], target: row["target"], state: row["state"], attempts: row["attempts"],
                         nextRetryAt: row["next_retry_at"], error: row["error"], options: EmbedJobOptions(json: row["options_json"]))
    }

    /// The notebook's building and active generations.
    static func generationSnapshots(_ db: Database, notebookId: Int64) throws -> [GenerationSnapshot] {
        try Int64.fetchAll(db, sql: """
            SELECT id FROM index_generations WHERE notebook_id=? AND state IN ('building','active') ORDER BY id
            """, arguments: [notebookId]).compactMap { try GenerationSQL.generation(db, id: $0) }
            .map { GenerationSnapshot(id: $0.id, state: $0.state, identity: $0.identity) }
    }

    static func embedJobIds(_ db: Database, notebookId: Int64) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT id FROM ingest_jobs WHERE kind='embed' AND (target=? OR target IN
                (SELECT 'generation:'||id FROM index_generations WHERE notebook_id=?)) ORDER BY id
            """, arguments: ["notebook:\(notebookId)", notebookId])
    }

    static func hasUnfinishedEmbedJob(_ db: Database, notebookId: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM ingest_jobs WHERE kind='embed' AND (target=? OR target IN
                (SELECT 'generation:'||id FROM index_generations WHERE notebook_id=?))
              AND (state IN ('queued','running','paused') OR (state='failed' AND attempts<5 AND next_retry_at IS NOT NULL)))
            """, arguments: ["notebook:\(notebookId)", notebookId]) == true
    }

    /// Embeddable chunks (`embedding-plan-v1` §3) of the generation's non-excluded manifest
    /// revisions, and how many already have a vector there.
    static func chunkProgress(_ db: Database, generationId: Int64) throws -> (done: Int, total: Int) {
        let row = try Row.fetchOne(db, sql: chunkProgressSQL, arguments: [generationId])
        return (row?["done"] ?? 0, row?["total"] ?? 0)
    }

    /// Read every second while indexing runs: chunks are reached only through the
    /// covering `idx_chunks_revision_ord` (a revision's chunks always belong to the
    /// manifest source, so no chunk row has to be read to check `source_id`; the
    /// spreadsheet cap compares `ord`, which the index carries).
    static let chunkProgressSQL = """
        SELECT count(*) AS total, coalesce(sum(EXISTS(SELECT 1 FROM chunk_embeddings e
            WHERE e.chunk_id=c.id AND e.generation_id=m.generation_id)),0) AS done
        FROM index_generation_manifest m JOIN sources s ON s.id=m.source_id
        JOIN source_chunks c ON c.revision_id=m.revision_id
        WHERE m.generation_id=? AND m.state<>'excluded' AND \(EmbeddingPlan.embeddableSQL())
        """

    /// True when an eligible published revision with chunks is not yet done in the active generation.
    static func needsEmbedding(_ db: Database, notebookId: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM sources s WHERE s.notebook_id=? AND s.availability='present' AND s.eligible=1
                AND s.published_revision_id IS NOT NULL
                AND EXISTS(SELECT 1 FROM source_chunks c WHERE c.revision_id=s.published_revision_id)
                AND NOT EXISTS(SELECT 1 FROM index_generations g JOIN index_generation_manifest m ON m.generation_id=g.id
                    WHERE g.notebook_id=s.notebook_id AND g.state='active' AND m.source_id=s.id
                      AND m.revision_id=s.published_revision_id AND m.state='done'))
            """, arguments: [notebookId]) == true
    }
}

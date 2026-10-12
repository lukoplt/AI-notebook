import Foundation
import GRDB

public extension Notification.Name {
    /// Posted on the main actor after a committed folder-ingestion mutation.
    /// `userInfo["notebookId"]` is the affected notebook (Int64). Rejected fences
    /// and rollbacks post nothing. This is a cache hint, never a correctness fence.
    static let folderIngestionDidChange = Notification.Name("AINotebook.folderIngestionDidChange")
    /// Posted on the main actor whenever a notebook's `IndexingStatus` may have
    /// changed: after every `folderIngestionDidChange`, and additionally after
    /// job lifecycle changes (claim, fenced failure, lease recovery, retry
    /// requeue, cancellation, completion) and runtime start/scan outcomes, and
    /// for committed background embedding batches (coalesced: at most one per
    /// second per notebook, plus one trailing post).
    /// `userInfo["notebookId"]` is the notebook (Int64). Observe this one for
    /// live indexing progress.
    static let indexingStatusDidChange = Notification.Name("AINotebook.indexingStatusDidChange")
}

/// Leading-edge throttle with one trailing post per notebook (main actor only).
@MainActor
final class IndexingProgressThrottle {
    var interval: TimeInterval = 1
    private var lastPost: [Int64: ContinuousClock.Instant] = [:]
    private var trailing: Set<Int64> = []

    func signal(_ notebookId: Int64, post: @escaping @MainActor (Int64) -> Void) {
        let now = ContinuousClock.now
        let window = Duration.milliseconds(Int64((interval * 1000).rounded()))
        guard let last = lastPost[notebookId], now - last < window else {
            lastPost[notebookId] = now
            post(notebookId)
            return
        }
        guard trailing.insert(notebookId).inserted else { return }
        let delay = window - (now - last)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.trailing.remove(notebookId)
            self.lastPost[notebookId] = ContinuousClock.now
            post(notebookId)
        }
    }
}

/// One stored row considered by a rule change: a folder source or a source-less inventory item.
struct FolderRuleRow: Sendable, Equatable {
    let relPath: String
    let sizeBytes: Int64?
}

extension NotebookStore {
    /// Runs `body` on the main actor: synchronously when already on the main
    /// thread (tests and UI callers keep their ordering), otherwise enqueued.
    /// Store methods called from background workers post their change
    /// notifications through this, so observers always run on the main thread.
    func onMain(_ body: @escaping @MainActor @Sendable (NotebookStore) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(self) }
        } else {
            Task { @MainActor in body(self) }
        }
    }

    func notifyFolderIngestionChanged(notebookId: Int64) {
        onMain { store in
            NotificationCenter.default.post(name: .folderIngestionDidChange, object: store,
                                            userInfo: ["notebookId": notebookId])
            store.notifyIndexingStatusChanged(notebookId: notebookId)
        }
    }

    /// Status-only signal: job lifecycle changes that are not catalog mutations.
    func notifyIndexingStatusChanged(notebookId: Int64) {
        onMain { store in
            NotificationCenter.default.post(name: .indexingStatusDidChange, object: store,
                                            userInfo: ["notebookId": notebookId])
        }
    }

    /// Committed background batches are indexing progress, not catalog changes:
    /// a status-only signal at most once per `indexingProgressInterval` per
    /// notebook (leading edge plus one trailing post, so the last batch is never
    /// lost). Observers reload on the main actor, which also runs the store, so
    /// per-batch posts would throttle a fast build.
    func notifyIndexingProgress(notebookId: Int64) {
        onMain { store in
            store.indexingProgress.signal(notebookId) { [weak store] in store?.notifyIndexingStatusChanged(notebookId: $0) }
        }
    }

    /// Minimum seconds between two batch-progress signals of one notebook.
    @MainActor var indexingProgressInterval: TimeInterval {
        get { indexingProgress.interval }
        set { indexingProgress.interval = newValue }
    }

    func folderSource(id: Int64) throws -> FolderSource {
        try dbQueue.read { try FolderIngestionSQL.folder($0, id: id) }
    }

    func folderKnownSource(folderId: Int64, relPath: String) throws -> FolderKnownSource? {
        try dbQueue.read { try FolderIngestionSQL.known($0, folderId: folderId, relPath: relPath) }
    }

    func folderRuleRows(folderId: Int64) throws -> [FolderRuleRow] {
        try dbQueue.read { db in
            _ = try FolderIngestionSQL.folder(db, id: folderId)
            return try FolderIngestionSQL.ruleRows(db, folderId: folderId).map { FolderRuleRow(relPath: $0.relPath, sizeBytes: $0.sizeBytes) }
        }
    }

    /// Starts a new scan generation for the job that owns `fence`. Returns nil for
    /// a stale/expired fence, a non-scan job, or a different live scan owner.
    public func beginFolderScan(folderId: Int64, fence: JobFence, now: Int64) throws -> ScanTicket? {
        let begun = try dbQueue.write { db -> (ScanTicket, Int64)? in
            guard let job = try RevisionJobSQL.validateFence(db, fence: fence, now: now),
                  job.draft.kind == "scan", job.draft.target == "folder:\(folderId)" else { return nil }
            guard let row = try Row.fetchOne(db, sql: "SELECT notebook_id,scan_generation FROM folder_sources WHERE id=?",
                                             arguments: [folderId]) else { throw StorageV19Error.notFound }
            // An abandoned scanning row restarts only once the old owner's lease is gone.
            let competing = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM ingest_jobs WHERE kind='scan' AND target=? AND state='running'
                    AND id<>? AND lease_until>?)
                """, arguments: ["folder:\(folderId)", fence.jobId, now])!
            guard !competing else { return nil }
            let previous: Int64 = row["scan_generation"]
            let (generation, overflow) = previous.addingReportingOverflow(1)
            guard !overflow else { throw StorageV19Error.invalidValue }
            try db.execute(sql: "UPDATE folder_sources SET scan_state='scanning',scan_generation=? WHERE id=?",
                           arguments: [generation, folderId])
            return (ScanTicket(folderId: folderId, generation: generation, fence: fence), row["notebook_id"])
        }
        guard let begun else { return nil }
        notifyFolderIngestionChanged(notebookId: begun.1)
        return begun.0
    }

    /// Commits one observed regular file. Throws `staleLease` once the ticket no
    /// longer owns the folder's current scan. Returns the extraction request when
    /// new extraction work was queued.
    public func observeFolderFile(ticket: ScanTicket, observation: FolderObservation, now: Int64) throws -> ExtractionRequest? {
        try FolderIngestionSQL.validate(observation)
        let result = try dbQueue.write { db -> (ExtractionRequest?, Int64) in
            let folder = try FolderIngestionSQL.owned(db, ticket: ticket, now: now)
            return (try FolderIngestionSQL.observe(db, folder: folder, generation: ticket.generation,
                                                   observation: observation, now: now), folder.notebookId)
        }
        notifyFolderIngestionChanged(notebookId: result.1)
        return result.0
    }

    /// Commits a batch of scanner observations in one transaction (contract
    /// `ingestion-scan-perf-v1` §1–2). Every observation is validated first; an
    /// invalid one rejects the batch. A row whose inventory and source already
    /// match the observation only gets `seen_generation` bumped (one bulk
    /// UPDATE); every other row takes exactly the `observeFolderFile` /
    /// `observeInteriorLink` path. Posts one `folderIngestionDidChange` when any
    /// row changed, otherwise a throttled status-only signal (files seen);
    /// nothing for an empty batch or a rejected ticket.
    public func observeFolderFiles(ticket: ScanTicket, observations: [FolderScanObservation],
                                   now: Int64) throws -> FolderObserveBatchResult {
        for item in observations { try FolderIngestionSQL.validate(item.observation) }
        guard !observations.isEmpty else { return FolderObserveBatchResult(changed: 0, unchanged: 0) }
        let (result, notebookId) = try dbQueue.write { db -> (FolderObserveBatchResult, Int64) in
            let folder = try FolderIngestionSQL.owned(db, ticket: ticket, now: now)
            return (try FolderIngestionSQL.observeBatch(db, folder: folder, generation: ticket.generation,
                                                        observations: observations, now: now), folder.notebookId)
        }
        if result.changed > 0 {
            notifyFolderIngestionChanged(notebookId: notebookId)
        } else if result.unchanged > 0 {
            notifyIndexingProgress(notebookId: notebookId)
        }
        return result
    }

    /// The folder's sources keyed by `rel_path`: the scanner's fast-path snapshot.
    /// A stale entry is harmless — the commit re-checks every row and an outdated
    /// skip falls back to queuing extraction from the committed hash.
    func folderKnownSources(folderId: Int64) throws -> [String: FolderKnownSource] {
        try dbQueue.read { db in
            var known: [String: FolderKnownSource] = [:]
            let rows = try Row.fetchCursor(db, sql: """
                SELECT rel_path,id,status,mtime,size_bytes,content_hash,current_revision,published_revision_id,
                    \(RetryBudgetSQL.gaveUpPredicate) AS gave_up
                FROM sources WHERE folder_id=? AND rel_path IS NOT NULL
                """, arguments: [folderId])
            while let row = try rows.next() {
                known[row["rel_path"]] = FolderKnownSource(id: row["id"], status: row["status"], mtimeNs: row["mtime"],
                    sizeBytes: row["size_bytes"], contentHash: row["content_hash"], currentRevision: row["current_revision"],
                    publishedRevisionId: row["published_revision_id"], gaveUp: row["gave_up"])
            }
            return known
        }
    }

    /// Interior links are never followed or created as sources. A source that a
    /// link replaced becomes ineligible (`ignored`) and its extraction stops.
    func observeInteriorLink(ticket: ScanTicket, relPath: String, stamp: FileStamp, now: Int64) throws {
        let notebookId = try dbQueue.write { db -> Int64? in
            let folder = try FolderIngestionSQL.owned(db, ticket: ticket, now: now)
            guard try FolderIngestionSQL.known(db, folderId: folder.id, relPath: relPath) != nil else { return nil }
            _ = try FolderIngestionSQL.observe(db, folder: folder, generation: ticket.generation,
                observation: FolderObservation(relPath: relPath, stamp: stamp, kind: "skipped",
                                               skipReason: "ignored", contentHash: nil), now: now)
            return folder.notebookId
        }
        if let notebookId { notifyFolderIngestionChanged(notebookId: notebookId) }
    }

    /// Finishes the ticket's scan atomically with its job. Missing-marking is
    /// confined to completed subtrees; unavailable roots and unexpected errors
    /// mark nothing missing. Returns false for a stale ticket.
    public func finishFolderScan(ticket: ScanTicket, completion: ScanCompletion, now: Int64) throws -> Bool {
        let notebookId = try dbQueue.write { db -> Int64? in
            let folder: FolderSource
            do { folder = try FolderIngestionSQL.owned(db, ticket: ticket, now: now) }
            catch StorageV19Error.staleLease { return nil }
            try FolderIngestionSQL.finish(db, folder: folder, generation: ticket.generation, completion: completion, now: now)
            guard try RevisionJobSQL.completeJob(db, fence: ticket.fence, now: now) else { throw StorageV19Error.staleLease }
            return folder.notebookId
        }
        guard let notebookId else { return false }
        notifyFolderIngestionChanged(notebookId: notebookId)
        return true
    }

    /// A cancelled scan cannot finish. Cancels the owned job and marks only the
    /// current generation partial; no missing-marking happens.
    public func markFolderScanCancelled(ticket: ScanTicket, now: Int64) throws -> Bool {
        let notebookId = try dbQueue.write { db -> Int64? in
            let cancelled = try RevisionJobSQL.cancelJob(db, fence: ticket.fence, now: now)
            try db.execute(sql: """
                UPDATE folder_sources SET scan_state='partial' WHERE id=? AND scan_generation=? AND scan_state='scanning'
                """, arguments: [ticket.folderId, ticket.generation])
            guard cancelled || db.changesCount == 1 else { return nil }
            return try Int64.fetchOne(db, sql: "SELECT notebook_id FROM folder_sources WHERE id=?", arguments: [ticket.folderId])
        }
        guard let notebookId else { return false }
        notifyFolderIngestionChanged(notebookId: notebookId)
        return true
    }

    /// Commits rules, eligibility flags, inventory reasons, job cancellation and
    /// queued work atomically. `eligibility` must cover every stored folder
    /// source and inventory path; a path observed after classification rejects
    /// the call with `staleRevision` so the caller recomputes from fresh rows.
    /// `skipReasons` supplies the classifier's reason for ineligible paths.
    public func applyFolderRules(folderId: Int64, rules: FolderRules, eligibility: [String: Bool],
                                 skipReasons: [String: String] = [:], now: Int64) throws {
        try rules.limits.validate()
        guard ["cp1250", "none"].contains(rules.encodingFallback) else { throw IngestionError(code: "unsupportedEncoding") }
        let notebookId = try dbQueue.write { db -> Int64 in
            try FolderIngestionSQL.applyRules(db, folderId: folderId, rules: rules, eligibility: eligibility,
                                              skipReasons: skipReasons, now: now)
        }
        notifyFolderIngestionChanged(notebookId: notebookId)
    }

    /// Request for a restarted extract job. The hash is the last committed hash
    /// (possibly empty); the worker always replaces it with its opened-file hash.
    public func extractionRequest(sourceId: Int64) throws -> ExtractionRequest? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT folder_id,rel_path,mtime,size_bytes,content_hash FROM sources WHERE id=? AND folder_id IS NOT NULL
                """, arguments: [sourceId]) else { return nil }
            let folder = try FolderIngestionSQL.folder(db, id: row["folder_id"])
            return ExtractionRequest(sourceId: sourceId, folderId: folder.id, relPath: row["rel_path"],
                stamp: FileStamp(identity: "", mtimeNs: row["mtime"] ?? 0, sizeBytes: row["size_bytes"] ?? 0),
                hash: row["content_hash"] ?? "", rules: try folder.rules)
        }
    }
}

enum FolderIngestionSQL {
    static func folder(_ db: Database, id: Int64) throws -> FolderSource {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM folder_sources WHERE id=?", arguments: [id]) else {
            throw StorageV19Error.notFound
        }
        let decoder = JSONDecoder()
        let identity: String = row["path_identity"], includes: String = row["include_exts"], ignores: String = row["ignore_globs"]
        let date: Date = row["created_at"]
        return FolderSource(id: row["id"], notebookId: row["notebook_id"], draft: FolderDraft(
            rootPath: row["root_path"], displayName: row["display_name"],
            includeExts: try decoder.decode([String].self, from: Data(includes.utf8)),
            ignoreGlobs: try decoder.decode([String].self, from: Data(ignores.utf8)), limitsJSON: row["limits"],
            encodingFallback: row["encoding_fallback"], watchEnabled: row["watch_enabled"]),
            identity: try decoder.decode(FolderIdentity.self, from: Data(identity.utf8)),
            scanState: row["scan_state"], scanGeneration: row["scan_generation"], lastFullScanAt: row["last_full_scan_at"],
            lastScanError: row["last_scan_error"], createdAt: Int64(date.timeIntervalSince1970))
    }

    static func known(_ db: Database, folderId: Int64, relPath: String) throws -> FolderKnownSource? {
        try Row.fetchOne(db, sql: """
            SELECT id,status,mtime,size_bytes,content_hash,current_revision,published_revision_id,
                \(RetryBudgetSQL.gaveUpPredicate) AS gave_up
            FROM sources WHERE folder_id=? AND rel_path=?
            """, arguments: [folderId, relPath]).map {
                FolderKnownSource(id: $0["id"], status: $0["status"], mtimeNs: $0["mtime"], sizeBytes: $0["size_bytes"],
                                  contentHash: $0["content_hash"], currentRevision: $0["current_revision"],
                                  publishedRevisionId: $0["published_revision_id"], gaveUp: $0["gave_up"])
            }
    }

    /// The ticket must own the running scan job and the folder's current scanning generation.
    static func owned(_ db: Database, ticket: ScanTicket, now: Int64) throws -> FolderSource {
        guard let job = try RevisionJobSQL.validateFence(db, fence: ticket.fence, now: now),
              job.draft.kind == "scan", job.draft.target == "folder:\(ticket.folderId)" else {
            throw StorageV19Error.staleLease
        }
        let folder = try folder(db, id: ticket.folderId)
        guard folder.scanState == "scanning", folder.scanGeneration == ticket.generation else {
            throw StorageV19Error.staleLease
        }
        return folder
    }

    static func validate(_ observation: FolderObservation) throws {
        try validatePath(observation.relPath)
        guard observation.stamp.sizeBytes >= 0 else { throw StorageV19Error.invalidValue }
        switch observation.kind {
        case "eligible":
            guard observation.skipReason == nil else { throw StorageV19Error.invalidValue }
        case "skipped":
            guard ["ignored", "unsupported_ext", "over_limit"].contains(observation.skipReason ?? ""),
                  observation.contentHash == nil else { throw StorageV19Error.invalidValue }
        default:
            throw StorageV19Error.invalidValue
        }
        if let hash = observation.contentHash, hash.isEmpty { throw StorageV19Error.invalidValue }
    }

    static func validatePath(_ path: String) throws {
        let bytes = Array(path.utf8)
        let drive = bytes.count >= 2 && ((65...90).contains(bytes[0]) || (97...122).contains(bytes[0])) && bytes[1] == 58
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0"), !drive,
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw StorageV19Error.invalidPath
        }
    }

    static func upsertItem(_ db: Database, folderId: Int64, relPath: String, kind: String, reason: String?,
                           mtime: Int64?, size: Int64?, generation: Int64) throws {
        try db.execute(sql: """
            INSERT INTO scan_items(folder_id,rel_path,kind,skip_reason,mtime,size_bytes,seen_generation)
            VALUES(?,?,?,?,?,?,?) ON CONFLICT(folder_id,rel_path) DO UPDATE SET kind=excluded.kind,
            skip_reason=excluded.skip_reason,mtime=excluded.mtime,size_bytes=excluded.size_bytes,
            seen_generation=excluded.seen_generation
            """, arguments: [folderId, relPath, kind, reason, mtime, size, generation])
    }

    /// New work is immediately due: a null retry deadline (queued rows only).
    static func enqueueDue(_ db: Database, draft: IngestJobDraft, now: Int64) throws -> Int64 {
        let id = try RevisionJobSQL.enqueueJob(db, draft: draft, now: now)
        try db.execute(sql: "UPDATE ingest_jobs SET next_retry_at=NULL WHERE id=?", arguments: [id])
        return id
    }

    /// Unfinished = queued, running, paused, or failed with an automatic retry pending.
    static let unfinishedExtract = """
        kind='extract' AND target=? AND (state IN ('queued','running','paused')
            OR (state='failed' AND attempts<5 AND next_retry_at IS NOT NULL))
        """

    static func cancelExtractions(_ db: Database, sourceId: Int64, except keep: Int64? = nil) throws {
        try db.execute(sql: """
            UPDATE ingest_jobs SET state='cancelled',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
            WHERE \(unfinishedExtract) AND id IS NOT ?
            """, arguments: ["source:\(sourceId)", keep])
    }

    /// Queues extraction for the current pointer unless an unclaimed job for it
    /// already exists (or `running` is allowed to stand for unchanged bytes).
    /// Returns true when a new job was queued.
    @discardableResult
    static func requireExtraction(_ db: Database, sourceId: Int64, keepRunning: Bool, now: Int64) throws -> Bool {
        // A spent failure budget queues nothing until the content changes or the user retries.
        guard try !RetryBudgetSQL.exhausted(db, sourceId: sourceId) else { return false }
        let current = try Int64.fetchOne(db, sql: "SELECT current_revision FROM sources WHERE id=?", arguments: [sourceId])
        let jobs = try Row.fetchAll(db, sql: "SELECT id,state,target_revision FROM ingest_jobs WHERE \(unfinishedExtract) ORDER BY id",
                                    arguments: ["source:\(sourceId)"])
        let reusable = jobs.last { row in
            let state: String = row["state"]
            let target: Int64? = row["target_revision"]
            return target == current && (state == "queued" || state == "paused" || (keepRunning && state == "running"))
        }
        if let reusable {
            let id: Int64 = reusable["id"]
            try cancelExtractions(db, sourceId: sourceId, except: id)
            let state: String = reusable["state"]
            if state != "running" {
                try db.execute(sql: "UPDATE sources SET status='pending',error=NULL WHERE id=?", arguments: [sourceId])
            }
            return false
        }
        try cancelExtractions(db, sourceId: sourceId)
        _ = try enqueueDue(db, draft: IngestJobDraft(kind: "extract", target: "source:\(sourceId)",
                                                                   targetRevision: current), now: now)
        try db.execute(sql: "UPDATE sources SET status='pending',error=NULL WHERE id=?", arguments: [sourceId])
        return true
    }

    static func observe(_ db: Database, folder: FolderSource, generation: Int64,
                        observation: FolderObservation, now: Int64) throws -> ExtractionRequest? {
        let stamp = observation.stamp
        try upsertItem(db, folderId: folder.id, relPath: observation.relPath, kind: observation.kind,
                       reason: observation.skipReason, mtime: stamp.mtimeNs, size: stamp.sizeBytes, generation: generation)
        let existing = try known(db, folderId: folder.id, relPath: observation.relPath)
        if observation.kind == "skipped" {
            guard let existing else { return nil }
            try db.execute(sql: "UPDATE sources SET availability='present',eligible=0,mtime=?,size_bytes=? WHERE id=?",
                           arguments: [stamp.mtimeNs, stamp.sizeBytes, existing.id])
            try cancelExtractions(db, sourceId: existing.id)
            return nil
        }
        let rules = try folder.rules
        guard let existing else {
            // A new file is always hashed: the scanner never fast-paths an unknown path.
            guard let hash = observation.contentHash else { throw StorageV19Error.invalidValue }
            let name = observation.relPath.split(separator: "/").last.map(String.init) ?? observation.relPath
            let type = SourceType.detect(filename: name) ?? .text
            try db.execute(sql: """
                INSERT INTO sources(notebook_id,type,title,uri,raw_path,status,error,ingested_at,folder_id,rel_path,
                    mtime,size_bytes,availability,eligible) VALUES(?,?,?,NULL,?,'pending',NULL,?,?,?,?,?,'present',1)
                """, arguments: [folder.notebookId, type.rawValue, name, rawPath(folder, observation.relPath),
                                  Date(timeIntervalSince1970: TimeInterval(now)), folder.id, observation.relPath,
                                  stamp.mtimeNs, stamp.sizeBytes])
            let sourceId = db.lastInsertedRowID
            try RetryBudgetSQL.observe(db, sourceId: sourceId, hash: hash, sameStamp: false)
            _ = try enqueueDue(db, draft: IngestJobDraft(kind: "extract", target: "source:\(sourceId)",
                                                                       targetRevision: nil), now: now)
            return ExtractionRequest(sourceId: sourceId, folderId: folder.id, relPath: observation.relPath,
                                     stamp: stamp, hash: hash, rules: rules)
        }
        let sameStamp = existing.mtimeNs == stamp.mtimeNs && existing.sizeBytes == stamp.sizeBytes
        let committed = (existing.contentHash ?? "").isEmpty ? nil : existing.contentHash
        let currentPublished = existing.publishedRevisionId != nil && existing.currentRevision == existing.publishedRevisionId
        try db.execute(sql: "UPDATE sources SET availability='present',eligible=1,mtime=?,size_bytes=? WHERE id=?",
                       arguments: [stamp.mtimeNs, stamp.sizeBytes, existing.id])
        if let hash = observation.contentHash {
            if let committed, currentPublished, hash.utf8.elementsEqual(committed.utf8) {
                // The committed bytes are on disk: any pending refresh is superseded.
                if existing.status != SourceStatus.ready.rawValue {
                    try cancelExtractions(db, sourceId: existing.id)
                    try db.execute(sql: "UPDATE sources SET status='ready',error=NULL WHERE id=?", arguments: [existing.id])
                    try RetryBudgetSQL.clear(db, sourceId: existing.id)
                }
                return nil
            }
        } else if FolderScanner.canSkipRead(existing, stamp: stamp, verifyAll: false) {
            return nil
        }
        // Metadata alone never suppresses pending or failed extraction; a spent budget
        // for the same content does (`ingestion-retry-cap-v1` §4).
        try RetryBudgetSQL.observe(db, sourceId: existing.id, hash: observation.contentHash, sameStamp: sameStamp)
        guard try requireExtraction(db, sourceId: existing.id, keepRunning: sameStamp, now: now) else { return nil }
        return ExtractionRequest(sourceId: existing.id, folderId: folder.id, relPath: observation.relPath,
                                 stamp: stamp, hash: observation.contentHash ?? committed ?? "", rules: rules)
    }

    /// Bound parameters per bulk statement (well under SQLite's variable limit).
    static let bulkChunk = 400

    /// The batch body of `observeFolderFiles`: bulk-reads inventory and sources
    /// of the batch, bumps `seen_generation` of unchanged rows in bulk and runs
    /// `observe` for every other row, in input order.
    static func observeBatch(_ db: Database, folder: FolderSource, generation: Int64,
                             observations: [FolderScanObservation], now: Int64) throws -> FolderObserveBatchResult {
        struct Item { let kind: String; let reason: String?; let mtime: Int64?; let size: Int64? }
        struct Source { let known: FolderKnownSource; let availability: String; let eligible: Bool }
        var items: [String: Item] = [:], sources: [String: Source] = [:]
        let paths = observations.map(\.observation.relPath)
        for start in stride(from: 0, to: paths.count, by: bulkChunk) {
            let chunk = Array(paths[start..<min(paths.count, start + bulkChunk)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for row in try Row.fetchAll(db, sql: """
                SELECT rel_path,kind,skip_reason,mtime,size_bytes FROM scan_items WHERE folder_id=? AND rel_path IN (\(marks))
                """, arguments: StatementArguments([folder.id as DatabaseValueConvertible] + chunk.map { $0 as DatabaseValueConvertible })) {
                items[row["rel_path"]] = Item(kind: row["kind"], reason: row["skip_reason"], mtime: row["mtime"], size: row["size_bytes"])
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT rel_path,id,status,mtime,size_bytes,content_hash,current_revision,published_revision_id,availability,eligible,
                    \(RetryBudgetSQL.gaveUpPredicate) AS gave_up
                FROM sources WHERE folder_id=? AND rel_path IN (\(marks))
                """, arguments: StatementArguments([folder.id as DatabaseValueConvertible] + chunk.map { $0 as DatabaseValueConvertible })) {
                sources[row["rel_path"]] = Source(known: FolderKnownSource(id: row["id"], status: row["status"], mtimeNs: row["mtime"],
                    sizeBytes: row["size_bytes"], contentHash: row["content_hash"], currentRevision: row["current_revision"],
                    publishedRevisionId: row["published_revision_id"], gaveUp: row["gave_up"]),
                    availability: row["availability"], eligible: row["eligible"])
            }
        }
        /// Inventory and source already say exactly what the observation says.
        func unchanged(_ observation: FolderObservation) -> Bool {
            let stamp = observation.stamp
            guard let item = items[observation.relPath], item.kind == observation.kind, item.reason == observation.skipReason,
                  item.mtime == stamp.mtimeNs, item.size == stamp.sizeBytes else { return false }
            let source = sources[observation.relPath]
            if observation.kind == "skipped" { return source == nil }
            guard let source, source.availability == "present", source.eligible,
                  source.known.mtimeNs == stamp.mtimeNs, source.known.sizeBytes == stamp.sizeBytes else { return false }
            guard let hash = observation.contentHash else {
                return FolderScanner.canSkipRead(source.known, stamp: stamp, verifyAll: false)
            }
            let known = source.known
            return !(known.contentHash ?? "").isEmpty && hash.utf8.elementsEqual((known.contentHash ?? "").utf8)
                && known.publishedRevisionId != nil && known.currentRevision == known.publishedRevisionId
                && known.status == SourceStatus.ready.rawValue
        }
        var bump: [String] = []
        var changed = 0
        var touched = Set<String>()
        for item in observations {
            let observation = item.observation
            // A repeated path sees its own earlier write: never trust the snapshot twice.
            let first = touched.insert(observation.relPath).inserted
            if item.knownOnly {
                let hasSource = first ? sources[observation.relPath] != nil
                    : try known(db, folderId: folder.id, relPath: observation.relPath) != nil
                guard hasSource else { continue }
            }
            if first, unchanged(observation) {
                bump.append(observation.relPath)
                continue
            }
            _ = try observe(db, folder: folder, generation: generation, observation: observation, now: now)
            changed += 1
        }
        for start in stride(from: 0, to: bump.count, by: bulkChunk) {
            let chunk = Array(bump[start..<min(bump.count, start + bulkChunk)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try db.execute(sql: "UPDATE scan_items SET seen_generation=? WHERE folder_id=? AND rel_path IN (\(marks))",
                           arguments: StatementArguments([generation as DatabaseValueConvertible, folder.id] + chunk.map { $0 as DatabaseValueConvertible }))
        }
        return FolderObserveBatchResult(changed: changed, unchanged: bump.count)
    }

    static func rawPath(_ folder: FolderSource, _ relPath: String) -> String {
        folder.draft.rootPath.hasSuffix("/") ? folder.draft.rootPath + relPath : folder.draft.rootPath + "/" + relPath
    }

    /// Component-prefix membership by exact scalar bytes; never `LIKE`.
    static func contains(prefix: String, path: String) -> Bool {
        prefix.isEmpty || path.utf8.elementsEqual(prefix.utf8) || path.utf8.starts(with: (prefix + "/").utf8)
    }

    static func finish(_ db: Database, folder: FolderSource, generation: Int64, completion: ScanCompletion, now: Int64) throws {
        if completion.rootUnavailable {
            try db.execute(sql: "UPDATE folder_sources SET scan_state='unavailable',last_scan_error=? WHERE id=?",
                           arguments: [completion.error ?? "rootUnavailable", folder.id])
            try db.execute(sql: "UPDATE sources SET availability='unavailable' WHERE folder_id=? AND availability='present'",
                           arguments: [folder.id])
            return
        }
        if let error = completion.error {
            try db.execute(sql: "UPDATE folder_sources SET scan_state='error',last_scan_error=? WHERE id=?",
                           arguments: [error, folder.id])
            return
        }
        for path in completion.completed + completion.incomplete where !path.isEmpty { try validatePath(path) }
        let prefixes = completion.completed
        if !prefixes.isEmpty {
            let sources = try Row.fetchAll(db, sql: """
                SELECT s.id,s.rel_path,s.availability,i.seen_generation FROM sources s
                LEFT JOIN scan_items i ON i.folder_id=s.folder_id AND i.rel_path=s.rel_path
                WHERE s.folder_id=? ORDER BY s.id
                """, arguments: [folder.id])
            for row in sources {
                let path: String = row["rel_path"]
                let seen: Int64? = row["seen_generation"]
                let availability: String = row["availability"]
                guard seen != generation, availability != "missing",
                      prefixes.contains(where: { contains(prefix: $0, path: path) }) else { continue }
                let id: Int64 = row["id"]
                try db.execute(sql: "UPDATE sources SET availability='missing' WHERE id=?", arguments: [id])
                try cancelExtractions(db, sourceId: id)
            }
            let items = try Row.fetchAll(db, sql: """
                SELECT i.rel_path FROM scan_items i WHERE i.folder_id=? AND i.seen_generation<>?
                AND NOT EXISTS(SELECT 1 FROM sources s WHERE s.folder_id=i.folder_id AND s.rel_path=i.rel_path)
                """, arguments: [folder.id, generation])
            for row in items {
                let path: String = row["rel_path"]
                guard prefixes.contains(where: { contains(prefix: $0, path: path) }) else { continue }
                try db.execute(sql: "DELETE FROM scan_items WHERE folder_id=? AND rel_path=?", arguments: [folder.id, path])
            }
        }
        let full = completion.incomplete.isEmpty && completion.completed.contains("")
        if full {
            try db.execute(sql: "UPDATE folder_sources SET scan_state='idle',last_full_scan_at=?,last_scan_error=NULL WHERE id=?",
                           arguments: [now, folder.id])
        } else {
            try db.execute(sql: "UPDATE folder_sources SET scan_state='partial',last_scan_error=NULL WHERE id=?",
                           arguments: [folder.id])
        }
    }

    struct RuleRow {
        let relPath: String
        let sizeBytes: Int64?
        let sourceId: Int64?
    }

    static func ruleRows(_ db: Database, folderId: Int64) throws -> [RuleRow] {
        let sources = try Row.fetchAll(db, sql: "SELECT id,rel_path,size_bytes FROM sources WHERE folder_id=? ORDER BY id",
                                       arguments: [folderId]).map {
            RuleRow(relPath: $0["rel_path"], sizeBytes: $0["size_bytes"], sourceId: $0["id"])
        }
        let items = try Row.fetchAll(db, sql: """
            SELECT i.rel_path,i.size_bytes FROM scan_items i WHERE i.folder_id=?
            AND NOT EXISTS(SELECT 1 FROM sources s WHERE s.folder_id=i.folder_id AND s.rel_path=i.rel_path)
            ORDER BY i.rel_path
            """, arguments: [folderId]).map { RuleRow(relPath: $0["rel_path"], sizeBytes: $0["size_bytes"], sourceId: nil) }
        return sources + items
    }

    /// Reason for an ineligible stored row when the classifier supplied none.
    static func fallbackReason(_ rules: FolderRules, _ row: RuleRow) -> String {
        guard let ext = FolderClassifier.extensionName(row.relPath), rules.includeExts.contains(ext) else { return "unsupported_ext" }
        if let size = row.sizeBytes, size > rules.limits.fileBytes { return "over_limit" }
        return "ignored"
    }

    static func applyRules(_ db: Database, folderId: Int64, rules: FolderRules, eligibility: [String: Bool],
                           skipReasons: [String: String], now: Int64) throws -> Int64 {
        let folder = try folder(db, id: folderId)
        let rows = try ruleRows(db, folderId: folderId)
        // Rows observed after the caller classified must be classified too.
        guard rows.allSatisfy({ eligibility[$0.relPath] != nil }) else { throw StorageV19Error.staleRevision }
        let old = try? folder.rules
        let forceExtraction = old.map { $0.limits != rules.limits || $0.encodingFallback != rules.encodingFallback } ?? true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try db.execute(sql: """
            UPDATE folder_sources SET include_exts=?,ignore_globs=?,limits=?,encoding_fallback=? WHERE id=?
            """, arguments: [String(decoding: try encoder.encode(rules.includeExts), as: UTF8.self),
                              String(decoding: try encoder.encode(rules.ignoreGlobs), as: UTF8.self),
                              String(decoding: try encoder.encode(rules.limits), as: UTF8.self),
                              rules.encodingFallback, folderId])
        for row in rows {
            let eligible = eligibility[row.relPath]!
            let reason = eligible ? nil : (skipReasons[row.relPath] ?? fallbackReason(rules, row))
            let item = try Row.fetchOne(db, sql: "SELECT seen_generation,mtime,size_bytes FROM scan_items WHERE folder_id=? AND rel_path=?",
                                        arguments: [folderId, row.relPath])
            guard let sourceId = row.sourceId else {
                try db.execute(sql: "UPDATE scan_items SET kind=?,skip_reason=? WHERE folder_id=? AND rel_path=?",
                               arguments: [eligible ? "eligible" : "skipped", reason, folderId, row.relPath])
                continue
            }
            let source = try Row.fetchOne(db, sql: """
                SELECT eligible,availability,status,mtime,size_bytes,current_revision,published_revision_id FROM sources WHERE id=?
                """, arguments: [sourceId])!
            let availability: String = source["availability"]
            if let item {
                try upsertItem(db, folderId: folderId, relPath: row.relPath, kind: eligible ? "eligible" : "skipped",
                               reason: reason, mtime: item["mtime"], size: item["size_bytes"], generation: item["seen_generation"])
            } else if availability != "missing" {
                try upsertItem(db, folderId: folderId, relPath: row.relPath, kind: eligible ? "eligible" : "skipped",
                               reason: reason, mtime: source["mtime"], size: source["size_bytes"], generation: folder.scanGeneration)
            }
            let wasEligible: Bool = source["eligible"]
            try db.execute(sql: "UPDATE sources SET eligible=? WHERE id=?", arguments: [eligible, sourceId])
            guard eligible else {
                try cancelExtractions(db, sourceId: sourceId)
                continue
            }
            let status: String = source["status"]
            let current: Int64? = source["current_revision"], published: Int64? = source["published_revision_id"]
            let needsWork = published == nil || current != published || status != SourceStatus.ready.rawValue
            if (!wasEligible && needsWork) || forceExtraction {
                // New limits or encoding may resolve a failure: the budget starts over.
                if forceExtraction { try RetryBudgetSQL.reset(db, sourceId: sourceId) }
                try requireExtraction(db, sourceId: sourceId, keepRunning: !forceExtraction, now: now)
            }
        }
        // A folder rescan discovers unknown files and re-extracts under the new rules.
        let queuedScan = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM ingest_jobs WHERE kind='scan' AND target=? AND state='queued')
            """, arguments: ["folder:\(folderId)"])!
        if !queuedScan {
            _ = try enqueueDue(db, draft: IngestJobDraft(kind: "scan", target: "folder:\(folderId)",
                targetRevision: nil, optionsJSON: #"{"verifyAll":false}"#), now: now)
        }
        return folder.notebookId
    }
}

import Foundation
import GRDB

public struct GenerationProgress: Sendable, Equatable {
    public let generationId: Int64?
    public let done: Int
    public let total: Int
    public let excluded: Int
    public let failed: Bool
    public let pausedForChat: Bool
    public let hasActive: Bool
    public let jobId: Int64?
    public let preparing: Bool
    public let errorCode: String?
    /// Vectors this build copied from an identical chunk text instead of a provider call
    /// (`embedding-plan-v1` §6); they count toward `done` like any other vector.
    public let copied: Int

    public init(generationId: Int64?, done: Int, total: Int, excluded: Int, failed: Bool, pausedForChat: Bool,
                hasActive: Bool, jobId: Int64?, preparing: Bool, errorCode: String?, copied: Int = 0) {
        self.generationId = generationId
        self.done = done
        self.total = total
        self.excluded = excluded
        self.failed = failed
        self.pausedForChat = pausedForChat
        self.hasActive = hasActive
        self.jobId = jobId
        self.preparing = preparing
        self.errorCode = errorCode
        self.copied = copied
    }

    func with(pausedForChat: Bool) -> GenerationProgress {
        GenerationProgress(generationId: generationId, done: done, total: total, excluded: excluded, failed: failed,
                           pausedForChat: pausedForChat, hasActive: hasActive, jobId: jobId, preparing: preparing,
                           errorCode: errorCode, copied: copied)
    }
}

/// One published chunk captured for an embedding batch, with explicit revision identity.
public struct EmbeddingBatchItem: Sendable, Equatable {
    public let chunkId: Int64
    public let sourceId: Int64
    public let revisionId: Int64
    public let text: String
}

/// A captured chunk whose text equals the input at `chunkId`: it receives that vector at commit.
public struct EmbeddingDuplicate: Sendable, Equatable {
    public let chunkId: Int64
    public let revisionId: Int64
    public let ofChunkId: Int64

    public init(chunkId: Int64, revisionId: Int64, ofChunkId: Int64) {
        self.chunkId = chunkId
        self.revisionId = revisionId
        self.ofChunkId = ofChunkId
    }
}

extension EmbeddingSelection {
    init(identity: GenerationIdentity) {
        self.init(providerId: identity.providerId, endpointRevision: identity.endpointRevision, model: identity.model,
                  modelDigest: identity.modelDigest, dims: identity.dims, normalization: identity.normalization,
                  queryFormatVersion: identity.queryFormatVersion, docFormatVersion: identity.docFormatVersion,
                  chunkerVersion: identity.chunkerVersion)
    }

    /// Decodes the durable `{selection,copyExisting}` embed options (explicit nulls allowed).
    static func fromOptions(_ json: String) throws -> (EmbeddingSelection, Bool) {
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let value = object["selection"] as? [String: Any],
              let providerId = value["providerId"] as? String, let endpoint = value["endpointRevision"] as? String,
              let model = value["model"] as? String, let normalization = value["normalization"] as? String,
              let query = value["queryFormatVersion"] as? String, let doc = value["docFormatVersion"] as? String,
              let chunker = value["chunkerVersion"] as? String else { throw StorageV19Error.invalidValue }
        let selection = EmbeddingSelection(providerId: providerId, endpointRevision: endpoint, model: model,
            modelDigest: value["modelDigest"] as? String, dims: (value["dims"] as? NSNumber)?.intValue,
            normalization: normalization, queryFormatVersion: query, docFormatVersion: doc, chunkerVersion: chunker)
        return (selection, object["copyExisting"] as? Bool ?? true)
    }
}

extension NotebookStore {
    /// Explicit re-index with verified dimensions: a fresh building generation
    /// beside the active one and exactly one generation job. Returns the generation ID.
    public func requestReindex(notebookId: Int64, identity: GenerationIdentity, now: Int64) throws -> Int64 {
        let generationId = try dbQueue.write { db -> Int64 in
            let jobId = try IngestionGenerationSQL.enqueueBuild(db, notebookId: notebookId,
                selection: EmbeddingSelection(identity: identity), copyExisting: false, now: now)
            guard let job = try RevisionJobSQL.job(db, id: jobId), let id = Int64(job.draft.target.dropFirst("generation:".count)) else {
                throw StorageV19Error.invalidValue
            }
            return id
        }
        notifyFolderIngestionChanged(notebookId: notebookId)
        return generationId
    }

    /// Persists a captured nonsecret selection as a build job; returns the job ID.
    public func requestEmbeddingBuild(notebookId: Int64, selection: EmbeddingSelection, copyExisting: Bool, now: Int64) throws -> Int64 {
        let jobId = try dbQueue.write { db in
            try IngestionGenerationSQL.enqueueBuild(db, notebookId: notebookId, selection: selection, copyExisting: copyExisting, now: now)
        }
        notifyFolderIngestionChanged(notebookId: notebookId)
        return jobId
    }

    /// Ensures one queued scan for the folder. Verify-all upgrades an unclaimed
    /// job; a running scan gets exactly one queued successor.
    public func requestFolderScan(folderId: Int64, verifyAll: Bool, now: Int64) throws -> Int64 {
        let (jobId, notebookId) = try dbQueue.write { db -> (Int64, Int64) in
            let folder = try FolderIngestionSQL.folder(db, id: folderId)
            if let queued = try Row.fetchOne(db, sql: """
                SELECT id,options_json FROM ingest_jobs WHERE kind='scan' AND target=? AND state='queued' ORDER BY id LIMIT 1
                """, arguments: ["folder:\(folderId)"]) {
                let id: Int64 = queued["id"]
                if verifyAll, try !Self.verifyAllOption(queued["options_json"]) {
                    try db.execute(sql: "UPDATE ingest_jobs SET options_json=? WHERE id=? AND state='queued'",
                                   arguments: [#"{"verifyAll":true}"#, id])
                }
                return (id, folder.notebookId)
            }
            let id = try FolderIngestionSQL.enqueueDue(db, draft: IngestJobDraft(kind: "scan", target: "folder:\(folderId)",
                targetRevision: nil, optionsJSON: verifyAll ? #"{"verifyAll":true}"# : #"{"verifyAll":false}"#), now: now)
            return (id, folder.notebookId)
        }
        notifyFolderIngestionChanged(notebookId: notebookId)
        return jobId
    }

    public func scanOptions(jobId: Int64) throws -> Bool {
        try dbQueue.read { db in
            guard let job = try RevisionJobSQL.job(db, id: jobId), job.draft.kind == "scan" else { throw StorageV19Error.notFound }
            return try Self.verifyAllOption(job.draft.optionsJSON)
        }
    }

    nonisolated static func verifyAllOption(_ json: String) throws -> Bool {
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw StorageV19Error.invalidValue
        }
        return object["verifyAll"] as? Bool ?? false
    }

    /// Watch-enabled folders across every notebook.
    public func watchedFolders() throws -> [FolderSource] {
        try allFolders().filter(\.draft.watchEnabled)
    }

    func allFolders() throws -> [FolderSource] {
        try dbQueue.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM folder_sources ORDER BY id").map { try FolderIngestionSQL.folder(db, id: $0) }
        }
    }

    /// Scanning rows without a live scan job (crash/restart) become partial;
    /// nothing is marked missing.
    func repairOrphanScans(now: Int64) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE folder_sources SET scan_state='partial' WHERE scan_state='scanning' AND NOT EXISTS(
                    SELECT 1 FROM ingest_jobs j WHERE j.kind='scan' AND j.target='folder:'||folder_sources.id
                    AND j.state='running' AND j.lease_until>?)
                """, arguments: [now])
            return db.changesCount
        }
    }

    /// Reconciles the building generation to the newest published revisions,
    /// prunes stale vectors and marks fully covered rows done. True when the
    /// manifest or the vectors changed (new pending work may sit behind a cursor).
    @discardableResult
    func settleGeneration(generationId: Int64) throws -> Bool {
        try dbQueue.write { try IngestionGenerationSQL.settle($0, generationId: generationId) }
    }

    /// The next pending embeddable chunks in build order (`embedding-plan-v1` §4), without side effects.
    func embeddingBatch(generationId: Int64, limit: Int) throws -> [EmbeddingBatchItem] {
        try dbQueue.read { db in
            var items: [EmbeddingBatchItem] = []
            for priorityClass in 0...1 where items.count < limit {
                items += try IngestionGenerationSQL.candidates(db, generationId: generationId, priorityClass: priorityClass,
                    after: nil, limit: limit - items.count).map(\.item)
            }
            return items
        }
    }

    /// The first eligible published embeddable chunks in build order, for dimension discovery.
    func bootstrapBatch(notebookId: Int64, limit: Int) throws -> [EmbeddingBatchItem] {
        try dbQueue.read { db in
            var items: [EmbeddingBatchItem] = []
            for priorityClass in 0...1 where items.count < limit {
                items += try Row.fetchAll(db, sql: """
                    SELECT c.id,c.source_id,c.revision_id,c.text FROM sources s
                    JOIN source_chunks c ON c.revision_id=s.published_revision_id AND c.source_id=s.id
                    WHERE s.notebook_id=? AND s.availability='present' AND s.eligible=1 AND \(EmbeddingPlan.classSQL())=?
                      AND \(EmbeddingPlan.embeddableSQL())
                    ORDER BY s.id,c.ord LIMIT ?
                    """, arguments: [notebookId, priorityClass, limit - items.count]).map(IngestionGenerationSQL.item)
            }
            return items
        }
    }

    /// One fenced build round (`embedding-plan-v1` §5): settles the generation, then walks
    /// pending candidates after `cursor` in build order, copying vectors of texts the
    /// generation already embedded and collecting at most `limit` unique provider inputs.
    /// Nil when the fence is lost or the generation is no longer building.
    func captureEmbeddingRound(generationId: Int64, limit: Int, cursor: EmbeddingCursor?, fence: JobFence,
                               now: Int64) throws -> EmbeddingRound? {
        precondition(limit > 0)
        let result = try dbQueue.write { db -> (EmbeddingRound, Int64)? in
            guard let job = try RevisionJobSQL.validateFence(db, fence: fence, now: now), job.draft.kind == "embed",
                  job.draft.target == "generation:\(generationId)",
                  let generation = try GenerationSQL.generation(db, id: generationId), generation.state == "building" else { return nil }
            let reset = try IngestionGenerationSQL.settle(db, generationId: generationId)
            var position = reset ? nil : cursor
            // Keys are UTF-8 bytes: Swift String equality is canonical equivalence, dedup is exact.
            var items: [EmbeddingBatchItem] = [], inputs: [Data: Int] = [:]
            var joined: [(item: EmbeddingBatchItem, index: Int)] = []
            var copied = 0, scanned = 0
            let scanLimit = EmbeddingPlan.roundScanFactor * limit
            walk: for priorityClass in 0...1 {
                if let position, position.priorityClass > priorityClass { continue }
                var after = position?.priorityClass == priorityClass ? position : nil
                while scanned < scanLimit {
                    let page = try IngestionGenerationSQL.candidates(db, generationId: generationId, priorityClass: priorityClass,
                                                                     after: after, limit: limit)
                    if page.isEmpty { break }
                    for candidate in page {
                        let text = candidate.item.text
                        if try IngestionGenerationSQL.copyExistingVector(db, generationId: generationId, chunkId: candidate.item.chunkId,
                                                                         text: text) {
                            copied += 1
                        } else if let index = inputs[Data(text.utf8)] {
                            joined.append((candidate.item, index))
                        } else if items.count < limit {
                            inputs[Data(text.utf8)] = items.count
                            items.append(candidate.item)
                        } else {
                            break walk
                        }
                        position = candidate.cursor
                        after = candidate.cursor
                        scanned += 1
                        if scanned >= scanLimit { break walk }
                    }
                }
            }
            if copied > 0 { try IngestionGenerationSQL.markComplete(db, generation: generation) }
            return (EmbeddingRound(items: items, joined: joined, copied: copied, cursor: position, reset: reset), generation.notebookId)
        }
        guard let (round, notebookId) = result else { return nil }
        if round.copied > 0 { notifyIndexingProgress(notebookId: notebookId) }
        return round
    }

    /// Stores a fenced batch; stale members (changed/ineligible revisions) are discarded.
    /// `duplicates` (same text as a committed input) receive that input's vector bytes in the same transaction.
    public func commitEmbeddingBatch(generationId: Int64, chunkIds: [Int64], revisionIds: [Int64], vectors: [[Float]],
                                     fence: JobFence, now: Int64, duplicates: [EmbeddingDuplicate] = []) throws -> Bool {
        guard chunkIds.count == revisionIds.count, chunkIds.count == vectors.count else { throw IngestionError(code: "invalidVector") }
        let notebookId = try dbQueue.write { db -> Int64? in
            guard let job = try RevisionJobSQL.validateFence(db, fence: fence, now: now), job.draft.kind == "embed",
                  job.draft.target == "generation:\(generationId)",
                  let generation = try GenerationSQL.generation(db, id: generationId), generation.state == "building" else { return nil }
            try IngestionGenerationSQL.store(db, generation: generation, chunkIds: chunkIds, revisionIds: revisionIds, vectors: vectors)
            try IngestionGenerationSQL.storeDuplicates(db, generation: generation, duplicates: duplicates)
            try IngestionGenerationSQL.markComplete(db, generation: generation)
            return generation.notebookId
        }
        guard let notebookId else { return false }
        notifyIndexingProgress(notebookId: notebookId)
        return true
    }

    /// Bootstrap: derives the identity from the first real response, creates or
    /// reuses the building generation, stores the fresh vectors and retargets
    /// the same running job, all in one transaction. Nil when fenced out, the
    /// durable selection differs, or every captured revision went stale.
    public func commitBootstrapBatch(notebookId: Int64, selection: EmbeddingSelection, dims: Int,
                                     chunkIds: [Int64], revisionIds: [Int64], vectors: [[Float]], copyExisting: Bool,
                                     fence: JobFence, now: Int64, duplicates: [EmbeddingDuplicate] = []) throws -> Int64? {
        guard chunkIds.count == revisionIds.count, chunkIds.count == vectors.count,
              vectors.allSatisfy({ $0.count == dims }) else { throw IngestionError(code: "invalidVector") }
        let generationId = try dbQueue.write { db -> Int64? in
            guard let job = try RevisionJobSQL.validateFence(db, fence: fence, now: now), job.draft.kind == "embed",
                  job.draft.target == "notebook:\(notebookId)",
                  let durable = try? EmbeddingSelection.fromOptions(job.draft.optionsJSON).0,
                  FolderEmbeddingSession.compatible(durable, selection) else { return nil }
            let fresh = try (0..<chunkIds.count).filter { try IngestionGenerationSQL.isFresh(db, chunkId: chunkIds[$0], revisionId: revisionIds[$0]) }
            guard !fresh.isEmpty else { return nil }
            let identity = GenerationIdentity(providerId: selection.providerId, endpointRevision: selection.endpointRevision,
                model: selection.model, modelDigest: selection.modelDigest, dims: dims, normalization: selection.normalization,
                queryFormatVersion: selection.queryFormatVersion, docFormatVersion: selection.docFormatVersion,
                chunkerVersion: selection.chunkerVersion)
            let generation = try IngestionGenerationSQL.ensureBuilding(db, notebookId: notebookId, identity: identity,
                                                                       copyExisting: copyExisting, now: now)
            try IngestionGenerationSQL.store(db, generation: generation, chunkIds: fresh.map { chunkIds[$0] },
                                             revisionIds: fresh.map { revisionIds[$0] }, vectors: fresh.map { vectors[$0] })
            try IngestionGenerationSQL.storeDuplicates(db, generation: generation, duplicates: duplicates)
            try IngestionGenerationSQL.markComplete(db, generation: generation)
            guard try RevisionJobSQL.retargetEmbedJob(db, fence: fence, generationId: generation.id, now: now) else {
                throw StorageV19Error.staleLease
            }
            return generation.id
        }
        if generationId != nil { notifyFolderIngestionChanged(notebookId: notebookId) }
        return generationId
    }

    /// Activates only when every manifest row is done/excluded after a final
    /// reconcile, and the selected identity is unchanged; retirement,
    /// activation and job completion are atomic. A changed selection
    /// invalidates the build without touching the active generation.
    public func activateBuiltGeneration(id: Int64, selectedIdentity: GenerationIdentity, fence: JobFence, now: Int64) throws -> Bool {
        let result = try dbQueue.write { db -> (Bool, Int64?) in
            guard let job = try RevisionJobSQL.validateFence(db, fence: fence, now: now), job.draft.kind == "embed",
                  job.draft.target == "generation:\(id)",
                  let generation = try GenerationSQL.generation(db, id: id), generation.state == "building" else { return (false, nil) }
            guard generation.identity == selectedIdentity else {
                _ = try IngestionGenerationSQL.invalidate(db, fence: fence, now: now)
                return (false, generation.notebookId)
            }
            try GenerationSQL.reconcile(db, generationId: id)
            try IngestionGenerationSQL.pruneStaleVectors(db, generationId: id)
            try IngestionGenerationSQL.markComplete(db, generation: generation)
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM index_generation_manifest WHERE generation_id=? AND state='pending'",
                                   arguments: [id]) == 0 else { return (false, nil) }
            do { try GenerationSQL.activate(db, id: id, fence: fence, now: now) }
            catch StorageV19Error.generationNotReady { return (false, nil) }
            return (true, generation.notebookId)
        }
        if let notebookId = result.1 { notifyFolderIngestionChanged(notebookId: notebookId) }
        return result.0
    }

    /// Cancels the generation's jobs and retires only this building generation.
    public func discardBuildingGeneration(id: Int64, now: Int64) throws {
        let notebookId = try dbQueue.write { db -> Int64 in
            guard let generation = try GenerationSQL.generation(db, id: id) else { throw StorageV19Error.notFound }
            guard generation.state == "building" || generation.state == "failed" else { throw StorageV19Error.generationNotReady }
            try db.execute(sql: """
                UPDATE ingest_jobs SET state='cancelled',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
                WHERE kind='embed' AND target=? AND (state IN ('queued','running','paused')
                    OR (state='failed' AND attempts<5 AND next_retry_at IS NOT NULL))
                """, arguments: ["generation:\(id)"])
            try GenerationSQL.retire(db, id: id)
            return generation.notebookId
        }
        notifyFolderIngestionChanged(notebookId: notebookId)
    }

    /// Discards a build by job: a bootstrap job is cancelled, a generation job
    /// delegates to discarding its building generation.
    public func discardEmbedJob(jobId: Int64, notebookId: Int64, now: Int64) throws {
        guard let job = try self.job(id: jobId), job.draft.kind == "embed" else { throw StorageV19Error.notFound }
        if job.draft.target == "notebook:\(notebookId)" {
            try dbQueue.write { db in
                try db.execute(sql: """
                    UPDATE ingest_jobs SET state='cancelled',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
                    WHERE id=? AND (state IN ('queued','running','paused') OR (state='failed' AND next_retry_at IS NOT NULL))
                    """, arguments: [jobId])
            }
            notifyFolderIngestionChanged(notebookId: notebookId)
            return
        }
        guard let generationId = Int64(job.draft.target.dropFirst("generation:".count)),
              try generation(id: generationId)?.notebookId == notebookId else { throw StorageV19Error.notebookMismatch }
        try discardBuildingGeneration(id: generationId, now: now)
    }

    /// The live owner's selection changed: cancel it with `embeddingSelectionChanged`
    /// and fail its building generation. A stale owner changes nothing.
    public func invalidateEmbeddingSelection(fence: JobFence, now: Int64) throws -> Bool {
        let notebookId = try dbQueue.write { try IngestionGenerationSQL.invalidate($0, fence: fence, now: now) }
        if let notebookId { notifyFolderIngestionChanged(notebookId: notebookId) }
        return notebookId != nil
    }

    /// Fenced embed failure; the fifth (terminal) failure also fails the building generation.
    public func failEmbeddingJob(fence: JobFence, error: String, now: Int64) throws -> Bool {
        let notebookId = try dbQueue.write { db -> Int64? in
            guard let job = try RevisionJobSQL.validateFence(db, fence: fence, now: now), job.draft.kind == "embed",
                  try RevisionJobSQL.failJob(db, fence: fence, error: error, now: now) else { return nil }
            let generation = try IngestionGenerationSQL.generationTarget(db, job: job)
            if job.attempts >= 5, let generation, generation.state == "building" {
                try db.execute(sql: "UPDATE index_generations SET state='failed' WHERE id=? AND state='building'", arguments: [generation.id])
            }
            return try IngestionGenerationSQL.notebookId(db, job: job)
        }
        if let notebookId { notifyFolderIngestionChanged(notebookId: notebookId) }
        return notebookId != nil
    }

    /// An empty corpus completes the bootstrap job without a generation.
    public func completeEmptyBootstrap(fence: JobFence, now: Int64) throws -> Bool {
        let notebookId = try dbQueue.write { db -> Int64? in
            guard let job = try RevisionJobSQL.validateFence(db, fence: fence, now: now), job.draft.kind == "embed",
                  job.draft.target.hasPrefix("notebook:"), try RevisionJobSQL.completeJob(db, fence: fence, now: now) else { return nil }
            return try IngestionGenerationSQL.notebookId(db, job: job)
        }
        if let notebookId { notifyIndexingStatusChanged(notebookId: notebookId) }
        return notebookId != nil
    }

    public func generationProgress(notebookId: Int64) throws -> GenerationProgress {
        try dbQueue.read { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM notebooks WHERE id=?", arguments: [notebookId]) != nil else {
                throw StorageV19Error.notFound
            }
            let active = try GenerationSQL.activeGeneration(db, notebookId: notebookId)
            let latest = try Int64.fetchOne(db, sql: """
                SELECT id FROM index_generations WHERE notebook_id=? AND state IN ('building','failed') AND id>? ORDER BY id DESC LIMIT 1
                """, arguments: [notebookId, active?.id ?? 0]).flatMap { try GenerationSQL.generation(db, id: $0) }
            // The same job as the indexing status (`indexing-status-v1` §8).
            let selected = try IndexingStatusSQL.statusJob(db, notebookId: notebookId)
            let jobId = selected?.job.id
            let jobState = selected?.job.state
            let jobError = selected?.job.error
            let jobUnfinished = jobState.map { ["queued", "running", "paused"].contains($0) } ?? false
            var done = 0, total = 0, excluded = 0
            if let latest {
                for row in try Row.fetchAll(db, sql: "SELECT state,count(*) AS n FROM index_generation_manifest WHERE generation_id=? GROUP BY state",
                                            arguments: [latest.id]) {
                    let n: Int = row["n"], state: String = row["state"]
                    total += n
                    if state == "done" { done = n }
                    if state == "excluded" { excluded = n }
                }
            }
            let terminalJob = jobState == "failed" && selected?.job.nextRetryAt == nil
            let copied = try latest.map { try IngestionGenerationSQL.copiedCount(db, generationId: $0.id) } ?? 0
            return GenerationProgress(generationId: latest?.id, done: done, total: total, excluded: excluded,
                failed: latest?.state == "failed" || terminalJob, pausedForChat: false, hasActive: active != nil,
                jobId: jobId, preparing: jobUnfinished && selected?.bootstrap == true,
                errorCode: jobUnfinished ? nil : jobError, copied: copied)
        }
    }
}

extension IngestionGenerationSQL {
    static func item(_ row: Row) -> EmbeddingBatchItem {
        EmbeddingBatchItem(chunkId: row["id"], sourceId: row["source_id"], revisionId: row["revision_id"], text: row["text"])
    }

    static func isFresh(_ db: Database, chunkId: Int64, revisionId: Int64) throws -> Bool {
        try Bool.fetchOne(db.cachedStatement(sql: """
            SELECT EXISTS(SELECT 1 FROM source_chunks c JOIN sources s ON s.id=c.source_id
                WHERE c.id=? AND c.revision_id=? AND s.published_revision_id=c.revision_id
                  AND s.availability='present' AND s.eligible=1)
            """), arguments: [chunkId, revisionId]) == true
    }

    /// Stores only members whose chunk, captured revision, manifest revision and
    /// published revision still agree. The WP3 kernel validates dims and norm.
    /// Every stored vector gets a dedup ledger row (`copied = 0`).
    static func store(_ db: Database, generation: IndexGeneration, chunkIds: [Int64], revisionIds: [Int64], vectors: [[Float]]) throws {
        for index in chunkIds.indices {
            guard try isMember(db, generationId: generation.id, chunkId: chunkIds[index], revisionId: revisionIds[index]) else { continue }
            try GenerationSQL.storeEmbedding(db, building: generation, chunkId: chunkIds[index],
                                             vector: EmbeddingVector(values: vectors[index]))
            guard let text = try String.fetchOne(db.cachedStatement(sql: "SELECT text FROM source_chunks WHERE id=?"),
                                                 arguments: [chunkIds[index]]) else { continue }
            try recordHash(db, generationId: generation.id, chunkId: chunkIds[index], text: text, copied: false)
        }
    }

    /// A captured chunk that is still fresh and a member of the generation at its captured revision.
    static func isMember(_ db: Database, generationId: Int64, chunkId: Int64, revisionId: Int64) throws -> Bool {
        try isFresh(db, chunkId: chunkId, revisionId: revisionId)
            && Int.fetchOne(db.cachedStatement(sql: """
                SELECT 1 FROM index_generation_manifest m JOIN source_chunks c ON c.source_id=m.source_id
                WHERE m.generation_id=? AND c.id=? AND m.revision_id=?
                """), arguments: [generationId, chunkId, revisionId]) != nil
    }

    /// Joined same-text chunks copy the committed input's vector bytes; stale members are skipped.
    static func storeDuplicates(_ db: Database, generation: IndexGeneration, duplicates: [EmbeddingDuplicate]) throws {
        for duplicate in duplicates {
            guard try isMember(db, generationId: generation.id, chunkId: duplicate.chunkId, revisionId: duplicate.revisionId),
                  let text = try String.fetchOne(db.cachedStatement(sql: "SELECT text FROM source_chunks WHERE id=?"),
                                                 arguments: [duplicate.chunkId]),
                  let original = try String.fetchOne(db.cachedStatement(sql: "SELECT text FROM source_chunks WHERE id=?"),
                                                     arguments: [duplicate.ofChunkId]),
                  original.utf8.elementsEqual(text.utf8) else { continue }
            try copyVector(db, generationId: generation.id, from: duplicate.ofChunkId, to: duplicate.chunkId, text: text)
        }
    }

    static func recordHash(_ db: Database, generationId: Int64, chunkId: Int64, text: String, copied: Bool) throws {
        try db.cachedStatement(sql: """
            INSERT OR REPLACE INTO generation_text_hashes(generation_id,chunk_id,text_hash,copied) VALUES (?,?,?,?)
            """).execute(arguments: [generationId, chunkId, EmbeddingPlan.textHash(text), copied ? 1 : 0])
    }

    /// Byte-for-byte copy of an existing vector of the generation; false when `from` has none.
    @discardableResult
    static func copyVector(_ db: Database, generationId: Int64, from: Int64, to: Int64, text: String) throws -> Bool {
        try db.cachedStatement(sql: """
            INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding)
            SELECT ?,generation_id,embedding FROM chunk_embeddings WHERE chunk_id=? AND generation_id=?
            ON CONFLICT(chunk_id,generation_id) DO NOTHING
            """).execute(arguments: [to, from, generationId])
        guard db.changesCount == 1 else { return false }
        try recordHash(db, generationId: generationId, chunkId: to, text: text, copied: true)
        return true
    }

    /// Dedup rule 1: the exact text already has a vector in the generation → copy it now.
    static func copyExistingVector(_ db: Database, generationId: Int64, chunkId: Int64, text: String) throws -> Bool {
        guard let from = try Int64.fetchOne(db.cachedStatement(sql: existingVectorSQL),
                                            arguments: [generationId, EmbeddingPlan.textHash(text), text]) else { return false }
        return try copyVector(db, generationId: generationId, from: from, to: chunkId, text: text)
    }

    /// Ledger lookup by hash, verified by exact text and an existing vector.
    static let existingVectorSQL = """
        SELECT d.chunk_id FROM generation_text_hashes d
        JOIN chunk_embeddings e ON e.chunk_id=d.chunk_id AND e.generation_id=d.generation_id
        JOIN source_chunks c ON c.id=d.chunk_id
        WHERE d.generation_id=? AND d.text_hash=? AND c.text=? LIMIT 1
        """

    /// Dedup copies of the generation whose vector still exists.
    static func copiedCount(_ db: Database, generationId: Int64) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM generation_text_hashes d WHERE d.generation_id=? AND d.copied=1
              AND EXISTS(SELECT 1 FROM chunk_embeddings e WHERE e.chunk_id=d.chunk_id AND e.generation_id=d.generation_id)
            """, arguments: [generationId]) ?? 0
    }

    /// Reconcile, prune, mark complete; true when the manifest or the vectors changed.
    static func settle(_ db: Database, generationId: Int64) throws -> Bool {
        guard let generation = try GenerationSQL.generation(db, id: generationId), generation.state == "building" else { return false }
        let before = db.totalChangesCount
        try GenerationSQL.reconcile(db, generationId: generationId)
        try pruneStaleVectors(db, generationId: generationId)
        let changed = db.totalChangesCount != before
        try markComplete(db, generation: generation)
        return changed
    }

    struct Candidate {
        let item: EmbeddingBatchItem
        let cursor: EmbeddingCursor
    }

    /// Pending embeddable chunks of one priority class strictly after `after`, in
    /// (source, ord) order. Keyset on the manifest primary key: finished sources
    /// before the cursor are never read again.
    static func candidates(_ db: Database, generationId: Int64, priorityClass: Int, after: EmbeddingCursor?,
                           limit: Int) throws -> [Candidate] {
        try Row.fetchAll(db.cachedStatement(sql: candidatesSQL),
                         arguments: [generationId, after?.sourceId ?? 0, priorityClass, after?.ord ?? -1, limit]).map { row in
            Candidate(item: item(row), cursor: EmbeddingCursor(priorityClass: priorityClass, sourceId: row["source_id"], ord: row["ord"]))
        }
    }

    static let candidatesSQL = """
        SELECT c.id,c.source_id,c.revision_id,c.ord,c.text FROM index_generation_manifest m
        JOIN sources s ON s.id=m.source_id
        JOIN source_chunks c ON c.revision_id=m.revision_id AND c.source_id=m.source_id
        WHERE m.generation_id=?1 AND m.source_id>=?2 AND m.state='pending' AND s.availability='present' AND s.eligible=1
          AND s.published_revision_id=m.revision_id AND \(EmbeddingPlan.classSQL())=?3
          AND (m.source_id>?2 OR c.ord>?4) AND \(EmbeddingPlan.embeddableSQL())
          AND NOT EXISTS(SELECT 1 FROM chunk_embeddings e WHERE e.chunk_id=c.id AND e.generation_id=m.generation_id)
        ORDER BY m.source_id,c.ord LIMIT ?5
        """

    /// Pending rows whose published revision has a vector for every embeddable
    /// chunk become done; an empty published revision is done with zero vectors.
    static func markComplete(_ db: Database, generation: IndexGeneration) throws {
        let complete = try Row.fetchAll(db, sql: """
            SELECT m.source_id,m.revision_id FROM index_generation_manifest m JOIN sources s ON s.id=m.source_id
            WHERE m.generation_id=? AND m.state='pending' AND s.published_revision_id=m.revision_id
              AND NOT EXISTS(SELECT 1 FROM source_chunks c LEFT JOIN chunk_embeddings e ON e.chunk_id=c.id AND e.generation_id=m.generation_id
                             WHERE c.revision_id=m.revision_id AND \(EmbeddingPlan.embeddableSQL())
                               AND (e.chunk_id IS NULL OR length(e.embedding)<>?))
            """, arguments: [generation.id, generation.identity.dims * MemoryLayout<Float>.size])
        guard !complete.isEmpty else { return }
        try GenerationSQL.setManifest(db, generationId: generation.id, entries: complete.map {
            ManifestEntry(sourceId: $0["source_id"], revisionId: $0["revision_id"], state: "done", reason: nil)
        })
    }

    static func generationTarget(_ db: Database, job: IngestJob) throws -> IndexGeneration? {
        guard job.draft.target.hasPrefix("generation:"), let id = Int64(job.draft.target.dropFirst("generation:".count)) else { return nil }
        return try GenerationSQL.generation(db, id: id)
    }

    static func notebookId(_ db: Database, job: IngestJob) throws -> Int64? {
        if job.draft.target.hasPrefix("notebook:") { return Int64(job.draft.target.dropFirst("notebook:".count)) }
        return try generationTarget(db, job: job)?.notebookId
    }

    static func invalidate(_ db: Database, fence: JobFence, now: Int64) throws -> Int64? {
        guard let job = try RevisionJobSQL.validateFence(db, fence: fence, now: now), job.draft.kind == "embed" else { return nil }
        try db.execute(sql: """
            UPDATE ingest_jobs SET state='cancelled',error='embeddingSelectionChanged',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
            WHERE id=? AND state='running' AND lease_token=? AND lease_until>?
            """, arguments: [fence.jobId, fence.leaseToken, now])
        guard db.changesCount == 1 else { return nil }
        if let generation = try generationTarget(db, job: job), generation.state == "building" {
            try db.execute(sql: "UPDATE index_generations SET state='failed' WHERE id=? AND state='building'", arguments: [generation.id])
        }
        return try notebookId(db, job: job)
    }
}

extension NotebookStore {
    /// Runtime start / reconcile (`ingestion-build-merge-v1` §4): an unclaimed incremental bootstrap of
    /// a space that already has a building (or current active) generation joins that generation's job
    /// or completes as a no-op, so it never builds a second generation. Returns the bootstraps resolved.
    @discardableResult
    func mergeRedundantBootstraps(now: Int64) throws -> Int {
        let (count, notebooks) = try dbQueue.write { db -> (Int, Set<Int64>) in
            var count = 0, notebooks = Set<Int64>()
            let candidates = try Row.fetchAll(db, sql: """
                SELECT id,target,state,attempts,next_retry_at,error,options_json FROM ingest_jobs
                WHERE kind='embed' AND target LIKE 'notebook:%' AND (state IN ('queued','paused')
                    OR (state='failed' AND attempts<5 AND next_retry_at IS NOT NULL)) ORDER BY id
                """).map(IndexingStatusSQL.embedJobSnapshot)
            for candidate in candidates {
                // An earlier merge of this pass may already have superseded it.
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT id,target,state,attempts,next_retry_at,error,options_json FROM ingest_jobs WHERE id=?
                    """, arguments: [candidate.id]), let notebookId = Int64(candidate.target.dropFirst("notebook:".count)) else { continue }
                let job = IndexingStatusSQL.embedJobSnapshot(row)
                let action = EmbedJobPlanning.startup(job: job,
                    generations: try IndexingStatusSQL.generationSnapshots(db, notebookId: notebookId),
                    needsEmbedding: try IndexingStatusSQL.needsEmbedding(db, notebookId: notebookId))
                switch action {
                case .keep: continue
                case .merge:
                    guard let selection = job.incrementalSelection else { continue }
                    _ = try IngestionGenerationSQL.enqueueBuild(db, notebookId: notebookId, selection: selection,
                                                                copyExisting: true, now: now)
                    try IngestionGenerationSQL.completeBootstraps(db, ids: [job.id])
                case .noop:
                    try IngestionGenerationSQL.completeBootstraps(db, ids: [job.id])
                }
                count += 1
                notebooks.insert(notebookId)
            }
            return (count, notebooks)
        }
        for notebookId in notebooks.sorted() { notifyFolderIngestionChanged(notebookId: notebookId) }
        return count
    }
}

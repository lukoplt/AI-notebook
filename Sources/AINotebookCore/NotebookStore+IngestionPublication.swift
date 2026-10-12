import Foundation
import GRDB

extension EmbeddingSelection {
    /// Nonsecret job options with explicit nulls; never contains credentials.
    func optionsJSON(copyExisting: Bool) throws -> String {
        let selection: [String: Any] = [
            "providerId": providerId, "endpointRevision": endpointRevision, "model": model,
            "modelDigest": modelDigest ?? NSNull(), "dims": dims ?? NSNull(), "normalization": normalization,
            "queryFormatVersion": queryFormatVersion, "docFormatVersion": docFormatVersion, "chunkerVersion": chunkerVersion]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["copyExisting": copyExisting, "selection": selection],
                                                           options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    /// Only a selection with verified dimensions has a generation identity.
    var identity: GenerationIdentity? {
        guard let dims, dims > 0 else { return nil }
        return GenerationIdentity(providerId: providerId, endpointRevision: endpointRevision, model: model,
                                  modelDigest: modelDigest, dims: dims, normalization: normalization,
                                  queryFormatVersion: queryFormatVersion, docFormatVersion: docFormatVersion,
                                  chunkerVersion: chunkerVersion)
    }
}

extension NotebookStore {
    /// Publishes one extracted revision in a single fenced transaction: revision,
    /// chunks, immutable page map, source metadata and the generation embed job
    /// commit together or not at all. Returns nil (changing nothing except
    /// cancelling a superseded owner) when the fence, pointer, observation or
    /// rules no longer match.
    public func publishFolderExtraction(request: ExtractionRequest, draft: RevisionDraft,
                                        chunks: [RevisionChunkDraft], metadata: PublicationMetadata,
                                        embeddingSelection: EmbeddingSelection?,
                                        fence: JobFence, now: Int64) throws -> SourceRevision? {
        try publishFolderExtraction(request: request, draft: draft, chunks: chunks, metadata: metadata,
                                    embeddingSelection: embeddingSelection, fence: fence, now: now, fault: { _ in })
    }

    /// `fault` is a test seam invoked at named points inside the transaction.
    func publishFolderExtraction(request: ExtractionRequest, draft: RevisionDraft,
                                 chunks: [RevisionChunkDraft], metadata: PublicationMetadata,
                                 embeddingSelection: EmbeddingSelection?, fence: JobFence, now: Int64,
                                 fault: (String) throws -> Void) throws -> SourceRevision? {
        let result = try dbQueue.write { db -> (SourceRevision?, Int64?) in
            try IngestionPublicationSQL.publish(db, request: request, draft: draft, chunks: chunks, metadata: metadata,
                                                selection: embeddingSelection, fence: fence, now: now, fault: fault)
        }
        if let notebookId = result.1 { notifyFolderIngestionChanged(notebookId: notebookId) }
        return result.0
    }

    /// Changed-during-extraction: cancels only this live owner and queues fresh
    /// expected-current work. An expired or replaced owner creates nothing.
    public func requestFreshExtraction(sourceId: Int64, fence: JobFence, now: Int64) throws -> Bool {
        let notebookId = try dbQueue.write { db -> Int64? in
            guard let job = try RevisionJobSQL.validateFence(db, fence: fence, now: now),
                  job.draft.kind == "extract", job.draft.target == "source:\(sourceId)",
                  let source = try Row.fetchOne(db, sql: "SELECT notebook_id,current_revision FROM sources WHERE id=?",
                                                arguments: [sourceId]) else { return nil }
            guard try RevisionJobSQL.cancelJob(db, fence: fence, now: now) else { return nil }
            _ = try FolderIngestionSQL.enqueueDue(db, draft: IngestJobDraft(kind: "extract", target: "source:\(sourceId)",
                targetRevision: source["current_revision"]), now: now)
            try db.execute(sql: "UPDATE sources SET status='pending',error=NULL WHERE id=?", arguments: [sourceId])
            return source["notebook_id"]
        }
        guard let notebookId else { return false }
        notifyFolderIngestionChanged(notebookId: notebookId)
        return true
    }

    /// Loose (non-folder) publication: same fenced revision/chunks/page-map/
    /// metadata/embed-job transaction as folder publication, without the
    /// folder stat and rule checks. Lease and current-pointer checks remain.
    public func publishLooseExtraction(sourceId: Int64, draft: RevisionDraft, chunks: [RevisionChunkDraft],
                                      metadata: PublicationMetadata, embeddingSelection: EmbeddingSelection?,
                                      fence: JobFence, now: Int64) throws -> SourceRevision? {
        let result = try dbQueue.write { db -> (SourceRevision?, Int64?) in
            try IngestionPublicationSQL.publishLoose(db, sourceId: sourceId, draft: draft, chunks: chunks, metadata: metadata,
                                                     selection: embeddingSelection, fence: fence, now: now)
        }
        if let notebookId = result.1 { notifyFolderIngestionChanged(notebookId: notebookId) }
        return result.0
    }

    /// A folder source's re-ingest: queue durable extraction of the current
    /// pointer (coalesced), never opening the path directly.
    @discardableResult
    public func requestSourceExtraction(sourceId: Int64, now: Int64) throws -> Bool {
        let notebookId = try dbQueue.write { db -> Int64? in
            guard let notebook = try Int64.fetchOne(db, sql: "SELECT notebook_id FROM sources WHERE id=?", arguments: [sourceId]) else {
                throw StorageV19Error.notFound
            }
            // An explicit re-ingest is a user retry: a spent failure budget starts over.
            try RetryBudgetSQL.resetIfGaveUp(db, sourceId: sourceId)
            try FolderIngestionSQL.requireExtraction(db, sourceId: sourceId, keepRunning: true, now: now)
            return notebook
        }
        if let notebookId { notifyFolderIngestionChanged(notebookId: notebookId) }
        return notebookId != nil
    }

    /// Chat bridge for the legacy retriever: `.all` → nil (whole notebook);
    /// a selection → its live present/eligible members (explicit sources plus
    /// current folder members), possibly empty. Evaluated per turn.
    func chatSourceIds(notebookId: Int64, scope: RetrievalScope) throws -> Set<Int64>? {
        guard case let .selection(sourceIds, folderIds) = scope else { return nil }
        guard !sourceIds.isEmpty || !folderIds.isEmpty else { return [] }
        let sources = sourceIds.sorted(), folders = folderIds.sorted()
        let sourceList = sources.isEmpty ? "NULL" : sources.map { _ in "?" }.joined(separator: ",")
        let folderList = folders.isEmpty ? "NULL" : folders.map { _ in "?" }.joined(separator: ",")
        var arguments: StatementArguments = [notebookId]
        arguments += StatementArguments(sources)
        arguments += StatementArguments(folders)
        return try dbQueue.read { db in
            Set(try Int64.fetchAll(db, sql: """
                SELECT id FROM sources WHERE notebook_id=? AND availability='present' AND eligible=1
                  AND (id IN (\(sourceList)) OR folder_id IN (\(folderList)))
                """, arguments: arguments))
        }
    }

    /// Cancels unfinished scan jobs of the folder and extraction jobs of its sources.
    func cancelFolderWork(folderId: Int64, now: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE ingest_jobs SET state='cancelled',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
                WHERE ((kind='scan' AND target=?) OR (kind='extract' AND target IN
                    (SELECT 'source:'||id FROM sources WHERE folder_id=?)))
                  AND (state IN ('queued','running','paused') OR (state='failed' AND next_retry_at IS NOT NULL))
                """, arguments: ["folder:\(folderId)", folderId])
        }
    }

    func folderHasPendingWork(folderId: Int64) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM ingest_jobs WHERE ((kind='scan' AND target=?) OR (kind='extract' AND target IN
                    (SELECT 'source:'||id FROM sources WHERE folder_id=?)))
                  AND state IN ('queued','running','paused'))
                """, arguments: ["folder:\(folderId)", folderId]) == true
        }
    }

    /// sourceId → published revision for one folder.
    func folderPublications(folderId: Int64) throws -> [Int64: Int64?] {
        try dbQueue.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id,published_revision_id FROM sources WHERE folder_id=?",
                                                              arguments: [folderId]).map { ($0["id"] as Int64, $0["published_revision_id"] as Int64?) })
        }
    }

    /// Admission bytes for an extract job from the stored size and folder limits.
    func extractionReservation(job: IngestJob) throws -> Int64 {
        guard job.draft.kind == "extract", let sourceId = Int64(job.draft.target.dropFirst("source:".count)) else { return 0 }
        return try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT type,folder_id,size_bytes FROM sources WHERE id=?", arguments: [sourceId]) else { return 0 }
            let folderId: Int64? = row["folder_id"]
            // An unparsable folder limits document reserves the defaults (as on Windows) instead of throwing:
            // a throwing reservation would stall the queue head (ingestion-memory-pressure-v1 §5).
            let limits = folderId.flatMap { try? FolderIngestionSQL.folder(db, id: $0) }.flatMap { try? $0.rules.limits } ?? .defaults
            let type = SourceType(rawValue: row["type"]) ?? .text
            return IngestionAdmission.reservation(kind: type, fileBytes: row["size_bytes"] ?? limits.fileBytes, limits: limits)
        }
    }

    /// True when an eligible published revision is not yet done in the active generation.
    func notebookNeedsEmbedding(notebookId: Int64) throws -> Bool {
        try dbQueue.read { try IndexingStatusSQL.needsEmbedding($0, notebookId: notebookId) }
    }

    /// A fenced gc job runs the WP3 retention kernel for its generation's notebook.
    func runGarbageCollection(job: IngestJob, fence: JobFence, now: Int64) throws {
        guard let generationId = Int64(job.draft.target.dropFirst("generation:".count)),
              let notebookId = try generation(id: generationId)?.notebookId,
              try dbQueue.read({ try RevisionJobSQL.validateFence($0, fence: fence, now: now) }) != nil else { return }
        _ = try garbageCollect(notebookId: notebookId)
        _ = try completeJob(fence: fence, now: now)
    }

    /// Cancels the owned extraction of a source that is gone, ineligible or
    /// unavailable; nothing is published.
    func cancelOwnedExtraction(fence: JobFence, now: Int64) throws -> Bool {
        let (cancelled, notebookId) = try dbQueue.write { db -> (Bool, Int64?) in
            let job = try RevisionJobSQL.job(db, id: fence.jobId)
            guard try RevisionJobSQL.cancelJob(db, fence: fence, now: now) else { return (false, nil) }
            return (true, try job.flatMap { try RevisionJobSQL.notebookId(db, draft: $0.draft) })
        }
        if let notebookId { notifyIndexingStatusChanged(notebookId: notebookId) }
        return cancelled
    }
}

enum IngestionGenerationSQL {
    /// Reuses an identical building generation for incremental ingestion. An
    /// explicit reindex (`copyExisting=false`) always starts fresh and retires
    /// earlier building work of that identity. Vectors are copied only between
    /// identical identities and identical manifest revisions. No IO.
    static func ensureBuilding(_ db: Database, notebookId: Int64, identity: GenerationIdentity,
                               copyExisting: Bool, now: Int64) throws -> IndexGeneration {
        let building = try Int64.fetchAll(db, sql: """
            SELECT id FROM index_generations WHERE notebook_id=? AND state='building' ORDER BY id DESC
            """, arguments: [notebookId]).compactMap { try GenerationSQL.generation(db, id: $0) }
            .filter { $0.identity == identity }
        if copyExisting, let reusable = building.first {
            try GenerationSQL.reconcile(db, generationId: reusable.id)
            try pruneStaleVectors(db, generationId: reusable.id)
            return reusable
        }
        if !copyExisting {
            for old in building { try GenerationSQL.retire(db, id: old.id) }
        }
        let created = try GenerationSQL.create(db, notebookId: notebookId, identity: identity, now: now)
        if copyExisting, let active = try GenerationSQL.activeGeneration(db, notebookId: notebookId),
           active.identity == identity {
            try GenerationSQL.copyUnchangedVectors(db, from: active.id, to: created.id, excludingChunkId: nil)
        }
        return created
    }

    /// A building generation never keeps vectors of a revision its manifest no
    /// longer names: a changed revision cannot lend vectors to replacement chunks.
    static func pruneStaleVectors(_ db: Database, generationId: Int64) throws {
        try db.execute(sql: pruneStaleVectorsSQL, arguments: [generationId])
    }

    /// Runs before every background batch, so it must stay proportional to the
    /// manifest: a source's chunks are reached only through its other revisions
    /// (`source_revisions(source_id,…)` → `idx_chunks_revision_ord`) plus
    /// revision-less legacy chunks, never by reading every chunk row of every
    /// manifest source. Same set as `c.source_id=m.source_id AND
    /// c.revision_id IS NOT m.revision_id`: a chunk's revision always belongs to its source.
    static let pruneStaleVectorsSQL = """
        DELETE FROM chunk_embeddings WHERE generation_id=?1 AND chunk_id IN (
            SELECT c.id FROM index_generation_manifest m
            JOIN source_revisions r ON r.source_id=m.source_id AND r.id<>m.revision_id
            JOIN source_chunks c ON c.revision_id=r.id
            WHERE m.generation_id=?1
            UNION ALL
            SELECT c.id FROM source_chunks c
            JOIN index_generation_manifest m ON m.generation_id=?1 AND m.source_id=c.source_id
            WHERE c.revision_id IS NULL)
        """

    /// Queues the build for a selection and returns its job ID. Verified
    /// dimensions target a (reused or fresh) building generation; unknown
    /// dimensions adopt the identity of a building/active generation of the
    /// same space (`ingestion-build-merge-v1` §2), else queue one notebook-target
    /// bootstrap job whose first real corpus batch discovers them. Never infers
    /// dimensions from a model name. A generation job supersedes the unclaimed
    /// incremental bootstraps of its space (§3).
    static func enqueueBuild(_ db: Database, notebookId: Int64, selection requested: EmbeddingSelection,
                             copyExisting: Bool, now: Int64) throws -> Int64 {
        var selection = requested
        if let adopted = EmbedJobPlanning.resolveBuild(selection: requested, copyExisting: copyExisting,
                generations: try IndexingStatusSQL.generationSnapshots(db, notebookId: notebookId)) {
            selection = EmbeddingSelection(identity: adopted.identity)
        }
        let options = try selection.optionsJSON(copyExisting: copyExisting)
        if let identity = selection.identity {
            let generation = try ensureBuilding(db, notebookId: notebookId, identity: identity, copyExisting: copyExisting, now: now)
            let jobId = try enqueueEmbed(db, target: "generation:\(generation.id)", optionsJSON: options, now: now)
            let bootstraps = try Row.fetchAll(db, sql: """
                SELECT id,target,state,attempts,next_retry_at,error,options_json FROM ingest_jobs
                WHERE kind='embed' AND target=? AND state IN ('queued','paused','failed') ORDER BY id
                """, arguments: ["notebook:\(notebookId)"]).map(IndexingStatusSQL.embedJobSnapshot)
            try completeBootstraps(db, ids: EmbedJobPlanning.superseded(identity: identity, jobs: bootstraps))
            return jobId
        }
        return try enqueueEmbed(db, target: "notebook:\(notebookId)", optionsJSON: options, now: now)
    }

    /// Completes unclaimed bootstraps as no-ops (`ingestion-build-merge-v1` §3); a claimed job is never touched.
    static func completeBootstraps(_ db: Database, ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try db.execute(sql: """
            UPDATE ingest_jobs SET state='done',error=NULL,next_retry_at=NULL,lease_until=NULL,lease_token=NULL
            WHERE kind='embed' AND target LIKE 'notebook:%' AND state<>'running' AND id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
            """, arguments: StatementArguments(ids))
    }

    /// Queues one embed job unless an unfinished one already covers the target:
    /// any job of the same generation (a running job keeps picking up new
    /// pending manifest rows), or a bootstrap job with identical options.
    @discardableResult
    static func enqueueEmbed(_ db: Database, target: String, optionsJSON: String, now: Int64) throws -> Int64 {
        if let existing = try Int64.fetchOne(db, sql: """
            SELECT id FROM ingest_jobs WHERE kind='embed' AND target=?
                AND (target LIKE 'generation:%' OR options_json=?)
                AND state IN ('queued','paused','running') ORDER BY id LIMIT 1
            """, arguments: [target, optionsJSON]) {
            return existing
        }
        return try FolderIngestionSQL.enqueueDue(db, draft: IngestJobDraft(kind: "embed", target: target, targetRevision: nil,
                                                                          optionsJSON: optionsJSON), now: now)
    }
}

enum IngestionPublicationSQL {
    static func publishLoose(_ db: Database, sourceId: Int64, draft: RevisionDraft, chunks: [RevisionChunkDraft],
                             metadata: PublicationMetadata, selection: EmbeddingSelection?, fence: JobFence,
                             now: Int64) throws -> (SourceRevision?, Int64?) {
        guard let job = try RevisionJobSQL.validateFence(db, fence: fence, now: now),
              job.draft.kind == "extract", job.draft.target == "source:\(sourceId)",
              let notebookId = try Int64.fetchOne(db, sql: "SELECT notebook_id FROM sources WHERE id=?", arguments: [sourceId]) else {
            return (nil, nil)
        }
        try validatePages(metadata.pages, text: draft.canonicalText)
        guard let revision = try RevisionJobSQL.commitExtraction(db, sourceId: sourceId, draft: draft, chunks: chunks,
                                                                 fence: fence, now: now) else { return (nil, nil) }
        try insertPages(db, revisionId: revision.id, pages: metadata.pages)
        try db.execute(sql: "UPDATE sources SET encoding=?,lang=?,lang_coverage=?,descriptor=? WHERE id=?",
                       arguments: [metadata.encoding, metadata.lang, metadata.coverageJSON, metadata.descriptorJSON, sourceId])
        if let selection {
            _ = try IngestionGenerationSQL.enqueueBuild(db, notebookId: notebookId, selection: selection, copyExisting: true, now: now)
        }
        return (revision, notebookId)
    }

    static func validatePages(_ pages: [PageBoundary], text: String) throws {
        let scalarCount = text.unicodeScalars.count
        var previousEnd = 0
        for (index, page) in pages.enumerated() {
            guard page.page == index + 1, page.start >= previousEnd, page.start <= page.end, page.end <= scalarCount else {
                throw StorageV19Error.invalidSpan
            }
            previousEnd = page.end
        }
    }

    static func insertPages(_ db: Database, revisionId: Int64, pages: [PageBoundary]) throws {
        let insert = try db.makeStatement(sql: "INSERT INTO revision_pages(revision_id,page,char_start,char_end) VALUES(?,?,?,?)")
        for page in pages { try insert.execute(arguments: [revisionId, page.page, page.start, page.end]) }
    }

    static func publish(_ db: Database, request: ExtractionRequest, draft: RevisionDraft, chunks: [RevisionChunkDraft],
                        metadata: PublicationMetadata, selection: EmbeddingSelection?, fence: JobFence, now: Int64,
                        fault: (String) throws -> Void) throws -> (SourceRevision?, Int64?) {
        guard let job = try RevisionJobSQL.validateFence(db, fence: fence, now: now),
              job.draft.kind == "extract", job.draft.target == "source:\(request.sourceId)" else { return (nil, nil) }
        guard let source = try Row.fetchOne(db, sql: """
            SELECT notebook_id,folder_id,rel_path,availability,eligible,mtime,size_bytes,current_revision FROM sources WHERE id=?
            """, arguments: [request.sourceId]) else {
            _ = try RevisionJobSQL.cancelJob(db, fence: fence, now: now)
            return (nil, nil)
        }
        let notebookId: Int64 = source["notebook_id"]
        let folderId: Int64? = source["folder_id"]
        let relPath: String? = source["rel_path"]
        let availability: String = source["availability"]
        let eligible: Bool = source["eligible"]
        let mtime: Int64? = source["mtime"]
        let size: Int64? = source["size_bytes"]
        let folderRules = try folderId.flatMap { try? FolderIngestionSQL.folder(db, id: $0) }.map { try $0.rules }
        let current: Int64? = source["current_revision"]
        // Every precondition is checked before the first write; a superseded owner is cancelled.
        guard folderId == request.folderId, relPath.map({ $0.utf8.elementsEqual(request.relPath.utf8) }) == true,
              availability == "present", eligible, current == job.draft.targetRevision,
              mtime == request.stamp.mtimeNs, size == request.stamp.sizeBytes,
              let folderRules, folderRules == request.rules else {
            _ = try RevisionJobSQL.cancelJob(db, fence: fence, now: now)
            return (nil, notebookId)
        }
        try validatePages(metadata.pages, text: draft.canonicalText)
        guard let revision = try RevisionJobSQL.commitExtraction(db, sourceId: request.sourceId, draft: draft,
                                                                 chunks: chunks, fence: fence, now: now) else {
            return (nil, nil)
        }
        try insertPages(db, revisionId: revision.id, pages: metadata.pages)
        let descriptor = try? JSONDecoder().decode(SourceDescriptor.self, from: Data(metadata.descriptorJSON.utf8))
        guard let descriptor else { throw StorageV19Error.invalidValue }
        try db.execute(sql: """
            UPDATE sources SET mtime=?,size_bytes=?,encoding=?,lang=?,lang_coverage=?,descriptor=?,title=? WHERE id=?
            """, arguments: [request.stamp.mtimeNs, request.stamp.sizeBytes, metadata.encoding, metadata.lang,
                              metadata.coverageJSON, metadata.descriptorJSON, descriptor.title, request.sourceId])
        try fault("after-metadata")
        if let selection {
            _ = try IngestionGenerationSQL.enqueueBuild(db, notebookId: notebookId, selection: selection,
                                                        copyExisting: true, now: now)
            try fault("after-embed-enqueue")
        }
        return (revision, notebookId)
    }
}

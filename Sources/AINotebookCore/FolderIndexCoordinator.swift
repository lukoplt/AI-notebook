import Foundation

/// Response-shape validation before any vector reaches the store.
func validatedDimensions(_ vectors: [[Float]], count: Int) throws -> Int {
    guard vectors.count == count, let dims = vectors.first?.count, dims > 0,
          vectors.allSatisfy({ $0.count == dims && $0.allSatisfy(\.isFinite)
              && $0.contains(where: { $0 != 0 }) }) else {
        throw IngestionError(code: "invalidVector")
    }
    return dims
}

/// A batch captured for one provider call, with explicit chunk/revision identity.
struct CapturedEmbeddingBatch: Sendable, Equatable {
    let notebookId: Int64
    /// nil for a dimension-discovery (bootstrap) batch.
    let generationId: Int64?
    /// Unique provider inputs.
    let items: [EmbeddingBatchItem]
    /// Same-text chunks that receive an input's vector at commit (`embedding-plan-v1` §5).
    var duplicates: [EmbeddingDuplicate] = []
    var chunkIds: [Int64] { items.map(\.chunkId) }
    var revisionIds: [Int64] { items.map(\.revisionId) }
    var inputs: [String] { items.map(\.text) }
}

enum EmbeddingBatchOutcome: Equatable, Sendable {
    case committed
    case bootstrapped(Int64)
    case stale
    case failed(String)
    case invalidated
}

/// Builds replacement generations beside the active one with one immutable
/// captured session per job. Every batch waits for chat admission immediately
/// before its provider call; a waiting job stays running (leases keep being
/// renewed by the queue) and its generation stays `building`.
public actor FolderIndexCoordinator {
    private let store: NotebookStore
    private let admission: IngestionAdmission
    private let clock: any IngestLeaseClock
    private let session: @Sendable (Int64) async throws -> FolderEmbeddingSession?
    private let selectedSelection: @Sendable (Int64) async throws -> EmbeddingSelection?
    private var waitingForChat: Set<Int64> = []
    private let batchSize: Int
    /// Chunks per background provider request. Larger requests amortize the
    /// per-batch store work and HTTP round trip (Ollama `/api/embed` and OpenAI
    /// embeddings both take an input array); 64 stays far below provider input limits.
    static let batchSize = 64

    public init(store: NotebookStore, admission: IngestionAdmission, clock: any IngestLeaseClock,
                session: @escaping @Sendable (Int64) async throws -> FolderEmbeddingSession?,
                selectedSelection: @escaping @Sendable (Int64) async throws -> EmbeddingSelection?) {
        self.init(store: store, admission: admission, clock: clock, session: session,
                  selectedSelection: selectedSelection, batchSize: Self.batchSize)
    }

    init(store: NotebookStore, admission: IngestionAdmission, clock: any IngestLeaseClock,
         session: @escaping @Sendable (Int64) async throws -> FolderEmbeddingSession?,
         selectedSelection: @escaping @Sendable (Int64) async throws -> EmbeddingSelection?, batchSize: Int) {
        precondition(batchSize > 0)
        self.store = store
        self.admission = admission
        self.clock = clock
        self.session = session
        self.selectedSelection = selectedSelection
        self.batchSize = batchSize
    }

    public func execute(job: IngestJob, fence: JobFence) async throws {
        guard job.draft.kind == "embed" else { throw StorageV19Error.invalidValue }
        let store = self.store, clock = self.clock
        let notebookId = try storeWork { () throws -> Int64? in
            try store.runOnDatabase { try IngestionGenerationSQL.notebookId($0, job: job) }
        }
        guard let notebookId else { return }
        let (durable, copyExisting) = try EmbeddingSelection.fromOptions(job.draft.optionsJSON)
        // Restart may reconstruct a session only if it matches the durable options.
        guard let captured = try await session(notebookId), FolderEmbeddingSession.compatible(captured.selection, durable),
              let current = try await selectedSelection(notebookId), FolderEmbeddingSession.compatible(current, durable) else {
            _ = try storeWork { try store.invalidateEmbeddingSelection(fence: fence, now: clock.now()) }
            return
        }
        var generationId: Int64? = job.draft.target.hasPrefix("generation:")
            ? Int64(job.draft.target.dropFirst("generation:".count)) : nil
        // Keyset position of the last consumed candidate (`embedding-plan-v1` §4).
        var cursor: EmbeddingCursor?
        while true {
            try Task.checkCancellation()
            let next: CapturedEmbeddingBatch?
            if let generationId {
                guard let round = try storeWork({
                    try store.captureEmbeddingRound(generationId: generationId, limit: self.batchSize, cursor: cursor,
                                                    fence: fence, now: clock.now())
                }) else { return }
                if round.items.isEmpty && round.copied == 0 {
                    // Nothing after the cursor: look once more from the start before concluding.
                    let startedAtCursor = cursor != nil && !round.reset
                    cursor = nil
                    if startedAtCursor { continue }
                    next = nil
                } else {
                    cursor = round.cursor
                    if round.items.isEmpty { continue }
                    next = CapturedEmbeddingBatch(notebookId: notebookId, generationId: generationId, items: round.items,
                        duplicates: round.joined.map { EmbeddingDuplicate(chunkId: $0.item.chunkId, revisionId: $0.item.revisionId,
                                                                          ofChunkId: round.items[$0.index].chunkId) })
                }
            } else {
                next = try await bootstrapRound(notebookId: notebookId)
            }
            guard let batch = next else {
                if let generationId {
                    guard let generation = try storeWork({ try store.generation(id: generationId) }),
                          let selected = try await selectedSelection(notebookId),
                          FolderEmbeddingSession.compatible(selected, captured.selection) else {
                        _ = try storeWork { try store.invalidateEmbeddingSelection(fence: fence, now: clock.now()) }
                        return
                    }
                    let activated = try storeWork {
                        try store.activateBuiltGeneration(id: generationId, selectedIdentity: generation.identity, fence: fence, now: clock.now())
                    }
                    if activated { return }
                    // Fenced out or the build ended: stop. New selectable pending rows: continue.
                    // Pending rows nothing can embed yet (a source whose current revision is not
                    // published) defer activation without spinning, as on Windows: the attempt
                    // ends and lease recovery or the next publication resumes the build.
                    guard try storeWork({ try store.job(id: fence.jobId)?.leaseToken == fence.leaseToken
                        && store.generation(id: generationId)?.state == "building"
                        && !store.embeddingBatch(generationId: generationId, limit: 1).isEmpty }) else { return }
                    continue
                }
                _ = try storeWork { try store.completeEmptyBootstrap(fence: fence, now: clock.now()) }
                return
            }
            let vectors: [[Float]]
            do {
                vectors = try await send(batch, session: captured)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let code = (error as? IngestionError)?.code ?? "provider-error"
                _ = try storeWork { try store.failEmbeddingJob(fence: fence, error: code, now: clock.now()) }
                return
            }
            switch try await commit(batch, vectors: vectors, session: captured, copyExisting: copyExisting, fence: fence) {
            case .committed: continue
            case .bootstrapped(let id): generationId = id
            case .stale:
                // All captured rows went stale (or the fence was lost): reselect while still owned.
                guard try storeWork({ try store.job(id: fence.jobId)?.leaseToken == fence.leaseToken }) else { return }
            case .failed, .invalidated: return
            }
        }
    }

    /// The bootstrap round (no generation yet): embeddable published chunks in build order;
    /// identical texts join one input (`embedding-plan-v1` §5 rules 2–4).
    func bootstrapRound(notebookId: Int64) async throws -> CapturedEmbeddingBatch? {
        let store = self.store, limit = batchSize
        let candidates = try storeWork {
            try store.bootstrapBatch(notebookId: notebookId, limit: EmbeddingPlan.roundScanFactor * limit)
        }
        // Keys are UTF-8 bytes: Swift String equality is canonical equivalence, dedup is exact.
        var items: [EmbeddingBatchItem] = [], inputs: [Data: Int] = [:], duplicates: [EmbeddingDuplicate] = []
        for candidate in candidates {
            if let index = inputs[Data(candidate.text.utf8)] {
                duplicates.append(EmbeddingDuplicate(chunkId: candidate.chunkId, revisionId: candidate.revisionId,
                                                     ofChunkId: items[index].chunkId))
            } else if items.count < limit {
                inputs[Data(candidate.text.utf8)] = items.count
                items.append(candidate)
            } else {
                break
            }
        }
        return items.isEmpty ? nil : CapturedEmbeddingBatch(notebookId: notebookId, generationId: nil, items: items,
                                                             duplicates: duplicates)
    }

    /// Settles the generation and captures the next batch (nil: nothing pending).
    func capture(notebookId: Int64, generationId: Int64?) async throws -> CapturedEmbeddingBatch? {
        let store = self.store
        let items = try storeWork { () throws -> [EmbeddingBatchItem] in
            if let generationId {
                try store.settleGeneration(generationId: generationId)
                return try store.embeddingBatch(generationId: generationId, limit: batchSize)
            }
            return try store.bootstrapBatch(notebookId: notebookId, limit: batchSize)
        }
        return items.isEmpty ? nil : CapturedEmbeddingBatch(notebookId: notebookId, generationId: generationId, items: items)
    }

    /// Waits for chat admission immediately before the provider call; a batch
    /// already sent may finish. Question embeddings never call this.
    func send(_ batch: CapturedEmbeddingBatch, session: FolderEmbeddingSession) async throws -> [[Float]] {
        waitingForChat.insert(batch.notebookId)
        defer { waitingForChat.remove(batch.notebookId) }
        try await admission.waitForBackgroundBatch()
        waitingForChat.remove(batch.notebookId)
        guard session.selection.docFormatVersion == "2" else { return try await session.embed(inputs: batch.inputs) }
        // embedding-raw-format-v2 §3: each document input starts with its source's path line.
        // Same-text duplicates (embedding-plan-v1 §5) reuse the first occurrence's vector.
        let store = self.store, ids = batch.chunkIds
        let headers = try storeWork { try store.embeddingHeaders(chunkIds: ids) }
        return try await session.embed(inputs: batch.items.map { (headers[$0.chunkId] ?? "") + $0.text })
    }

    /// Validates the response shape and selection, then commits under the fence.
    func commit(_ batch: CapturedEmbeddingBatch, vectors: [[Float]], session: FolderEmbeddingSession,
                copyExisting: Bool, fence: JobFence) async throws -> EmbeddingBatchOutcome {
        let store = self.store, clock = self.clock
        let dims: Int
        do {
            dims = try validatedDimensions(vectors, count: batch.items.count)
            if let known = session.selection.dims, known != dims { throw IngestionError(code: "invalidVector") }
            if let generationId = batch.generationId,
               try storeWork({ try store.generation(id: generationId)?.identity.dims }) != dims {
                throw IngestionError(code: "invalidVector")
            }
        } catch let error as IngestionError {
            _ = try storeWork { try store.failEmbeddingJob(fence: fence, error: error.code, now: clock.now()) }
            return .failed(error.code)
        }
        guard let current = try await selectedSelection(batch.notebookId),
              FolderEmbeddingSession.compatible(current, session.selection) else {
            _ = try storeWork { try store.invalidateEmbeddingSelection(fence: fence, now: clock.now()) }
            return .invalidated
        }
        if let generationId = batch.generationId {
            let stored = try storeWork {
                try store.commitEmbeddingBatch(generationId: generationId, chunkIds: batch.chunkIds,
                    revisionIds: batch.revisionIds, vectors: vectors, fence: fence, now: clock.now(), duplicates: batch.duplicates)
            }
            return stored ? .committed : .stale
        }
        let created = try storeWork {
            try store.commitBootstrapBatch(notebookId: batch.notebookId, selection: session.selection, dims: dims,
                chunkIds: batch.chunkIds, revisionIds: batch.revisionIds, vectors: vectors, copyExisting: copyExisting,
                fence: fence, now: clock.now(), duplicates: batch.duplicates)
        }
        return created.map { .bootstrapped($0) } ?? .stale
    }

    /// Re-index with verified dimensions (known identity).
    public func reindex(notebookId: Int64, identity: GenerationIdentity) async throws -> Int64 {
        let store = self.store, clock = self.clock
        return try storeWork { try store.requestReindex(notebookId: notebookId, identity: identity, now: clock.now()) }
    }

    /// Re-index from the currently selected provider: captures a session and
    /// persists its nonsecret selection. Returns the job ID.
    public func requestReindex(notebookId: Int64) async throws -> Int64 {
        guard let captured = try await session(notebookId) else { throw IngestionError(code: "unsupportedEndpoint") }
        let store = self.store, clock = self.clock
        return try storeWork { () throws -> Int64 in
            // Reuse verified dimensions only from an identical active space.
            var selection = captured.selection
            if let active = try store.activeGeneration(notebookId: notebookId),
               FolderEmbeddingSession.compatible(EmbeddingSelection(identity: active.identity), selection) {
                selection = EmbeddingSelection(identity: active.identity)
            }
            return try store.requestEmbeddingBuild(notebookId: notebookId, selection: selection, copyExisting: false, now: clock.now())
        }
    }

    /// Incremental build for the selected provider after loose/note publications;
    /// unchanged vectors are copied from an identical active space.
    func requestIncrementalBuild(notebookId: Int64) async throws {
        guard let captured = try await session(notebookId) else { return }
        let store = self.store, clock = self.clock
        try storeWork { () throws -> Void in
            guard try store.notebookNeedsEmbedding(notebookId: notebookId) else { return }
            var selection = captured.selection
            if let active = try store.activeGeneration(notebookId: notebookId),
               FolderEmbeddingSession.compatible(EmbeddingSelection(identity: active.identity), selection) {
                selection = EmbeddingSelection(identity: active.identity)
            }
            _ = try store.requestEmbeddingBuild(notebookId: notebookId, selection: selection, copyExisting: true, now: clock.now())
        }
    }

    /// embedding-raw-format-v2 §5: the selected raw space equals the active generation's
    /// except for an older raw format (`1`), so a format-2 build is due. The active
    /// generation keeps serving queries (with its own format) until the build activates.
    func rawFormatUpgradeDue(notebookId: Int64) async throws -> Bool {
        guard let captured = try await session(notebookId) else { return false }
        let selected = captured.selection, store = self.store
        guard selected.queryFormatVersion == RawEmbeddingFormat.current, selected.docFormatVersion == RawEmbeddingFormat.current,
              let active = try storeWork({ try store.activeGeneration(notebookId: notebookId) }) else { return false }
        let identity = active.identity
        return identity.providerId == selected.providerId && identity.endpointRevision == selected.endpointRevision
            && identity.model == selected.model && identity.queryFormatVersion == "1" && identity.docFormatVersion == "1"
    }

    /// Requests the format-upgrade build beside the active generation (nothing is copied:
    /// the spaces differ). Returns whether a build was requested.
    func requestRawFormatUpgrade(notebookId: Int64) async throws -> Bool {
        guard try await rawFormatUpgradeDue(notebookId: notebookId), let captured = try await session(notebookId) else { return false }
        let store = self.store, clock = self.clock
        _ = try storeWork { try store.requestEmbeddingBuild(notebookId: notebookId, selection: captured.selection,
                                                           copyExisting: true, now: clock.now()) }
        return true
    }

    public func discard(generationId: Int64) async throws {
        let store = self.store, clock = self.clock
        try storeWork { try store.discardBuildingGeneration(id: generationId, now: clock.now()) }
    }

    public func discardJob(jobId: Int64) async throws {
        let store = self.store, clock = self.clock
        try storeWork {
            guard let job = try store.job(id: jobId),
                  let notebookId = try store.runOnDatabase({ try IngestionGenerationSQL.notebookId($0, job: job) }) else {
                throw StorageV19Error.notFound
            }
            try store.discardEmbedJob(jobId: jobId, notebookId: notebookId, now: clock.now())
        }
    }

    public func progress(notebookId: Int64) async throws -> GenerationProgress {
        let store = self.store
        let value = try storeWork { try store.generationProgress(notebookId: notebookId) }
        return value.with(pausedForChat: waitingForChat.contains(notebookId))
    }
}

import Foundation
import GRDB

extension NotebookStore {
    /// Due queued candidates of one kind, filtered before LIMIT. A null retry
    /// deadline means immediately due (queued rows only).
    public func dueJobs(kind: String, now: Int64, limit: Int) throws -> [IngestJob] {
        guard limit > 0 else { return [] }
        return try dbQueue.read { db in
            let ids = try Int64.fetchAll(db, sql: """
                SELECT id FROM ingest_jobs
                WHERE kind=? AND state='queued' AND attempts<5 AND (next_retry_at IS NULL OR next_retry_at<=?)
                ORDER BY coalesce(next_retry_at,0),id LIMIT ?
                """, arguments: [kind, now, limit])
            return try ids.compactMap { try RevisionJobSQL.job(db, id: $0) }
        }
    }

    /// An exhausted job is never reset: a user retry queues a new row with
    /// zero attempts and marks the source's refresh pending again.
    public func retryExhaustedJob(id: Int64, now: Int64) throws -> Int64? {
        let created = try dbQueue.write { db -> (Int64, Int64?)? in
            guard let job = try RevisionJobSQL.job(db, id: id), job.state == "failed",
                  job.attempts >= 5 || job.nextRetryAt == nil else { return nil }
            let created = try RevisionJobSQL.enqueueJob(db, draft: job.draft, now: now)
            try db.execute(sql: "UPDATE ingest_jobs SET next_retry_at=NULL WHERE id=?", arguments: [created])
            if job.draft.kind == "extract", let sourceId = Int64(job.draft.target.dropFirst("source:".count)) {
                try db.execute(sql: """
                    UPDATE sources SET status='pending',error=NULL WHERE id=? AND current_revision IS ?
                    """, arguments: [sourceId, job.draft.targetRevision])
            }
            return (created, try RevisionJobSQL.notebookId(db, draft: job.draft))
        }
        if let notebookId = created?.1 { notifyIndexingStatusChanged(notebookId: notebookId) }
        return created?.0
    }

    /// User cancellation. A running job is cancelled only through its fence.
    /// A cancelled extraction must not leave its source refresh pending
    /// forever: when no newer extraction owns the source it becomes a visible
    /// `cancelled` refresh error, which a later scan or retry replaces.
    public func cancelIngestJob(id: Int64, fence: JobFence?, now: Int64) throws -> Bool {
        let (cancelled, notebookId) = try dbQueue.write { db -> (Bool, Int64?) in
            guard let job = try RevisionJobSQL.job(db, id: id) else { return (false, nil) }
            if let fence {
                guard fence.jobId == id, try RevisionJobSQL.cancelJob(db, fence: fence, now: now) else { return (false, nil) }
            } else {
                guard ["queued", "paused"].contains(job.state) else { return (false, nil) }
                try RevisionJobSQL.cancelJob(db, id: id)
            }
            if job.draft.kind == "extract", let sourceId = Int64(job.draft.target.dropFirst("source:".count)) {
                try db.execute(sql: """
                    UPDATE sources SET status='error',error='cancelled' WHERE id=? AND current_revision IS ?
                        AND status IN ('pending','chunking')
                        AND NOT EXISTS(SELECT 1 FROM ingest_jobs WHERE kind='extract' AND target=? AND id<>?
                            AND (state IN ('queued','running','paused')
                                 OR (state='failed' AND attempts<5 AND next_retry_at IS NOT NULL)))
                    """, arguments: [sourceId, job.draft.targetRevision, job.draft.target, id])
            }
            return (true, try RevisionJobSQL.notebookId(db, draft: job.draft))
        }
        if let notebookId { notifyIndexingStatusChanged(notebookId: notebookId) }
        return cancelled
    }
}

/// Claims durable jobs after reserving their resources, renews leases every
/// 60 seconds while work runs, and fences failure/cancellation. Kind-specific
/// completion (publication, generation batches) belongs to `execute`.
public actor JobQueue {
    private let store: NotebookStore
    private let clock: any IngestLeaseClock
    private let admission: IngestionAdmission
    private let token: @Sendable () -> String
    private let observe: @Sendable (String) -> Void
    private var active: [Int64: (fence: JobFence, work: Task<Void, Error>, renewal: Task<Void, Never>)] = [:]
    /// Candidates selected by an in-progress runOne; concurrent calls pick distinct jobs.
    private var selected: Set<Int64> = []
    /// Candidates whose reservation or claim threw, skipped until the lease-clock
    /// deadline: one poisoned row at the head of the due order must not stall
    /// every later job of its kind (ingestion-memory-pressure-v1 §5).
    private var deferred: [Int64: Int64] = [:]
    private var stopped = false
    static let candidateLimit = 32
    static let renewalInterval: Int64 = 60
    static let preClaimDeferral: Int64 = 60

    public init(store: NotebookStore, clock: any IngestLeaseClock,
                admission: IngestionAdmission, token: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.init(store: store, clock: clock, admission: admission, token: token, observe: { _ in })
    }

    init(store: NotebookStore, clock: any IngestLeaseClock, admission: IngestionAdmission,
         token: @escaping @Sendable () -> String, observe: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.clock = clock
        self.admission = admission
        self.token = token
        self.observe = observe
    }

    public func runOne(kind: String, reservedBytes: Int64,
                       execute: @escaping @Sendable (IngestJob, JobFence) async throws -> Void) async throws -> Bool {
        try await runOne(kind: kind, reservation: { _ in reservedBytes }, execute: execute)
    }

    /// Selects a due candidate, reserves its resources, then claims that exact id.
    public func runOne(kind: String, reservation: @escaping @Sendable (IngestJob) async throws -> Int64,
                       execute: @escaping @Sendable (IngestJob, JobFence) async throws -> Void) async throws -> Bool {
        guard !stopped else { return false }
        let store = self.store, clock = self.clock
        let (candidates, now) = try storeWork { () throws -> ([IngestJob], Int64) in
            let now = clock.now()
            _ = try store.recoverExpiredJobs(now: now)
            _ = try store.requeueRetryableJobs(now: now)
            return (try store.dueJobs(kind: kind, now: now, limit: Self.candidateLimit), now)
        }
        deferred = deferred.filter { $0.value > now }
        guard let candidate = candidates.first(where: { !selected.contains($0.id) && deferred[$0.id] == nil }) else { return false }
        selected.insert(candidate.id)
        defer { selected.remove(candidate.id) }
        var permit: UUID?
        var claimed = false
        do {
            if kind == "extract" {
                permit = try await admission.acquireExtraction(bytes: try await reservation(candidate))
            }
            try Task.checkCancellation()
            guard !stopped else { await release(permit); return false }
            let lease = token()
            let claimedJob = try storeWork { () throws -> IngestJob? in
                try store.claimJob(now: clock.now(), leaseToken: lease, id: candidate.id)
            }
            guard let job = claimedJob else {
                await release(permit)
                return false
            }
            claimed = true
            try await run(job: job, fence: JobFence(jobId: job.id, leaseToken: lease), execute: execute)
            await release(permit)
            return true
        } catch {
            await release(permit)
            if !claimed, !(error is CancellationError) {
                let (deadline, overflow) = now.addingReportingOverflow(Self.preClaimDeferral)
                deferred[candidate.id] = overflow ? .max : deadline
            }
            throw error
        }
    }

    /// User cancellation: stops local work and cancels the durable job.
    public func cancel(jobId: Int64) async throws {
        let store = self.store, clock = self.clock
        if let entry = active[jobId] {
            entry.work.cancel()
            _ = try storeWork { try store.cancelIngestJob(id: jobId, fence: entry.fence, now: clock.now()) }
        } else {
            _ = try storeWork { try store.cancelIngestJob(id: jobId, fence: nil, now: clock.now()) }
        }
    }

    /// Cancels and joins all local work. Durable leases expire and are recovered.
    public func stop() async {
        stopped = true
        let entries = Array(active.values)
        for entry in entries {
            entry.work.cancel()
            entry.renewal.cancel()
        }
        for entry in entries {
            _ = await entry.work.result
            await entry.renewal.value
        }
    }

    private func release(_ permit: UUID?) async {
        if let permit { await admission.releaseExtraction(permit) }
    }

    private func run(job: IngestJob, fence: JobFence,
                     execute: @escaping @Sendable (IngestJob, JobFence) async throws -> Void) async throws {
        let store = self.store, clock = self.clock, observe = self.observe
        let claimedAt = clock.now()
        let work = Task<Void, Error> { try await execute(job, fence) }
        let renewal = Task<Void, Never> {
            var deadline = claimedAt
            while !Task.isCancelled {
                let (next, overflow) = deadline.addingReportingOverflow(Self.renewalInterval)
                guard !overflow else { return }
                deadline = next
                do {
                    try await clock.wait(until: deadline)
                    try Task.checkCancellation()
                    let renewed = try storeWork { try store.renewJob(fence: fence, now: clock.now()) }
                    guard renewed else { throw StorageV19Error.staleLease }
                    observe("renewed:\(job.id)")
                } catch is CancellationError {
                    return
                } catch {
                    // A lost lease must never publish: stop the work.
                    observe("renewalFailed:\(job.id)")
                    work.cancel()
                    return
                }
            }
        }
        active[job.id] = (fence, work, renewal)
        defer { active[job.id] = nil }
        let outcome = await withTaskCancellationHandler { await work.result } onCancel: { work.cancel() }
        renewal.cancel()
        await renewal.value
        switch outcome {
        case .success:
            observe("finished:\(job.id)")
        case .failure(let error) where error is CancellationError:
            observe("cancelled:\(job.id)")
        case .failure(let error):
            let code = (error as? IngestionError)?.code ?? (error as? StorageV19Error)?.code ?? "unexpectedError"
            // A stale fence makes this a no-op; the replacement owner is untouched.
            let failed = try storeWork { try store.failJob(fence: fence, error: code, now: clock.now()) }
            observe(failed ? "failed:\(job.id)" : "staleFailure:\(job.id)")
        }
    }
}

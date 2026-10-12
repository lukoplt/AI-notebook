import Foundation

/// Startup recovery and clock-driven reconciliation for every notebook's
/// folders: recovers leases, requeues retryable failures, repairs orphan scans
/// to partial (never missing), requeues extraction failures recorded under an
/// older extractor revision (`ingestion-reextract-v1`, every folder, watched
/// or not), schedules each watch-enabled folder once at start and runs a
/// pass every 30 minutes. A pass rescans a watch-enabled folder only when
/// `verifyDue` says so: every pass without a healthy native watch, otherwise
/// every 6 hours (contract `ingestion-scan-perf-v1` §4). Disabled folders only
/// scan on request.
public actor FolderReconciler {
    private let store: NotebookStore
    private let clock: any IngestLeaseClock
    private let requestScan: @Sendable (Int64, Bool) async throws -> Void
    private let watchHealthy: @Sendable (Int64) -> Bool
    private var timer: Task<Void, Never>?
    /// Lease-clock seconds of the last scan this reconciler requested per folder.
    private var lastRequested: [Int64: Int64] = [:]
    public private(set) var nextReconcileAt: Int64?
    public private(set) var running = false
    public static let interval: Int64 = Int64(RagContractV1.Scan.periodicReconcileMinutes) * 60
    /// Re-verification interval of a folder whose native watch is healthy.
    public static let watchedVerifyHours = 6
    public static let watchedVerifyInterval: Int64 = Int64(watchedVerifyHours) * 3600

    /// `watchHealthy(folderId)`: the folder's native watch is running and has not
    /// reported lost events since it started. The default (no watches) keeps
    /// every pass rescanning every watch-enabled folder.
    public init(store: NotebookStore, clock: any IngestLeaseClock,
                watchHealthy: @escaping @Sendable (Int64) -> Bool = { _ in false },
                requestScan: @escaping @Sendable (Int64, Bool) async throws -> Void) {
        self.store = store
        self.clock = clock
        self.watchHealthy = watchHealthy
        self.requestScan = requestScan
    }

    /// Whether a pass requests a (stat-only) scan of a watch-enabled folder
    /// (contract `ingestion-scan-perf-v1` §4, fixture `ingestion-scan-cadence-v1`).
    public static func verifyDue(startup: Bool, watchHealthy: Bool, lastFullScanAt: Int64?,
                                 lastRequestedAt: Int64?, now: Int64) -> Bool {
        if startup || !watchHealthy { return true }
        guard let last = [lastFullScanAt, lastRequestedAt].compactMap({ $0 }).max() else { return true }
        guard now >= last else { return false }
        let (elapsed, overflow) = now.subtractingReportingOverflow(last)
        return overflow || elapsed >= watchedVerifyInterval
    }

    public func start() async throws {
        guard !running else { return }
        let now = clock.now()
        try await recover(now: now)
        try await scheduleWatched(now: now, startup: true)
        running = true
        nextReconcileAt = Self.add(now, Self.interval)
        let clock = self.clock
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let due = await self.nextReconcileAt else { return }
                do {
                    try await clock.wait(until: due)
                    try await self.tick(now: clock.now())
                } catch {
                    return
                }
            }
        }
    }

    public func stop() async {
        running = false
        timer?.cancel()
        await timer?.value
        timer = nil
    }

    /// Runs one reconciliation pass now, then reschedules.
    public func reconcile(now: Int64) async throws {
        try await recover(now: now)
        try await scheduleWatched(now: now, startup: false)
        nextReconcileAt = Self.add(now, Self.interval)
    }

    /// A clock tick reconciles only when due.
    func tick(now: Int64) async throws {
        guard running, let due = nextReconcileAt, now >= due else { return }
        try await reconcile(now: now)
    }

    private func recover(now: Int64) async throws {
        let store = self.store
        try storeWork {
            _ = try store.recoverExpiredJobs(now: now)
            _ = try store.requeueRetryableJobs(now: now)
            _ = try store.repairOrphanScans(now: now)
            // ingestion-build-merge-v1 §4: no bootstrap builds a second generation of a building space.
            _ = try store.mergeRedundantBootstraps(now: now)
            // Failures under an older extractor get one attempt with the current one.
            _ = try store.requeueUpgradedExtractions(now: now)
            // Spreadsheets published under an older canonical text, in throttled batches.
            _ = try store.requeueSpreadsheetUpgrades(now: now)
        }
    }

    private func scheduleWatched(now: Int64, startup: Bool) async throws {
        let store = self.store
        let folders = try storeWork { try store.watchedFolders() }
        for folder in folders where Self.verifyDue(startup: startup, watchHealthy: watchHealthy(folder.id),
                                                   lastFullScanAt: folder.lastFullScanAt,
                                                   lastRequestedAt: lastRequested[folder.id], now: now) {
            try await requestScan(folder.id, false)
            lastRequested[folder.id] = now
        }
    }

    private static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : value
    }
}

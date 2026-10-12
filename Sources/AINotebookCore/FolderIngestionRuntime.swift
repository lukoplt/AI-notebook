import Foundation

/// Which folders have a healthy native watch (contract `ingestion-scan-perf-v1` §4):
/// started successfully and no lost-events (`overflow`) report since. The runtime
/// writes it; the reconciler reads it to stretch periodic re-verification.
final class FolderWatchHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var healthy: Set<Int64> = []

    func started(_ folderId: Int64) { lock.lock(); healthy.insert(folderId); lock.unlock() }
    /// Stopped, failed, or reported lost events: periodic passes rescan it again.
    func degraded(_ folderId: Int64) { lock.lock(); healthy.remove(folderId); lock.unlock() }
    func isHealthy(_ folderId: Int64) -> Bool { lock.lock(); defer { lock.unlock() }; return healthy.contains(folderId) }
}

/// A native folder watch. Raw event kinds go to the runtime, which alone owns debouncing.
public protocol FolderWatchHandle: Sendable {
    func start() throws
    func stop()
}

public protocol FolderWatchFactory: Sendable {
    func make(folder: FolderSource, onEvent: @escaping @Sendable (String) -> Void) throws -> any FolderWatchHandle
}

/// Watcher event kinds → whether the coalesced rescan must hash every file.
/// Only a pure creation can rely on the metadata fast path.
public enum FolderWatchEventPolicy {
    public static func forceHash(kind: String) -> Bool { kind != "created" }
}

extension FolderWatcher: FolderWatchHandle {}

/// FSEvents in raw-signal mode: no native quiet period.
public struct NativeFolderWatchFactory: FolderWatchFactory {
    public init() {}
    public func make(folder: FolderSource, onEvent: @escaping @Sendable (String) -> Void) throws -> any FolderWatchHandle {
        FolderWatcher(folder: URL(fileURLWithPath: folder.draft.rootPath, isDirectory: true), onEvent: onEvent)
    }
}

/// Identity resolved off the UI thread, handed to the synchronous catalog API.
private struct ResolvedIdentity: FolderPathIdentity {
    let identity: FolderIdentity
    func resolve(rootPath: String) throws -> FolderIdentity { identity }
}

/// The process-wide durable ingestion runtime: folder commands, native watch
/// lifetime, debounced rescans and the dispatch loops that drain the durable
/// queue (`admission.maxExtractions` extraction loops, one scan loop, one
/// embed/gc loop, all at `.utility` priority). All callbacks carry a folder ID;
/// no "currently selected notebook" is consulted.
public actor FolderIngestionRuntime {
    private let store: NotebookStore
    private let scanner: FolderScanner
    private let extraction: FolderExtractionWorker
    private let index: FolderIndexCoordinator
    private let queue: JobQueue
    private let clock: any IngestLeaseClock
    private let admission: IngestionAdmission
    private let watches: any FolderWatchFactory
    private let dispatch: Bool
    private let milliseconds: @Sendable () -> Int64
    private let observe: @Sendable (String) -> Void
    private let reconciler: FolderReconciler
    private let availability: @Sendable (Int64) async -> EmbeddingAvailability
    /// Sampled on every scheduler tick (contract `ingestion-memory-pressure-v1` §3):
    /// a missed or reordered OS notification cannot keep extraction paused.
    private let memoryPressure: (@Sendable () -> MemoryPressureLevel)?
    /// Sampled at most every `AdaptiveConcurrency.sampleIntervalMs` on the
    /// scheduler tick (addendum A §A.4); nil keeps the limit at `maxExtractions`.
    private let systemLoad: (@Sendable () -> AdaptiveConcurrency.SystemSample)?
    private var governor: AdaptiveConcurrency.Governor
    private var lastSystemSample: Int64?

    private var started = false
    private var starting = false
    /// Contract code of the last failed `start()`; nil once a start succeeded.
    /// Surfaces as `IndexingStatus` `blocked(runtimeFailed)`.
    public private(set) var startError: String?
    private var scanOutcomes: [Int64: FolderScanOutcome] = [:]
    private var handles: [Int64: (token: UUID, handle: any FolderWatchHandle)] = [:]
    private let watchHealth = FolderWatchHealth()
    private var schedules: [Int64: RescanSchedule] = [:]
    private var forced: [Int64: (pending: Bool, trailing: Bool)] = [:]
    private var loops: [Task<Void, Never>] = []

    /// `availability` explains a missing embedding session per notebook (indexing status).
    public init(store: NotebookStore, scanner: FolderScanner, extraction: FolderExtractionWorker,
                index: FolderIndexCoordinator, queue: JobQueue, clock: any IngestLeaseClock,
                admission: IngestionAdmission, watches: any FolderWatchFactory,
                availability: @escaping @Sendable (Int64) async -> EmbeddingAvailability = { _ in .ready },
                memoryPressure: (@Sendable () -> MemoryPressureLevel)? = nil,
                systemLoad: (@Sendable () -> AdaptiveConcurrency.SystemSample)? = nil) {
        self.init(store: store, scanner: scanner, extraction: extraction, index: index, queue: queue, clock: clock,
                  admission: admission, watches: watches, dispatch: true,
                  milliseconds: { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }, observe: { _ in },
                  availability: availability, memoryPressure: memoryPressure, systemLoad: systemLoad)
    }

    /// `dispatch: false` leaves draining to `drainOnce()` (deterministic tests).
    init(store: NotebookStore, scanner: FolderScanner, extraction: FolderExtractionWorker,
         index: FolderIndexCoordinator, queue: JobQueue, clock: any IngestLeaseClock,
         admission: IngestionAdmission, watches: any FolderWatchFactory, dispatch: Bool,
         milliseconds: @escaping @Sendable () -> Int64, observe: @escaping @Sendable (String) -> Void,
         availability: @escaping @Sendable (Int64) async -> EmbeddingAvailability = { _ in .ready },
         memoryPressure: (@Sendable () -> MemoryPressureLevel)? = nil,
         systemLoad: (@Sendable () -> AdaptiveConcurrency.SystemSample)? = nil) {
        self.availability = availability
        self.memoryPressure = memoryPressure
        self.systemLoad = systemLoad
        governor = AdaptiveConcurrency.Governor(cap: admission.maxExtractions)
        self.store = store
        self.scanner = scanner
        self.extraction = extraction
        self.index = index
        self.queue = queue
        self.clock = clock
        self.admission = admission
        self.watches = watches
        self.dispatch = dispatch
        self.milliseconds = milliseconds
        self.observe = observe
        let health = watchHealth
        reconciler = FolderReconciler(store: store, clock: clock, watchHealthy: { health.isHealthy($0) }, requestScan: { folderId, verifyAll in
            _ = try storeWork { try store.requestFolderScan(folderId: folderId, verifyAll: verifyAll, now: clock.now()) }
        })
    }

    /// The production composition: native filesystem, bounded extractors,
    /// bundled detector and FSEvents watches. Construction does no IO.
    public static func standard(store: NotebookStore, admission: IngestionAdmission,
                                session: @escaping @Sendable (Int64) async throws -> FolderEmbeddingSession?,
                                clock: any IngestLeaseClock = SystemIngestLeaseClock(),
                                watches: any FolderWatchFactory = NativeFolderWatchFactory(),
                                memoryPressure: (@Sendable () -> MemoryPressureLevel)? = nil,
                                systemLoad: (@Sendable () -> AdaptiveConcurrency.SystemSample)? = nil) throws -> FolderIngestionRuntime {
        try make(store: store, admission: admission, session: session, clock: clock, watches: watches,
                 fileSystem: NativeFolderFileSystem(), dispatch: true, memoryPressure: memoryPressure, systemLoad: systemLoad,
                 web: WebExtractor())
    }

    /// Production composition from a session factory that explains a missing
    /// session (`EmbeddingAvailability`) instead of returning nil.
    public static func standard(store: NotebookStore, admission: IngestionAdmission,
                                resolveSession: @escaping @Sendable (Int64) async throws -> EmbeddingSessionResolution,
                                clock: any IngestLeaseClock = SystemIngestLeaseClock(),
                                watches: any FolderWatchFactory = NativeFolderWatchFactory(),
                                memoryPressure: (@Sendable () -> MemoryPressureLevel)? = nil,
                                systemLoad: (@Sendable () -> AdaptiveConcurrency.SystemSample)? = nil) throws -> FolderIngestionRuntime {
        try make(store: store, admission: admission, resolveSession: resolveSession, clock: clock, watches: watches,
                 fileSystem: NativeFolderFileSystem(), dispatch: true, memoryPressure: memoryPressure, systemLoad: systemLoad,
                 web: WebExtractor())
    }

    /// A nil session reads as `noProvider`.
    static func make(store: NotebookStore, admission: IngestionAdmission,
                     session: @escaping @Sendable (Int64) async throws -> FolderEmbeddingSession?,
                     clock: any IngestLeaseClock, watches: any FolderWatchFactory, fileSystem: any FolderFileSystem,
                     dispatch: Bool, milliseconds: @escaping @Sendable () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) },
                     observe: @escaping @Sendable (String) -> Void = { _ in },
                     memoryPressure: (@Sendable () -> MemoryPressureLevel)? = nil,
                     systemLoad: (@Sendable () -> AdaptiveConcurrency.SystemSample)? = nil,
                     web: (any TextExtractor)? = nil) throws -> FolderIngestionRuntime {
        let selection: @Sendable (Int64) async throws -> EmbeddingSelection? = { try await session($0)?.selection }
        return try make(store: store, admission: admission, session: session, selection: selection,
                        availability: { id in ((try? await session(id)) ?? nil) == nil ? .noProvider : .ready },
                        clock: clock, watches: watches, fileSystem: fileSystem, dispatch: dispatch,
                        milliseconds: milliseconds, observe: observe, memoryPressure: memoryPressure, systemLoad: systemLoad, web: web)
    }

    /// Embed jobs treat an unloadable credential as a retryable failure
    /// (`credentialUnavailable`); extraction publishes without an embed job.
    static func make(store: NotebookStore, admission: IngestionAdmission,
                     resolveSession: @escaping @Sendable (Int64) async throws -> EmbeddingSessionResolution,
                     clock: any IngestLeaseClock, watches: any FolderWatchFactory, fileSystem: any FolderFileSystem,
                     dispatch: Bool, milliseconds: @escaping @Sendable () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) },
                     observe: @escaping @Sendable (String) -> Void = { _ in },
                     memoryPressure: (@Sendable () -> MemoryPressureLevel)? = nil,
                     systemLoad: (@Sendable () -> AdaptiveConcurrency.SystemSample)? = nil,
                     web: (any TextExtractor)? = nil) throws -> FolderIngestionRuntime {
        let session: @Sendable (Int64) async throws -> FolderEmbeddingSession? = { id in
            let resolved = try await resolveSession(id)
            if resolved.availability == .credentialUnavailable { throw IngestionError(code: "credentialUnavailable") }
            return resolved.session
        }
        return try make(store: store, admission: admission, session: session,
                        selection: { try await session($0)?.selection },
                        availability: { id in (try? await resolveSession(id))?.availability ?? .noProvider },
                        clock: clock, watches: watches, fileSystem: fileSystem, dispatch: dispatch,
                        milliseconds: milliseconds, observe: observe, memoryPressure: memoryPressure, systemLoad: systemLoad, web: web)
    }

    private static func make(store: NotebookStore, admission: IngestionAdmission,
                             session: @escaping @Sendable (Int64) async throws -> FolderEmbeddingSession?,
                             selection: @escaping @Sendable (Int64) async throws -> EmbeddingSelection?,
                             availability: @escaping @Sendable (Int64) async -> EmbeddingAvailability,
                             clock: any IngestLeaseClock, watches: any FolderWatchFactory, fileSystem: any FolderFileSystem,
                             dispatch: Bool, milliseconds: @escaping @Sendable () -> Int64,
                             observe: @escaping @Sendable (String) -> Void,
                             memoryPressure: (@Sendable () -> MemoryPressureLevel)?,
                             systemLoad: (@Sendable () -> AdaptiveConcurrency.SystemSample)?,
                             web: (any TextExtractor)?) throws -> FolderIngestionRuntime {
        let extractor = BoundedDocumentExtractor()
        return FolderIngestionRuntime(store: store,
            scanner: FolderScanner(store: store, fileSystem: fileSystem, tables: try UnicodeTables.bundled(), clock: clock,
                                   hashWidth: { AdaptiveConcurrency.hashWidth(extractionLimit: await admission.concurrencyLimit) }),
            extraction: FolderExtractionWorker(store: store, fileSystem: fileSystem, detector: .bundled(), clock: clock,
                embeddingSelection: selection, web: web,
                extract: { url, kind, rules in try await extractor.extract(url: url, kind: kind, rules: rules) }),
            index: FolderIndexCoordinator(store: store, admission: admission, clock: clock, session: session, selectedSelection: selection),
            queue: JobQueue(store: store, clock: clock, admission: admission),
            clock: clock, admission: admission, watches: watches, dispatch: dispatch, milliseconds: milliseconds, observe: observe,
            availability: availability, memoryPressure: memoryPressure, systemLoad: systemLoad)
    }

    // MARK: Lifecycle

    /// Idempotent: recovers durable state, schedules watched folders once,
    /// starts their native watches and (in production) the dispatch loops,
    /// then requests missing index builds. `started` is set only after the
    /// reconciler started; a failure is kept as `startError` (status
    /// `blocked(runtimeFailed)`) and a later `start()` may retry.
    public func start() async throws {
        guard !started, !starting else { return }
        starting = true
        defer { starting = false }
        let store = self.store
        do {
            try await reconciler.start()
            let folders = try storeWork({ try store.watchedFolders() })
            started = true
            startError = nil
            for folder in folders { startWatch(folder) }
        } catch {
            await reconciler.stop()
            startError = Self.code(error)
            storeWork {
                let notebooks = (try? store.runOnDatabase { try Int64.fetchAll($0, sql: "SELECT id FROM notebooks") }) ?? []
                store.notifyIndexingStatusChanged(notebookIds: Set(notebooks))
            }
            throw error
        }
        storeWork {
            let notebooks = (try? store.runOnDatabase { try Int64.fetchAll($0, sql: "SELECT id FROM notebooks") }) ?? []
            store.notifyIndexingStatusChanged(notebookIds: Set(notebooks))
        }
        if dispatch {
            // One extraction loop per admissible permit; the admission's adaptive
            // limit decides how many of them run (addendum A §A.5). Background
            // work runs at utility QoS so the UI and foreground apps win.
            let extractLoops = Array(repeating: ["extract"], count: admission.maxExtractions)
            for kinds in [["scan"]] + extractLoops + [["embed", "gc"]] {
                loops.append(Task(priority: .utility) { [weak self] in await self?.dispatchLoop(kinds: kinds) })
            }
            loops.append(Task { [weak self] in await self?.scheduleLoop() })
        }
        // Best effort: a provider error here must not fail the start.
        try? await ensureIndexBuilds()
    }

    static func code(_ error: Error) -> String {
        (error as? IngestionError)?.code ?? (error as? StorageV19Error)?.code ?? "unexpectedError"
    }

    /// Stops watches, the reconciler and all dispatch loops, and joins them.
    public func stop() async {
        started = false
        for (_, entry) in handles { entry.handle.stop() }
        handles = [:]
        await reconciler.stop()
        let running = loops
        loops = []
        for loop in running { loop.cancel() }
        for loop in running { await loop.value }
    }

    // MARK: Commands

    /// Resolves the root off the UI thread, persists defaults, queues the first
    /// scan and starts the watch. Overlapping roots fail before any watch starts.
    public func addFolder(notebookId: Int64, url: URL) async throws -> FolderSource {
        let path = url.standardizedFileURL.path
        let fileSystem = scanner.fileSystem
        let identity = try await Task.detached(priority: .userInitiated) { try fileSystem.resolve(rootPath: path) }.value
        let store = self.store, clock = self.clock
        let folder = try storeWork { () throws -> FolderSource in
            let created = try store.createFolder(notebookId: notebookId, draft: FolderDraft(rootPath: path,
                displayName: url.lastPathComponent.isEmpty ? path : url.lastPathComponent,
                includeExts: FolderRules.defaults.includeExts, ignoreGlobs: FolderRules.defaults.ignoreGlobs,
                limitsJSON: "{}", encodingFallback: FolderRules.defaults.encodingFallback, watchEnabled: true),
                identity: ResolvedIdentity(identity: identity), now: clock.now())
            _ = try store.requestFolderScan(folderId: created.id, verifyAll: false, now: clock.now())
            return created
        }
        if started { startWatch(folder) }
        wake()
        return folder
    }

    public func scanNow(folderId: Int64, verifyAll: Bool) async throws -> Int64 {
        let store = self.store, clock = self.clock
        let id = try storeWork { try store.requestFolderScan(folderId: folderId, verifyAll: verifyAll, now: clock.now()) }
        wake()
        return id
    }

    /// Persists the flag and starts/stops only this folder's native watch;
    /// manual scans stay possible while disabled.
    public func setWatching(folderId: Int64, enabled: Bool) async throws {
        let store = self.store
        let folder = try storeWork { () throws -> FolderSource in
            let current = try store.folderSource(id: folderId)
            let d = current.draft
            try store.updateFolder(id: folderId, draft: FolderDraft(rootPath: d.rootPath, displayName: d.displayName,
                includeExts: d.includeExts, ignoreGlobs: d.ignoreGlobs, limitsJSON: d.limitsJSON,
                encodingFallback: d.encodingFallback, watchEnabled: enabled), identity: ResolvedIdentity(identity: current.identity))
            store.notifyFolderIngestionChanged(notebookId: current.notebookId)
            return try store.folderSource(id: folderId)
        }
        if enabled {
            if started { startWatch(folder) }
        } else {
            stopWatch(folderId)
        }
    }

    /// Invalidates the watch token first, cancels folder/source jobs, then
    /// deletes catalog rows. Never touches files on disk.
    public func removeFolder(folderId: Int64) async throws {
        stopWatch(folderId)
        schedules[folderId] = nil
        forced[folderId] = nil
        scanOutcomes[folderId] = nil
        let store = self.store, clock = self.clock
        try storeWork {
            let folder = try store.folderSource(id: folderId)
            try store.cancelFolderWork(folderId: folderId, now: clock.now())
            try store.deleteFolder(id: folderId)
            store.notifyFolderIngestionChanged(notebookId: folder.notebookId)
        }
    }

    /// One raw watcher signal (monotonic milliseconds). Force-hash requests are
    /// OR-coalesced into the folder's single pending rescan.
    public func signal(folderId: Int64, at milliseconds: Int64, forceHash: Bool) async {
        var schedule = schedules[folderId] ?? RescanSchedule()
        var force = forced[folderId] ?? (false, false)
        if schedule.running { force.trailing = force.trailing || forceHash } else { force.pending = force.pending || forceHash }
        schedule.signal(at: milliseconds)
        schedules[folderId] = schedule
        forced[folderId] = force
    }

    /// Samples the memory-pressure probe (and, every `sampleIntervalMs`, the
    /// system probe for the adaptive limit), then requests every due debounced rescan.
    func tick(at milliseconds: Int64) async throws {
        var level: MemoryPressureLevel?
        if let memoryPressure {
            level = memoryPressure()
            await admission.setMemoryPressure(level!)
        }
        if let systemLoad, lastSystemSample.map({ milliseconds < $0 || milliseconds - $0 >= AdaptiveConcurrency.sampleIntervalMs }) ?? true {
            lastSystemSample = milliseconds
            await applyConcurrency(sample: systemLoad(), memory: level, at: milliseconds)
        }
        let store = self.store, clock = self.clock
        for folderId in schedules.keys.sorted() {
            guard var schedule = schedules[folderId], schedule.isDue(at: milliseconds) else { continue }
            let force = forced[folderId]?.pending ?? false
            let exists = try storeWork { () throws -> Bool in
                guard (try? store.folderSource(id: folderId)) != nil else { return false }
                _ = try store.requestFolderScan(folderId: folderId, verifyAll: force, now: clock.now())
                return true
            }
            guard exists else { schedules[folderId] = nil; forced[folderId] = nil; continue }
            schedule.started()
            schedules[folderId] = schedule
            forced[folderId] = (false, forced[folderId]?.trailing ?? false)
            wake()
        }
    }

    /// Feeds one system sample through the target policy and governor into admission (addendum A §A.4).
    func applyConcurrency(sample: AdaptiveConcurrency.SystemSample, memory: MemoryPressureLevel?, at milliseconds: Int64) async {
        let own = await admission.runningExtractions
        let pressure: MemoryPressureLevel
        if let memory { pressure = memory } else { pressure = await admission.memoryPressureLevel }
        let target = AdaptiveConcurrency.target(sample, ownWorkers: own, memory: pressure)
        await admission.setConcurrencyLimit(governor.observe(target: target, atMs: milliseconds))
    }

    func noteScanStarted(folderId: Int64) {
        var schedule = schedules[folderId] ?? RescanSchedule()
        if !schedule.running { schedule.started() }
        schedules[folderId] = schedule
    }

    func noteScanFinished(folderId: Int64, at milliseconds: Int64) {
        guard var schedule = schedules[folderId] else { return }
        schedule.finished(at: milliseconds)
        schedules[folderId] = schedule
        let force = forced[folderId] ?? (false, false)
        forced[folderId] = (force.pending || force.trailing, false)
    }

    /// Waits until the folder and its sources have no queued/running scan or extraction.
    public func waitForFolderIdle(folderId: Int64) async throws {
        let store = self.store
        while true {
            try Task.checkCancellation()
            let busy = try storeWork { try store.folderHasPendingWork(folderId: folderId) }
            guard busy else { return }
            if dispatch {
                try await Task.sleep(for: .milliseconds(50))
            } else if try await !drainOnce() {
                return // nothing due now (e.g. a retry deadline in the future)
            }
        }
    }

    /// Runs one due job (scan, extract, embed, gc order). Returns whether an attempt ran.
    public func drainOnce() async throws -> Bool {
        for kind in ["scan", "extract", "embed", "gc"] where try await run(kind: kind) { return true }
        return false
    }

    /// Wakes generation work for every notebook after loose/note publications.
    public func wakeGenerationWork() async throws {
        let store = self.store
        let notebooks = try storeWork { try store.runOnDatabase { try Int64.fetchAll($0, sql: "SELECT id FROM notebooks ORDER BY id") } }
        for notebook in notebooks { try await index.requestIncrementalBuild(notebookId: notebook) }
        wake()
    }

    /// Legacy facade: finds or adds the persisted folder for `url`, scans it
    /// and returns how many sources gained a new published revision.
    public func syncFolder(notebookId: Int64, url: URL) async throws -> Int {
        let store = self.store
        let path = url.standardizedFileURL.path
        let existing = try storeWork { try store.folders(notebookId: notebookId).first { $0.draft.rootPath == path } }
        let folder: FolderSource
        if let existing { folder = existing } else { folder = try await addFolder(notebookId: notebookId, url: url) }
        let before = try storeWork { try store.folderPublications(folderId: folder.id) }
        if existing != nil { _ = try await scanNow(folderId: folder.id, verifyAll: false) }
        try await waitForFolderIdle(folderId: folder.id)
        let after = try storeWork { try store.folderPublications(folderId: folder.id) }
        return after.filter { before[$0.key] != $0.value }.count
    }

    /// Validates and applies new rules through the scanner (atomic revocation
    /// and requeue). Rules compile with the folder volume's case policy.
    public func applyRules(folderId: Int64, rules: FolderRules) async throws {
        try await scanner.applyRules(folderId: folderId, rules: rules, now: clock.now())
    }

    /// True when every glob compiles under the folder volume's case policy and
    /// every limit is positive and within the process ceilings.
    public func validateRules(folderId: Int64, rules: FolderRules) async -> Bool {
        let store = self.store, fileSystem = scanner.fileSystem, tables = scanner.tables
        guard let folder = try? storeWork({ try store.folderSource(id: folderId) }) else { return false }
        let sensitive = await Task.detached(priority: .userInitiated) { (try? fileSystem.caseSensitive(root: folder)) ?? false }.value
        return (try? FolderClassifier(rules: rules, caseSensitive: sensitive, tables: tables)) != nil
    }

    /// Re-index with the currently selected embedder: a fresh build beside the
    /// active index (dimension bootstrap when unknown). Returns the job ID.
    public func requestReindex(notebookId: Int64) async throws -> Int64 {
        try await index.requestReindex(notebookId: notebookId)
    }

    public func generationProgress(notebookId: Int64) async throws -> GenerationProgress {
        try await index.progress(notebookId: notebookId)
    }

    // MARK: Indexing status

    /// Why background embedding can or cannot run for the notebook right now.
    public func embeddingAvailability(notebookId: Int64) async -> EmbeddingAvailability {
        await availability(notebookId)
    }

    /// The notebook's indexing status: store inputs + embedding availability +
    /// runtime start error + admission memory pressure (contract `indexing-status-v1`).
    public func indexingStatus(notebookId: Int64) async throws -> IndexingStatus {
        let reason = await availability(notebookId)
        let pressure = await admission.memoryPressureLevel
        let store = self.store, clock = self.clock, error = startError
        var inputs = try storeWork {
            try store.indexingInputs(notebookId: notebookId, now: clock.now(), availability: reason, runtimeError: error)
        }
        inputs.memoryPressure = pressure
        return IndexingStatus.derive(inputs)
    }

    /// The folder's last finished scan in this process ("No changes · N files up to date"); nil before one finished.
    public func lastScanOutcome(folderId: Int64) -> FolderScanOutcome? {
        scanOutcomes[folderId]
    }

    /// "Retry now" / "Build index": retries a failed runtime start, makes the
    /// notebook's waiting embed job due now, or else requests a missing build.
    public func retryIndexingNow(notebookId: Int64) async throws {
        if startError != nil { try await start() }
        let store = self.store, clock = self.clock
        let expedited = try storeWork { try store.expediteEmbedRetry(notebookId: notebookId, now: clock.now()) }
        if !expedited { _ = try await ensureIndexBuild(notebookId: notebookId) }
        wake()
    }

    /// Explicit "Retry" of one failed folder source: its failure budget starts
    /// over and extraction is queued (`ingestion-retry-cap-v1` §5). Returns
    /// whether the source was retried.
    @discardableResult
    public func retryFailedSource(sourceId: Int64) async throws -> Bool {
        let store = self.store, clock = self.clock
        let retried = try storeWork { try store.retryFailedExtraction(sourceId: sourceId, now: clock.now()) }
        wake()
        return retried
    }

    /// "Retry all failed" for the notebook. Returns the number of retried sources.
    @discardableResult
    public func retryFailedSources(notebookId: Int64) async throws -> Int {
        let store = self.store, clock = self.clock
        let count = try storeWork { try store.retryFailedExtractions(notebookId: notebookId, now: clock.now()) }
        wake()
        return count
    }

    /// Requests an incremental build when the notebook has unindexed published
    /// content, no unfinished embed job, and an available session. Returns
    /// whether a build was requested.
    @discardableResult
    func ensureIndexBuild(notebookId: Int64) async throws -> Bool {
        let store = self.store
        let (needs, unfinished) = try storeWork {
            (try store.notebookNeedsEmbedding(notebookId: notebookId), try store.hasUnfinishedEmbedJob(notebookId: notebookId))
        }
        guard !unfinished else { return false }
        guard needs else {
            // embedding-raw-format-v2 §5: a complete index at raw format 1 is rebuilt once at format 2.
            guard try await index.requestRawFormatUpgrade(notebookId: notebookId) else { return false }
            return try storeWork { try store.hasUnfinishedEmbedJob(notebookId: notebookId) }
        }
        try await index.requestIncrementalBuild(notebookId: notebookId)
        return try storeWork { try store.hasUnfinishedEmbedJob(notebookId: notebookId) }
    }

    private func ensureIndexBuilds() async throws {
        let store = self.store
        let notebooks = try storeWork { try store.runOnDatabase { try Int64.fetchAll($0, sql: "SELECT id FROM notebooks ORDER BY id") } }
        for notebook in notebooks { _ = try? await ensureIndexBuild(notebookId: notebook) }
        wake()
    }

    /// Discards the notebook's latest unfinished build; the active index stays.
    public func discardBuild(notebookId: Int64) async throws {
        guard let jobId = try await index.progress(notebookId: notebookId).jobId else { return }
        try await index.discardJob(jobId: jobId)
    }

    /// Persisted folders (any notebook) registered at this root path.
    public func folderIds(rootPath: String) async throws -> [Int64] {
        let store = self.store
        return try storeWork { try store.allFolders().filter { $0.draft.rootPath == rootPath }.map(\.id) }
    }

    var watchedFolderIds: [Int64] { handles.keys.sorted() }

    // MARK: Internals

    /// Dispatch loops poll; commands only need durable rows, so waking is a hint.
    private func wake() {}

    private func startWatch(_ folder: FolderSource) {
        guard folder.draft.watchEnabled, handles[folder.id] == nil else { return }
        let token = UUID(), folderId = folder.id, clock = self.milliseconds
        do {
            let handle = try watches.make(folder: folder) { [weak self] kind in
                Task { await self?.receive(folderId: folderId, token: token, kind: kind, at: clock()) }
            }
            try handle.start()
            handles[folder.id] = (token, handle)
            watchHealth.started(folderId)
            observe("watch:\(folderId)")
        } catch {
            observe("watchFailed:\(folderId)")
        }
    }

    private func stopWatch(_ folderId: Int64) {
        watchHealth.degraded(folderId)
        handles.removeValue(forKey: folderId)?.handle.stop()
    }

    /// Token-guarded: callbacks from a stopped or replaced watch are ignored.
    /// Lost events (`overflow`) force a re-hashing rescan and mark the watch
    /// unhealthy, so periodic passes rescan the folder again (§4).
    func receive(folderId: Int64, token: UUID, kind: String, at milliseconds: Int64) async {
        guard handles[folderId]?.token == token else { return }
        if kind == "overflow" { watchHealth.degraded(folderId) }
        await signal(folderId: folderId, at: milliseconds, forceHash: FolderWatchEventPolicy.forceHash(kind: kind))
    }

    /// Whether the folder's native watch counts as healthy for the reconciler.
    func isWatchHealthy(folderId: Int64) -> Bool { watchHealth.isHealthy(folderId) }

    /// After system sleep the watches may have missed events: every watched
    /// folder gets one debounced stat-only rescan (contract `ingestion-scan-perf-v1` §4).
    public func systemDidWake() async {
        let now = milliseconds()
        for folderId in handles.keys.sorted() { await signal(folderId: folderId, at: now, forceHash: false) }
    }

    func token(folderId: Int64) -> UUID? { handles[folderId]?.token }

    private func run(kind: String) async throws -> Bool {
        let store = self.store, clock = self.clock, scanner = self.scanner, extraction = self.extraction
        let index = self.index, observe = self.observe
        return try await queue.runOne(kind: kind, reservation: { job in
            try storeWork { try store.extractionReservation(job: job) }
        }, execute: { [weak self] job, fence in
            observe("start:\(job.id)")
            switch job.draft.kind {
            case "scan":
                guard let folderId = Int64(job.draft.target.dropFirst("folder:".count)) else { return }
                let (verifyAll, baseline) = try storeWork { (try store.scanOptions(jobId: job.id), try store.maxIngestJobId()) }
                await self?.noteScanStarted(folderId: folderId)
                defer { Task { [weak self] in await self?.finishedScan(folderId: folderId) } }
                try await scanner.scan(folderId: folderId, verifyAll: verifyAll, fence: fence, now: clock.now(), cancelled: { false })
                await self?.scanCompleted(folderId: folderId, baseline: baseline)
            case "extract":
                try await extraction.execute(job: job, fence: fence)
            case "embed":
                try await index.execute(job: job, fence: fence)
            case "gc":
                try storeWork { try store.runGarbageCollection(job: job, fence: fence, now: clock.now()) }
            default:
                throw StorageV19Error.invalidValue
            }
        })
    }

    private func finishedScan(folderId: Int64) { noteScanFinished(folderId: folderId, at: milliseconds()) }

    /// Records the scan outcome and builds a missing index ("Scan now" on an
    /// unchanged folder). Provider errors never fail the scan job.
    private func scanCompleted(folderId: Int64, baseline: Int64) async {
        let store = self.store, clock = self.clock
        guard let (folder, outcome) = try? storeWork({ () throws -> (FolderSource, FolderScanOutcome) in
            (try store.folderSource(id: folderId), try store.folderScanOutcome(folderId: folderId, sinceJobId: baseline, now: clock.now()))
        }), folder.scanState != "scanning" else { return }
        scanOutcomes[folderId] = outcome
        storeWork { store.notifyIndexingStatusChanged(notebookId: folder.notebookId) }
        _ = try? await ensureIndexBuild(notebookId: folder.notebookId)
    }

    private func dispatchLoop(kinds: [String]) async {
        while !Task.isCancelled {
            var ran = false
            for kind in kinds where !ran { ran = (try? await run(kind: kind)) ?? false }
            if !ran { try? await Task.sleep(for: .milliseconds(250)) }
        }
    }

    /// Lease-clock seconds between two scheduler ticks (normally 100 ms apart)
    /// that mean the process was suspended, e.g. by system sleep.
    public static let wakeGapSeconds: Int64 = 60

    /// Whether two consecutive scheduler ticks bracket a suspension
    /// (contract `ingestion-scan-perf-v1` §4, fixture `ingestion-scan-cadence-v1`).
    public static func suspendedBetween(previous: Int64, now: Int64) -> Bool {
        guard now >= previous else { return false }
        let (gap, overflow) = now.subtractingReportingOverflow(previous)
        return overflow || gap >= wakeGapSeconds
    }

    private func scheduleLoop() async {
        var previous = clock.now()
        while !Task.isCancelled {
            // Platform-neutral wake detection (the App's wake notification is a faster hint).
            let now = clock.now()
            if Self.suspendedBetween(previous: previous, now: now) { await systemDidWake() }
            previous = now
            try? await tick(at: milliseconds())
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}


import AINotebookCore
import Foundation

/// Indexing status of the current notebook for the Sources status strip, the
/// folder rows ("Checking…", scan outcome) and the top-bar panel dot.
/// Refreshes on `indexingStatusDidChange` / `folderIngestionDidChange` and
/// ticks once per second only while work is active, a retry counts down or a
/// folder row shows a spinner or caption. Reading status never affects ingestion.
@MainActor
final class IndexingStatusModel: ObservableObject {
    @Published private(set) var status: IndexingStatus?
    /// Searchable files of the notebook ("Searchable · N files"), read only when ready.
    @Published private(set) var searchableFiles = 0
    /// Folders whose persisted scan state is `scanning`.
    @Published private(set) var scanningFolders: Set<Int64> = []
    @Published private(set) var tracker = FolderScanTracker()
    /// Last failed Retry now / Build index / scan request (raw detail for the tooltip).
    @Published var actionError: String?

    private(set) var notebookId: Int64?
    private var store: NotebookStore?
    private var runtime: FolderIngestionRuntime?
    private var observers: [NSObjectProtocol] = []
    private var ticker: Task<Void, Never>?
    private var refreshing = false
    private var refreshAgain = false

    var presentationDot: Bool { IndexingStatusPresentation.showsPanelDot(status) }

    func isChecking(folderId: Int64) -> Bool {
        tracker.isPending(folderId) || scanningFolders.contains(folderId)
    }

    func warning(folderId: Int64) -> IndexingScanWarning? {
        status?.scanWarnings.first { $0.folderId == folderId }
    }

    /// Follows the shell's current notebook.
    func bind(notebookId: Int64?, store: NotebookStore, runtime: FolderIngestionRuntime?) {
        guard notebookId != self.notebookId || store !== self.store || observers.isEmpty else { return }
        unbind()
        self.notebookId = notebookId
        self.store = store
        self.runtime = runtime
        status = nil
        searchableFiles = 0
        scanningFolders = []
        tracker = FolderScanTracker()
        actionError = nil
        guard let notebookId else { return }
        for name in [Notification.Name.indexingStatusDidChange, .folderIngestionDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: store, queue: .main) { [weak self] note in
                guard (note.userInfo?["notebookId"] as? Int64) == notebookId else { return }
                MainActor.assumeIsolated { Task { await self?.refresh() } }
            })
        }
        Task { await refresh() }
    }

    func unbind() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        ticker?.cancel()
        ticker = nil
    }

    /// Re-reads status, scanning folders and pending scan outcomes (coalesced).
    func refresh() async {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            await load()
        } while refreshAgain
        updateTicker()
    }

    private func load() async {
        guard let notebookId, let store else { return }
        let next: IndexingStatus
        #if DEBUG
        if let qa = Self.qaStatus {
            status = qa
            searchableFiles = Self.qaSearchableFiles
            return
        }
        #endif
        if let runtime {
            do {
                next = try await runtime.indexingStatus(notebookId: notebookId)
            } catch {
                // A status that cannot be read is shown as a runtime failure (with Retry now).
                next = IndexingStatus(phase: .blocked(.runtimeFailed(code: Self.code(error))),
                                      sourceErrors: status?.sourceErrors ?? 0, scanWarnings: status?.scanWarnings ?? [])
            }
        } else {
            next = IndexingStatus(phase: .blocked(.runtimeFailed(code: "runtimeUnavailable")), sourceErrors: 0, scanWarnings: [])
        }
        guard notebookId == self.notebookId else { return }
        if case .ready = next.phase {
            searchableFiles = (try? store.coverage(notebookId: notebookId, scope: .all).searchable) ?? searchableFiles
        }
        status = next
        let folders = (try? store.folders(notebookId: notebookId)) ?? []
        scanningFolders = Set(folders.filter { $0.scanState == "scanning" }.map(\.id))
        let now = Date().timeIntervalSince1970
        var tracker = self.tracker
        for folderId in tracker.pendingFolderIds {
            guard folders.contains(where: { $0.id == folderId }) else { tracker.remove(folderId: folderId); continue }
            let outcome = await runtime?.lastScanOutcome(folderId: folderId)
            tracker.update(folderId: folderId, scanning: scanningFolders.contains(folderId), outcome: outcome, now: now)
        }
        tracker.expire(now: now)
        guard notebookId == self.notebookId else { return }
        if tracker != self.tracker { self.tracker = tracker }
    }

    /// Scan now / Verify all with an immediate "Checking…" on the folder row.
    func scan(folderId: Int64, verifyAll: Bool, folders: FolderSourcesModel) async {
        let previous = await runtime?.lastScanOutcome(folderId: folderId)
        tracker.begin(folderId: folderId, now: Date().timeIntervalSince1970, previous: previous)
        updateTicker()
        if !(await folders.scan(id: folderId, verifyAll: verifyAll)) { tracker.cancel(folderId: folderId) }
        await refresh()
    }

    /// Retry now / Build index.
    func retryNow() async {
        guard let notebookId, let runtime else { return }
        do {
            try await runtime.retryIndexingNow(notebookId: notebookId)
            actionError = nil
        } catch {
            actionError = String(describing: error)
        }
        await refresh()
    }

    /// "Retry all failed" in the "N files couldn't be read" view (`ingestion-retry-cap-v1` §5).
    func retryAllFailed() async {
        guard let notebookId, let runtime else { return }
        do {
            _ = try await runtime.retryFailedSources(notebookId: notebookId)
            actionError = nil
        } catch {
            actionError = String(describing: error)
        }
        await refresh()
    }

    private func updateTicker() {
        let needed = (status?.isActive ?? false) || tracker.needsTicks
        if needed, ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    await self.refresh()
                }
            }
        } else if !needed, let ticker {
            ticker.cancel()
            self.ticker = nil
        }
    }

    private static func code(_ error: Error) -> String {
        (error as? IngestionError)?.code ?? (error as? StorageV19Error)?.code ?? "unexpectedError"
    }

    #if DEBUG
    /// Screenshot state: `-AINotebookQAIndexing <phase>` replaces the live status.
    static var qaStatus: IndexingStatus? {
        UserDefaults.standard.string(forKey: "AINotebookQAIndexing").flatMap(qaStatus(named:))
    }

    static let qaSearchableFiles = 1204

    static let qaPhases = ["scanning", "extracting", "embedding", "preparing", "retrying", "blockedNoModel",
                           "blockedProviderDisabled", "blockedConsent", "blockedCredential", "indexFailed",
                           "runtimeFailed", "ready", "lexicalOnly"]

    static func qaStatus(named name: String) -> IndexingStatus? {
        let phase: IndexingPhase
        switch name {
        case "scanning": phase = .scanning(filesSeen: 812)
        case "extracting": phase = .extracting(done: 37, total: 120)
        case "embedding": phase = .embedding(done: 1480, total: 4210, preparing: false)
        case "preparing": phase = .embedding(done: nil, total: nil, preparing: true)
        case "retrying": phase = .retrying(IndexingRetry(code: "connectionFailed", retryAt: 0, attempt: 2, retryInSeconds: 42))
        case "blockedNoModel": phase = .blocked(.noEmbeddingModel)
        case "blockedProviderDisabled": phase = .blocked(.providerDisabled)
        case "blockedConsent": phase = .blocked(.consentRequired)
        case "blockedCredential": phase = .blocked(.credentialUnavailable)
        case "indexFailed": phase = .blocked(.indexFailed(code: "dimensionMismatch"))
        case "runtimeFailed": phase = .blocked(.runtimeFailed(code: "unexpectedError"))
        case "ready": phase = .ready
        case "lexicalOnly": phase = .lexicalOnly
        default: return nil
        }
        return IndexingStatus(phase: phase, sourceErrors: name == "ready" || name == "extracting" ? 3 : 0, scanWarnings: [])
    }
    #endif
}

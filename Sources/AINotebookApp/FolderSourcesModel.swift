import Foundation
import AINotebookCore

/// One persisted folder with its scoped coverage snapshot.
struct FolderRow: Identifiable, Equatable {
    let folder: FolderSource
    let coverage: CoverageSnapshot
    var id: Int64 { folder.id }
}

/// Loaded members of one expanded folder (paged from the store, `rel_path` order).
struct FolderMembersState: Equatable {
    var members: [Source] = []
    var total = 0
    var isLoading = false
    var hasMore: Bool { !isLoading && members.count < total }
}

/// Presentation state for persisted folders. Store and runtime stay
/// process-wide; this model only reads snapshots and forwards commands.
@MainActor
final class FolderSourcesModel: ObservableObject {
    @Published private(set) var rows: [FolderRow] = []
    @Published var errorKey: AppText.Key?
    /// Expanded folders only; members are collapsed by default and loaded page by page.
    @Published private(set) var expanded: [Int64: FolderMembersState] = [:]
    /// Invoked with freshly loaded members (e.g. to load their summaries and tags).
    var onMembersLoaded: (([Source]) -> Void)?

    /// Every loaded member of every expanded folder.
    var loadedMembers: [Source] { expanded.values.flatMap(\.members) }

    private var store: NotebookStore?
    private var runtime: FolderIngestionRuntime?
    /// The notebook of the latest reload request; older loads never overwrite it.
    private var reloadToken: Int64?
    private var observer: NSObjectProtocol?
    private var pendingReload: Task<Void, Never>?
    /// Invoked after a coalesced change notification (e.g. to refresh sources).
    var onChange: (() async -> Void)?

    func configure(store: NotebookStore, runtime: FolderIngestionRuntime?) {
        self.store = store
        self.runtime = runtime
    }

    func reload(notebookId: Int64) async {
        reloadToken = notebookId
        guard let store else { return }
        do {
            let folders = try store.folders(notebookId: notebookId)
            let loaded = try folders.map { folder in
                FolderRow(folder: folder, coverage: try store.coverage(notebookId: notebookId,
                    scope: .selection(sourceIds: [], folderIds: [folder.id])))
            }
            guard reloadToken == notebookId else { return }
            rows = loaded
            try refreshExpanded(store: store, folderIds: Set(folders.map(\.id)))
        } catch {
            guard reloadToken == notebookId else { return }
            errorKey = Self.key(for: error)
        }
    }

    func isExpanded(_ id: Int64) -> Bool { expanded[id] != nil }

    /// Expands (loading the first page) or collapses one folder's member list.
    func toggle(folderId: Int64) {
        if expanded[folderId] != nil {
            expanded[folderId] = nil
        } else {
            expanded[folderId] = FolderMembersState()
            loadMore(folderId: folderId)
        }
    }

    /// Appends the next page of an expanded folder's members.
    func loadMore(folderId: Int64) {
        guard let store, var state = expanded[folderId], !state.isLoading else { return }
        state.isLoading = true
        expanded[folderId] = state
        do {
            let page = try store.folderMembers(folderId: folderId, offset: state.members.count,
                                               limit: NotebookStore.folderMembersPageSize)
            guard var current = expanded[folderId] else { return } // collapsed meanwhile
            current.members += page.members
            current.total = page.total
            current.isLoading = false
            expanded[folderId] = current
            onMembersLoaded?(page.members)
        } catch {
            if var current = expanded[folderId] { current.isLoading = false; expanded[folderId] = current }
            errorKey = Self.key(for: error)
        }
    }

    /// Re-reads the already loaded range of each expanded folder so status, availability and
    /// deletions show up; folders that no longer exist are dropped.
    private func refreshExpanded(store: NotebookStore, folderIds: Set<Int64>) throws {
        var refreshed: [Int64: FolderMembersState] = [:]
        for (id, state) in expanded where folderIds.contains(id) {
            let wanted = max(state.members.count, NotebookStore.folderMembersPageSize)
            var members: [Source] = []
            var total = 0
            while members.count < wanted {
                let page = try store.folderMembers(folderId: id, offset: members.count,
                                                   limit: min(NotebookStore.folderMembersMaxLimit, wanted - members.count))
                total = page.total
                members += page.members
                if page.members.isEmpty || !page.hasMore { break }
            }
            refreshed[id] = FolderMembersState(members: members, total: total)
        }
        expanded = refreshed
        onMembersLoaded?(loadedMembers)
    }

    func add(url: URL, notebookId: Int64) async {
        guard let runtime else { errorKey = .folderReadError; return }
        do { _ = try await runtime.addFolder(notebookId: notebookId, url: url) }
        catch { errorKey = Self.key(for: error) }
        await reload(notebookId: notebookId)
    }

    /// Requests a scan job; false when the request failed (the error is shown).
    @discardableResult
    func scan(id: Int64, verifyAll: Bool) async -> Bool {
        guard let runtime else { errorKey = .folderReadError; return false }
        do { _ = try await runtime.scanNow(folderId: id, verifyAll: verifyAll); return true }
        catch { errorKey = Self.key(for: error); return false }
    }

    /// "Retry" on a failed source (folder member or loose): its failure budget starts over (`ingestion-retry-cap-v1` §5).
    func retry(sourceId: Int64) async {
        guard let runtime else { errorKey = .folderReadError; return }
        do { _ = try await runtime.retryFailedSource(sourceId: sourceId) }
        catch { errorKey = Self.key(for: error) }
    }

    func setWatching(id: Int64, enabled: Bool) async {
        guard let runtime else { return }
        do { try await runtime.setWatching(folderId: id, enabled: enabled) }
        catch { errorKey = Self.key(for: error) }
        if let token = reloadToken { await reload(notebookId: token) }
    }

    func remove(id: Int64) async {
        guard let runtime else { return }
        do { try await runtime.removeFolder(folderId: id) }
        catch { errorKey = Self.key(for: error) }
        if let token = reloadToken { await reload(notebookId: token) }
    }

    func applyRules(id: Int64, rules: FolderRules) async throws {
        guard let runtime else { throw IngestionError(code: "rootUnavailable") }
        try await runtime.applyRules(folderId: id, rules: rules)
        if let token = reloadToken { await reload(notebookId: token) }
    }

    func validate(id: Int64, rules: FolderRules) async -> Bool {
        guard let runtime else { return false }
        return await runtime.validateRules(folderId: id, rules: rules)
    }

    /// Subscribes to committed ingestion changes for this store and notebook
    /// while the view is visible; reloads are coalesced.
    func subscribe(notebookId: Int64) {
        unsubscribe()
        guard let store else { return }
        observer = NotificationCenter.default.addObserver(forName: .folderIngestionDidChange, object: store, queue: .main) { [weak self] note in
            guard (note.userInfo?["notebookId"] as? Int64) == notebookId else { return }
            MainActor.assumeIsolated { self?.scheduleReload(notebookId: notebookId) }
        }
    }

    func unsubscribe() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        pendingReload?.cancel()
        pendingReload = nil
    }

    private func scheduleReload(notebookId: Int64) {
        guard pendingReload == nil else { return }
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.pendingReload = nil
            await self.reload(notebookId: notebookId)
            await self.onChange?()
        }
    }

    /// Persisted error codes are localized here; raw codes never reach the UI.
    static func key(for error: Error) -> AppText.Key {
        if let error = error as? StorageV19Error, error == .overlappingRoot { return .folderOverlapError }
        let code = (error as? IngestionError)?.code ?? (error as? StorageV19Error)?.code ?? ""
        return key(code: code)
    }

    static func key(code: String) -> AppText.Key {
        switch code {
        case "overlappingRoot": return .folderOverlapError
        case "fileLimit", "officeLimit", "textLimit", "pageLimit", "chunkLimit", "cellLimit": return .folderLimitError
        case "unsupportedEncoding": return .folderEncodingError
        case "corruptArchive", "invalidRelationship", "invalidCell", "unsupportedSyntax": return .folderDocumentError
        default: return .folderReadError
        }
    }
}

import Foundation
import AINotebookCore

/// Epic E1 (App layer) — owns the live `FolderWatcher` for one notebook and
/// turns its "something changed" callbacks into `LiveSourceSync.syncFolder`
/// runs. Parity with the Windows `FolderWatchService`, which keeps the same
/// state in the same shape.
///
/// SwiftUI recreates `SourceListView` on every redraw, so the watcher cannot
/// live in the view — it is held here as a `@StateObject` instead. Watching is
/// in-memory and per-session: closing the app stops it, exactly as on Windows.
@MainActor
final class FolderWatchController: ObservableObject {

    @Published private(set) var watchedFolder: URL?
    @Published private(set) var isSyncing = false
    @Published var errorMessage: String?

    var isWatching: Bool { watchedFolder != nil }

    private var watcher: FolderWatcher?
    private var syncTask: Task<Void, Never>?

    /// Starts watching `folder` and runs one sync immediately, so turning the
    /// switch on picks up everything already sitting in the folder rather than
    /// only future edits.
    func start(
        folder: URL,
        sync: @escaping @Sendable @MainActor (URL) async -> Void
    ) {
        stop()
        let watcher = FolderWatcher(folder: folder) { [weak self] in
            // Called on the watcher's queue; hop to the main actor because the
            // sync it triggers touches the store.
            Task { @MainActor [weak self] in
                await self?.runSync(folder: folder, sync: sync)
            }
        }
        do {
            try watcher.start()
            self.watcher = watcher
            self.watchedFolder = folder
            Task { await runSync(folder: folder, sync: sync) }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func stop() {
        syncTask?.cancel()
        syncTask = nil
        watcher?.stop()
        watcher = nil
        watchedFolder = nil
        isSyncing = false
    }

    deinit {
        // `watcher` is not main-actor-isolated, so it can be stopped from here
        // without hopping actors.
        watcher?.stop()
    }

    /// Runs one sync, dropping the request if one is already in flight — a
    /// burst of edits must not stack up re-ingestions of the same folder.
    private func runSync(
        folder: URL,
        sync: @escaping @Sendable @MainActor (URL) async -> Void
    ) async {
        guard !isSyncing else { return }
        isSyncing = true
        await sync(folder)
        isSyncing = false
    }
}

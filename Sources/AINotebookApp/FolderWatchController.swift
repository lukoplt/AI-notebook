import AppKit
import Foundation
import AINotebookCore

/// The app-owned holder of the single process-wide `FolderIngestionRuntime`.
/// The runtime owns every native watch (indexed by folder ID), debouncing,
/// scans and extraction; views reach it through this environment object.
@MainActor
final class FolderWatchController: ObservableObject {
    /// Installed once by the app before any view is created.
    static var installedRuntime: FolderIngestionRuntime?

    let runtime: FolderIngestionRuntime?

    @Published var errorMessage: String?

    private var terminationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init(runtime: FolderIngestionRuntime? = FolderWatchController.installedRuntime) {
        self.runtime = runtime
    }

    /// Starts the runtime once per process. Memory pressure needs no wiring
    /// here: the runtime samples the kernel level on every scheduler tick, so
    /// a missed or reordered pressure notification cannot pause extraction.
    /// Called from app construction, never from a window's view.
    func startProcessRuntime() {
        guard let runtime else { return }
        Task {
            do { try await runtime.start() }
            catch { self.errorMessage = String(describing: error) }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            // Best effort: durable leases are recovered on the next launch anyway.
            Task { await runtime.stop() }
        }
        // Watches may miss events while asleep: one stat-only rescan per watched folder
        // (contract ingestion-scan-perf-v1 §4).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { await runtime.systemDidWake() }
        }
    }
}

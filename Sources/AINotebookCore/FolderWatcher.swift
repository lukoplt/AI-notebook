import Foundation
import CoreServices

/// Epic E1 — watches a folder and reports that *something* changed, so the
/// caller can re-run `LiveSourceSync.syncFolder`. Parity with the Windows
/// `FolderWatchService`, which wraps `FileSystemWatcher` the same way.
///
/// FSEvents rather than a `DispatchSource` on the directory descriptor: a
/// directory source only fires when entries are added, removed or renamed, so
/// editing a file already inside the folder — the main case E1 exists for —
/// would go unnoticed. `kFSEventStreamCreateFlagFileEvents` reports individual
/// file writes.
///
/// The callback deliberately carries no payload. Deciding what actually
/// changed is `LiveSourceSync`'s job, and it does it by comparing content
/// hashes, which is both cheaper to reason about and immune to the events
/// FSEvents coalesces or drops.
public final class FolderWatcher: @unchecked Sendable {

    public enum WatchError: Error, Equatable {
        case couldNotCreateStream(path: String)
    }

    public let folder: URL

    /// How long FSEvents may batch events before delivering them.
    private let latency: CFTimeInterval
    /// Extra quiet period after the last event, so a burst of writes (an
    /// editor saving, an archive unpacking) triggers one sync rather than
    /// dozens.
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void

    private let queue = DispatchQueue(label: "com.ainotebook.folderwatcher")
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    public init(
        folder: URL,
        latency: TimeInterval = 0.2,
        debounce: TimeInterval = 0.4,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.folder = folder
        self.latency = latency
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { stopStream() }

    public var isWatching: Bool {
        queue.sync { stream != nil }
    }

    /// Starts watching. Calling it again while already watching is a no-op.
    public func start() throws {
        try queue.sync {
            guard stream == nil else { return }

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            // No kFSEventStreamCreateFlagIgnoreSelf: it suppresses events
            // caused by this process, which would silently drop changes
            // whenever the app itself touches the watched folder. Windows'
            // FileSystemWatcher has no such filter either, so leaving it off
            // keeps the two platforms behaving alike.
            let flags = UInt32(
                kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
            )
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, _, _, _, _ in
                    guard let info else { return }
                    Unmanaged<FolderWatcher>.fromOpaque(info)
                        .takeUnretainedValue()
                        .scheduleChange()
                },
                &context,
                // FSEvents reports canonical paths, so a watch registered on
                // a symlinked path (/var/... rather than /private/var/...)
                // never matches the events it is delivered.
                [folder.resolvingSymlinksInPath().path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            ) else {
                throw WatchError.couldNotCreateStream(path: folder.path)
            }

            // Dispatch queue rather than a run loop: the watcher has to work
            // from a plain background context, not only from the main thread.
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
        }
    }

    /// Stops watching and drops any sync that was still waiting out the
    /// debounce. Safe to call repeatedly, and safe before `start()`.
    public func stop() {
        queue.sync {
            pending?.cancel()
            pending = nil
        }
        stopStream()
    }

    private func stopStream() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// Called on `queue` from the FSEvents callback.
    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Already on `queue`, so this touches `pending` safely.
            self.pending = nil
            self.onChange()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}

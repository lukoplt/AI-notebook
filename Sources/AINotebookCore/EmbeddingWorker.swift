import Foundation

/// Long-running task that runs on every kick: in production it wakes the
/// durable runtime's generation work; isolated tests may drive the legacy
/// `Embedder.embedAllPending`. `kick()` is idempotent: while a drain is in flight, additional
/// kicks set a "drain again when this finishes" flag.
public actor EmbeddingWorker {
    private let embedder: Embedder?
    /// Production: wakes durable generation work in the folder runtime. When
    /// set, the legacy embedder never runs, so nothing is embedded twice.
    private let wake: (@Sendable () async throws -> Void)?
    private var inFlight: Task<Void, Never>?
    private var pendingKick = false

    public private(set) var lastError: Error?
    public private(set) var totalEmbedded: Int = 0

    public init(embedder: Embedder) {
        self.embedder = embedder
        self.wake = nil
    }

    public init(wake: @escaping @Sendable () async throws -> Void) {
        self.embedder = nil
        self.wake = wake
    }

    public func kick() {
        if inFlight == nil {
            inFlight = Task { [weak self] in
                await self?.drain()
            }
        } else {
            pendingKick = true
        }
    }

    private func drain() async {
        repeat {
            pendingKick = false
            do {
                if let wake {
                    try await wake()
                } else if let embedder {
                    let n = try await embedder.embedAllPending()
                    totalEmbedded += n
                }
                lastError = nil
            } catch {
                lastError = error
            }
        } while pendingKick
        inFlight = nil
    }

    /// Test-only: wait until the current drain finishes (returns immediately
    /// if no drain is in flight).
    public func waitUntilIdle() async {
        if let task = inFlight {
            _ = await task.value
        }
    }
}

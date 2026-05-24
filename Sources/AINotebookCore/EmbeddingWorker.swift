import Foundation

/// Long-running task that runs `Embedder.embedAllPending` whenever it's
/// kicked. `kick()` is idempotent: while a drain is in flight, additional
/// kicks set a "drain again when this finishes" flag.
public actor EmbeddingWorker {
    private let embedder: Embedder
    private var inFlight: Task<Void, Never>?
    private var pendingKick = false

    public private(set) var lastError: Error?
    public private(set) var totalEmbedded: Int = 0

    public init(embedder: Embedder) {
        self.embedder = embedder
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
                let n = try await embedder.embedAllPending()
                totalEmbedded += n
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

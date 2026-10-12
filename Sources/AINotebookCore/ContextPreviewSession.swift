import Foundation

/// Window-local preview bytes. Reads preserve FIFO order and no state is persisted.
public actor ContextPreviewSession {
    private struct Entry {
        let sessionId: Int64
        let assistantId: Int64
        let bytes: Data
    }

    /// Test/diagnostic accounting does not expose or retain another payload graph.
    struct EntryState: Sendable {
        let sessionId: Int64
        let assistantId: Int64
        let byteCount: Int
    }

    struct State: Sendable {
        let entries: [EntryState]
        let retainedBytes: Int
        let draftBytes: Int
        let draftReady: Bool
        let draftSessionId: Int64?
        let generation: UInt64
    }

    private let maxTurns: Int
    private let maxBytes: Int
    private var entries: [Entry] = []
    private var draftBytes: Data?
    private var draftKey: Data?
    private var draftSessionId: Int64?
    private var generation: UInt64 = 0

    public init(maxTurns: Int = RagContractV1.Pack.previewTurnsInMemory,
                maxBytes: Int = Int(RagContractV1.Pack.previewMaxBytes)) {
        precondition(maxTurns > 0, "Preview turn limit must be positive")
        precondition(maxBytes >= 0, "Preview byte limit must be nonnegative")
        self.maxTurns = maxTurns
        self.maxBytes = maxBytes
    }

    /// Includes the current ready draft as well as sent previews in every session.
    public var retainedBytes: Int {
        // All externally observable states have already passed trimToByteLimit.
        entries.reduce(draftBytes?.count ?? 0) { $0 + $1.bytes.count }
    }

    var state: State {
        State(entries: entries.map {
            EntryState(sessionId: $0.sessionId, assistantId: $0.assistantId, byteCount: $0.bytes.count)
        }, retainedBytes: retainedBytes, draftBytes: draftBytes?.count ?? 0,
              draftReady: draftBytes != nil, draftSessionId: draftSessionId, generation: generation)
    }

    public func beginDraft(sessionId: Int64, key: Data) -> UInt64 {
        precondition(key.count == 32, "Preview intent keys must be SHA-256 digests")
        advanceGeneration()
        draftSessionId = sessionId
        draftKey = key
        draftBytes = nil
        return generation
    }

    public func completeDraft(generation: UInt64, key: Data, bytes: Data) -> Bool {
        precondition(key.count == 32, "Preview intent keys must be SHA-256 digests")
        guard generation == self.generation, key == draftKey, bytes.count <= maxBytes else { return false }
        draftBytes = bytes
        trimToByteLimit()
        return true
    }

    public func draft(key: Data) -> Data? {
        precondition(key.count == 32, "Preview intent keys must be SHA-256 digests")
        return key == draftKey ? draftBytes : nil
    }

    public func invalidateDraft() {
        advanceGeneration()
        draftBytes = nil
        draftKey = nil
        draftSessionId = nil
    }

    @discardableResult
    public func retain(_ bytes: Data, sessionId: Int64, assistantId: Int64) -> Bool {
        // Rejected replacements leave the existing preview and FIFO untouched.
        guard bytes.count <= maxBytes else { return false }
        entries.removeAll { $0.sessionId == sessionId && $0.assistantId == assistantId }
        entries.append(Entry(sessionId: sessionId, assistantId: assistantId, bytes: bytes))
        while entries.lazy.filter({ $0.sessionId == sessionId }).count > maxTurns {
            entries.remove(at: entries.firstIndex { $0.sessionId == sessionId }!)
        }
        trimToByteLimit()
        return entries.contains { $0.sessionId == sessionId && $0.assistantId == assistantId }
    }

    public func sent(sessionId: Int64, assistantId: Int64) -> Data? {
        entries.first { $0.sessionId == sessionId && $0.assistantId == assistantId }?.bytes
    }

    /// Transfers a ready draft atomically, without charging its bytes twice.
    @discardableResult
    public func promoteDraft(sessionId: Int64, assistantId: Int64) -> Bool {
        guard draftSessionId == sessionId, let bytes = draftBytes else { return false }
        invalidateDraft()
        return retain(bytes, sessionId: sessionId, assistantId: assistantId)
    }

    public func clear(sessionId: Int64) {
        entries.removeAll { $0.sessionId == sessionId }
        if draftSessionId == sessionId { invalidateDraft() }
    }

    private func advanceGeneration() {
        let next = generation.addingReportingOverflow(1)
        precondition(!next.overflow, "Preview generation exhausted")
        generation = next.partialValue
    }

    private func trimToByteLimit() {
        // Keep the newest suffix that fits, exactly as repeated oldest eviction
        // would. Subtraction avoids overflowing an intermediate byte total when
        // callers choose a limit near Int.max.
        var available = maxBytes - (draftBytes?.count ?? 0)
        for index in entries.indices.reversed() {
            guard entries[index].bytes.count <= available else {
                entries.removeFirst(index + 1)
                return
            }
            available -= entries[index].bytes.count
        }
    }
}

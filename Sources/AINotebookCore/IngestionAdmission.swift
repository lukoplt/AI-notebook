import Foundation

/// System memory pressure as extraction admission sees it (contract
/// `ingestion-memory-pressure-v1`): `warning` admits one concurrent
/// extraction, `critical` pauses new extractions, `normal` restores the limit.
public enum MemoryPressureLevel: String, Sendable, Equatable, CaseIterable {
    case normal
    case warning
    case critical

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical;
    /// anything else (including a failed read) is normal (fail open).
    public static func darwin(rawLevel: Int) -> MemoryPressureLevel {
        switch rawLevel {
        case 2: return .warning
        case 4: return .critical
        default: return .normal
        }
    }

    /// Samples the kernel's current pressure level (the state the
    /// `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source reports). A failed read is normal.
    public static func sampleDarwin() -> MemoryPressureLevel {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return .normal }
        return darwin(rawLevel: Int(value))
    }

    /// Windows `MEMORYSTATUSEX.dwMemoryLoad` percent: ≥ 95 critical, ≥ 85 warning.
    public static func memoryLoad(percent: Int) -> MemoryPressureLevel {
        percent >= 95 ? .critical : percent >= 85 ? .warning : .normal
    }

    /// Concurrent extractions admitted at this level.
    func concurrency(maxExtractions: Int) -> Int {
        switch self {
        case .normal: return maxExtractions
        case .warning: return min(1, maxExtractions)
        case .critical: return 0
        }
    }
}

/// Bounds admitted background work: at most `maxExtractions` concurrent
/// extractions within a deterministic memory budget, FIFO and cancellable.
/// Memory pressure lowers the concurrency limit (warning → 1, critical → 0)
/// and the adaptive limit (addendum A) bounds it further; neither revokes
/// granted permits.
/// Chat tokens hold back the *next* background embedding batch; question
/// embeddings never consult this gate. This bounds admitted work, not
/// undocumented allocations inside PDFKit.
public actor IngestionAdmission {
    nonisolated public let maxExtractions: Int
    nonisolated public let memoryBytes: Int64

    private struct Waiter {
        let token: UUID
        let bytes: Int64
        let continuation: CheckedContinuation<Void, Error>
    }
    private var reservations: [(token: UUID, bytes: Int64)] = []
    private var waiters: [Waiter] = []
    private var chatTokens: [UUID] = []
    private var backgroundWaiters: [(token: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var pressure: MemoryPressureLevel = .normal
    /// The adaptive limit (addendum A), `1…maxExtractions`; starts at `maxExtractions`.
    private var limit: Int

    public init(maxExtractions: Int = 2, memoryBytes: Int64 = 536_870_912) {
        precondition(maxExtractions > 0 && memoryBytes > 0)
        self.maxExtractions = maxExtractions
        self.memoryBytes = memoryBytes
        limit = maxExtractions
    }

    /// The production admission for this machine (addendum A §A.2): half the
    /// logical cores (1…6) and 6 % of physical memory (512 MiB…1 GiB).
    public static func standard(processInfo: ProcessInfo = .processInfo) -> IngestionAdmission {
        IngestionAdmission(maxExtractions: AdaptiveConcurrency.maxWorkers(cores: processInfo.activeProcessorCount),
                           memoryBytes: AdaptiveConcurrency.memoryBudget(physicalBytes: Int64(clamping: processInfo.physicalMemory)))
    }

    /// Conservative reservation for one extraction: text `min(file,limit)×4 +
    /// scalars×8 + chunks×256`; Office/PDF add the expanded-bytes allowance.
    /// Saturates instead of overflowing; `acquire` caps it at the budget.
    public static func reservation(kind: SourceType, fileBytes: Int64, limits: IngestionLimits) -> Int64 {
        func add(_ a: Int64, _ b: Int64) -> Int64 { let (v, o) = a.addingReportingOverflow(b); return o ? .max : v }
        func mul(_ a: Int64, _ b: Int64) -> Int64 { let (v, o) = a.multipliedReportingOverflow(by: b); return o ? .max : v }
        var total = mul(min(max(fileBytes, 0), limits.fileBytes), 4)
        total = add(total, mul(Int64(limits.textScalars), 8))
        total = add(total, mul(Int64(limits.chunks), 256))
        switch kind {
        case .docx, .pptx, .xlsx, .pdf: total = add(total, limits.officeBytes)
        default: break
        }
        return total
    }

    public func acquireExtraction(bytes: Int64) async throws -> UUID {
        let token = UUID()
        try await acquireExtraction(bytes: bytes, token: token)
        return token
    }

    /// A request larger than the budget runs alone, reserving the whole budget.
    func acquireExtraction(bytes: Int64, token: UUID) async throws {
        try Task.checkCancellation()
        let amount = min(max(bytes, 0), memoryBytes)
        if waiters.isEmpty && canGrant(amount) {
            reservations.append((token, amount))
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(Waiter(token: token, bytes: amount, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(token) }
        }
    }

    /// Idempotent: releasing an unknown or already released token does nothing.
    public func releaseExtraction(_ token: UUID) {
        reservations.removeAll { $0.token == token }
        drain()
    }

    /// The frozen folder-rag-v1 boolean form: `true` = critical, `false` = normal.
    public func setMemoryPressure(_ blocked: Bool) {
        setMemoryPressure(blocked ? .critical : .normal)
    }

    /// Applies the current level; lower pressure drains waiters in FIFO order.
    public func setMemoryPressure(_ level: MemoryPressureLevel) {
        pressure = level
        drain()
    }

    /// The level last applied (indexing status runtime fact).
    public var memoryPressureLevel: MemoryPressureLevel { pressure }

    /// Applies the adaptive concurrency limit (clamped to `1…maxExtractions`).
    /// Lowering never revokes granted permits; raising drains waiters in FIFO order.
    public func setConcurrencyLimit(_ value: Int) {
        limit = min(max(value, 1), maxExtractions)
        drain()
    }

    /// The adaptive limit last applied.
    public var concurrencyLimit: Int { limit }

    /// Extractions currently holding a permit.
    public var runningExtractions: Int { reservations.count }

    public func beginChat() -> UUID {
        let token = UUID()
        beginChat(token: token)
        return token
    }

    func beginChat(token: UUID) {
        if !chatTokens.contains(token) { chatTokens.append(token) }
    }

    public func endChat(_ token: UUID) {
        chatTokens.removeAll { $0 == token }
        guard chatTokens.isEmpty else { return }
        let ready = backgroundWaiters
        backgroundWaiters = []
        for waiter in ready { waiter.continuation.resume() }
    }

    /// Call immediately before every background embedding batch. A batch
    /// already sent may finish; the next one waits while any chat is active.
    public func waitForBackgroundBatch() async throws {
        try await waitForBackgroundBatch(token: UUID())
    }

    func waitForBackgroundBatch(token: UUID) async throws {
        try Task.checkCancellation()
        guard !chatTokens.isEmpty else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                backgroundWaiters.append((token, continuation))
            }
        } onCancel: {
            Task { await self.cancelBackgroundWaiter(token) }
        }
    }

    struct Snapshot: Equatable, Sendable {
        let reservations: [Reservation]
        let waiters: [Reservation]
        let chatTokens: [UUID]
        let backgroundWaiters: [UUID]
        let level: MemoryPressureLevel
        var limit: Int = 0
        /// Any pressure (folder-rag-v1 traces only use the boolean form).
        var memoryPressure: Bool { level != .normal }
        struct Reservation: Equatable, Sendable { let token: UUID; let bytes: Int64 }
    }

    func snapshot() -> Snapshot {
        Snapshot(reservations: reservations.map { .init(token: $0.token, bytes: $0.bytes) },
                 waiters: waiters.map { .init(token: $0.token, bytes: $0.bytes) },
                 chatTokens: chatTokens, backgroundWaiters: backgroundWaiters.map(\.token),
                 level: pressure, limit: limit)
    }

    private func canGrant(_ amount: Int64) -> Bool {
        guard reservations.count < min(limit, pressure.concurrency(maxExtractions: maxExtractions)) else { return false }
        let used = reservations.reduce(Int64(0)) { $0 + $1.bytes }
        return amount <= memoryBytes - used
    }

    /// Strict FIFO: a blocked head waiter is never overtaken.
    private func drain() {
        while let first = waiters.first, canGrant(first.bytes) {
            waiters.removeFirst()
            reservations.append((first.token, first.bytes))
            first.continuation.resume()
        }
    }

    private func cancelWaiter(_ token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        drain()
    }

    private func cancelBackgroundWaiter(_ token: UUID) {
        guard let index = backgroundWaiters.firstIndex(where: { $0.token == token }) else { return }
        backgroundWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

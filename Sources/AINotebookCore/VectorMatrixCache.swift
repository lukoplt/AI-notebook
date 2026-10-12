import Foundation

/// The ledger includes allocated capacity, live invalidated entries and fills.
internal struct MatrixBudget {
    let limit: Int64
    private(set) var resident: Int64 = 0
    private(set) var reserved: Int64 = 0

    static func charge(rows: Int, dims: Int) -> Int64? {
        guard rows > 0, dims > 0 else { return nil }
        let (floats, a) = Int64(dims).multipliedReportingOverflow(by: 4)
        let (width, b) = floats.addingReportingOverflow(32)
        let (bytes, c) = Int64(rows).multipliedReportingOverflow(by: width)
        return a || b || c ? nil : bytes
    }
    mutating func reserve(_ bytes: Int64) -> Bool {
        guard bytes > 0, bytes <= limit, resident <= limit - bytes,
              reserved <= limit - bytes - resident else { return false }
        reserved += bytes
        return true
    }
    mutating func commit(_ bytes: Int64) {
        precondition(reserved >= bytes)
        reserved -= bytes
        resident += bytes
    }
    /// Re-charges bytes that were resident a moment ago (compaction never grows them).
    mutating func commitUnchecked(_ bytes: Int64) { resident += bytes }
    mutating func abandon(_ bytes: Int64) {
        precondition(reserved >= bytes)
        reserved -= bytes
    }
    mutating func dropResident(_ bytes: Int64) {
        precondition(resident >= bytes)
        resident -= bytes
    }
}

public struct VectorCacheStatistics: Sendable {
    public let residentBytes: Int64
    public let reservedBytes: Int64
    public let loadCount: Int
    public let entryCount: Int

    public init(residentBytes: Int64, reservedBytes: Int64, loadCount: Int, entryCount: Int) {
        self.residentBytes = residentBytes
        self.reservedBytes = reservedBytes
        self.loadCount = loadCount
        self.entryCount = entryCount
    }
}

internal enum VectorMatrixBuildError: Error, Equatable, Sendable {
    case capacityExceeded, invalidPage, sealedBuilder
}

/// Exact-capacity allocation. Only the builder writes, before transferring the
/// storage to the cache. After that transfer every buffer is immutable.
private final class VectorMatrixStorage: @unchecked Sendable {
    let capacity: Int
    let dims: Int
    let slab: UnsafeMutableBufferPointer<Float>
    let chunkIds: UnsafeMutableBufferPointer<Int64>
    let sourceIds: UnsafeMutableBufferPointer<Int64>
    let revisionIds: UnsafeMutableBufferPointer<Int64>
    let ordinals: UnsafeMutableBufferPointer<Int64>
    var count = 0

    init(capacity: Int, dims: Int) {
        self.capacity = capacity
        self.dims = dims
        slab = .allocate(capacity: capacity * dims)
        chunkIds = .allocate(capacity: capacity)
        sourceIds = .allocate(capacity: capacity)
        revisionIds = .allocate(capacity: capacity)
        ordinals = .allocate(capacity: capacity)
        slab.initialize(repeating: 0)
        chunkIds.initialize(repeating: 0)
        sourceIds.initialize(repeating: 0)
        revisionIds.initialize(repeating: 0)
        ordinals.initialize(repeating: 0)
    }
    deinit {
        slab.deinitialize(); slab.deallocate()
        chunkIds.deinitialize(); chunkIds.deallocate()
        sourceIds.deinitialize(); sourceIds.deallocate()
        revisionIds.deinitialize(); revisionIds.deallocate()
        ordinals.deinitialize(); ordinals.deallocate()
    }

    func topK(query: [Float], permittedSources: Set<Int64>, k: Int) -> [ScoredChunk] {
        guard var top = MaskedVectorTopK(query: query, dims: dims,
                                        permittedSources: permittedSources, k: k) else { return [] }
        // One borrowed slab, no per-row array or copy of the matrix.
        for index in 0..<count {
            guard permittedSources.contains(sourceIds[index]) else { continue }
            let reference = ChunkReference(chunkId: chunkIds[index], sourceId: sourceIds[index],
                                           revisionId: revisionIds[index], ord: Int(ordinals[index]))
            top.offer(reference, normalizedRow: UnsafeBufferPointer(
                start: slab.baseAddress!.advanced(by: index * dims), count: dims))
        }
        return top.sorted()
    }
}

private struct SealedVectorMatrix: Sendable {
    let storage: VectorMatrixStorage
    let invalidVectorCount: Int
    let peakPageBytes: Int64
}

/// The fill worker exclusively owns the loading buffer. The lock also fences
/// publication/discard, so a retained builder cannot mutate or retain a matrix
/// after its fill finishes. No lock is held across an await.
public final class VectorMatrixBuilder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: VectorMatrixStorage?
    private var attemptedRows = 0
    private var invalidVectors = 0
    private var peakBytes: Int64 = 0

    fileprivate init(rowCount: Int, dims: Int) {
        storage = VectorMatrixStorage(capacity: rowCount, dims: dims)
    }

    public func append(_ page: [VectorRow]) throws {
        try lock.withLock {
            guard let storage else { throw VectorMatrixBuildError.sealedBuilder }
            guard page.count <= storage.capacity - attemptedRows else {
                throw VectorMatrixBuildError.capacityExceeded
            }
            guard page.count <= 1024 else { throw VectorMatrixBuildError.invalidPage }
            var bytes: Int64 = 0
            for row in page {
                let (width, overflow) = Int64(row.values.count).multipliedReportingOverflow(by: 4)
                guard !overflow, width <= 8_388_608 - bytes else { throw VectorMatrixBuildError.invalidPage }
                bytes += width
            }
            peakBytes = max(peakBytes, bytes)
            attemptedRows += page.count
            for row in page {
                guard row.values.count == storage.dims else {
                    invalidVectors += 1
                    continue
                }
                let start = storage.slab.baseAddress!.advanced(by: storage.count * storage.dims)
                let target = UnsafeMutableBufferPointer(start: start, count: storage.dims)
                for index in row.values.indices { target[index] = row.values[index] }
                guard MaskedVectorTopK.normalize(target, allowZero: true) else {
                    invalidVectors += 1
                    continue
                }
                let index = storage.count
                storage.chunkIds[index] = row.reference.chunkId
                storage.sourceIds[index] = row.reference.sourceId
                storage.revisionIds[index] = row.reference.revisionId
                storage.ordinals[index] = Int64(row.reference.ord)
                storage.count += 1
            }
        }
    }

    /// Raw SQL pages may discard malformed BLOBs before creating VectorRow.
    internal func recordInvalidVectors(_ count: Int) {
        lock.withLock {
            guard storage != nil, count > 0 else { return }
            let (sum, overflow) = invalidVectors.addingReportingOverflow(count)
            invalidVectors = overflow ? Int.max : sum
        }
    }
    internal func recordPageBytes(_ bytes: Int) {
        lock.withLock {
            guard storage != nil, bytes >= 0 else { return }
            peakBytes = max(peakBytes, Int64(bytes))
        }
    }

    fileprivate func seal() throws -> SealedVectorMatrix {
        try lock.withLock {
            guard let storage else { throw VectorMatrixBuildError.sealedBuilder }
            self.storage = nil
            return SealedVectorMatrix(storage: storage, invalidVectorCount: invalidVectors,
                                      peakPageBytes: peakBytes)
        }
    }
    fileprivate func discard() { lock.withLock { storage = nil } }
}

/// Immutable storage plus a lock-protected lease. Scoring holds only this
/// lease's lock, preventing concurrent close from uncharging live buffers.
public final class VectorMatrixLease: @unchecked Sendable {
    public let invalidVectorCount: Int
    public let peakPageBytes: Int64
    private let lock = NSLock()
    private var storage: VectorMatrixStorage?
    private let cache: VectorMatrixCache
    private let entryId: UUID

    fileprivate init(matrix: SealedVectorMatrix, cache: VectorMatrixCache, entryId: UUID) {
        storage = matrix.storage
        invalidVectorCount = matrix.invalidVectorCount
        peakPageBytes = matrix.peakPageBytes
        self.cache = cache
        self.entryId = entryId
    }
    public func topK(query: [Float], permittedSources: Set<Int64>, k: Int) -> [ScoredChunk] {
        lock.withLock { storage?.topK(query: query, permittedSources: permittedSources, k: k) ?? [] }
    }
    private func takeClose() -> Bool {
        lock.withLock {
            guard storage != nil else { return false }
            storage = nil
            return true
        }
    }
    public func close() async {
        if takeClose() { await cache.release(entryId) }
    }
    deinit {
        if takeClose() {
            let cache = cache, entryId = entryId
            Task { await cache.release(entryId) }
        }
    }
}

/// A synchronous flag closes the cancellation-before-registration race. The
/// cache actor still owns all waiter and reservation state.
private final class MatrixWaiterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.withLock { value = true } }
    var isCancelled: Bool { lock.withLock { value } }
}

/// Identity of one generation's resident matrix: the database identity, the store instance
/// that opened it (renewed on every open, so a reopened or restored file never inherits
/// rows), notebook, generation and dims.
public struct ResidentMatrixKey: Hashable, Sendable {
    public let databaseId: String
    public let databaseInstance: String
    public let notebookId: Int64
    public let generationId: Int64
    public let dims: Int
    public init(databaseId: String, databaseInstance: String, notebookId: Int64, generationId: Int64, dims: Int) {
        self.databaseId = databaseId
        self.databaseInstance = databaseInstance
        self.notebookId = notebookId
        self.generationId = generationId
        self.dims = dims
    }
}

/// Result of one resident scoring call: nil from `residentTopK` means "stream instead".
internal struct ResidentScan: Sendable {
    let scored: [ScoredChunk]
    let invalidVectorCount: Int
    let peakPageBytes: Int64
}

public actor VectorMatrixCache {
    /// The process-wide cache scales its budget with physical memory (retrieval-resident-v1 §4).
    public static let shared: VectorMatrixCache = {
        let cache = VectorMatrixCache(budgetBytes: residentBudget(physicalMemory: ProcessInfo.processInfo.physicalMemory))
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
        source.setEventHandler { Task { await cache.trimResidents() } }
        source.resume()
        pressureSource = source
        return cache
    }()
    nonisolated(unsafe) private static var pressureSource: DispatchSourceMemoryPressure?

    /// clamp(physical / 16, globalBudgetBytes, 1 GiB): 512 MiB on 8 GB, 1 GiB on >= 16 GB.
    public static func residentBudget(physicalMemory: UInt64) -> Int64 {
        let sixteenth = Int64(clamping: physicalMemory / 16)
        return min(max(sixteenth, RagContractV1.Cache.globalBudgetBytes), 1 << 30)
    }

    private struct Entry {
        let key: RetrievalCacheKey
        let bytes: Int64
        let matrix: SealedVectorMatrix
        var leases: Int
        var tick: UInt64
        var invalidated = false
    }
    private struct Waiter {
        let cancellation: MatrixWaiterCancellation
        let continuation: CheckedContinuation<VectorMatrixLease?, any Error>
    }
    private struct Loading {
        let key: RetrievalCacheKey
        let bytes: Int64
        let builder: VectorMatrixBuilder
        let epoch: @Sendable () -> UInt64
        var task: Task<Void, Never>?
        var waiters: [UUID: Waiter]
        var invalidated = false
    }
    private struct WaiterObservation {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var budget: MatrixBudget
    private var ready: [RetrievalCacheKey: UUID] = [:]
    private var entries: [UUID: Entry] = [:]
    private var loadingKeys: [RetrievalCacheKey: UUID] = [:]
    private var loading: [UUID: Loading] = [:]
    private var waiterSlots: [UUID: UUID] = [:]
    private var waiterObservations: [RetrievalCacheKey: [WaiterObservation]] = [:]
    private var idleObservations: [CheckedContinuation<Void, Never>] = []
    private var tick: UInt64 = 0
    private var loads = 0
    private struct Resident {
        var matrix: ResidentVectorMatrix
        var bytes: Int64
        var tick: UInt64
    }
    private var residents: [ResidentMatrixKey: Resident] = [:]
    private var residentSyncs: [ResidentMatrixKey: Task<Bool, Error>] = [:]

    public init(budgetBytes: Int64 = RagContractV1.Cache.globalBudgetBytes) {
        budget = MatrixBudget(limit: max(0, budgetBytes))
    }

    internal func acquire(key: RetrievalCacheKey, rowCount: Int, dims: Int,
                          epoch: @escaping @Sendable () -> UInt64,
                          load: @escaping @Sendable () async throws -> [VectorRow]) async throws -> VectorMatrixLease? {
        try await acquire(key: key, rowCount: rowCount, dims: dims, epoch: epoch) { builder in
            try builder.append(try await load())
        }
    }

    public func acquire(key: RetrievalCacheKey, rowCount: Int, dims: Int,
                        epoch: @escaping @Sendable () -> UInt64,
                        fill: @escaping @Sendable (VectorMatrixBuilder) async throws -> Void) async throws -> VectorMatrixLease? {
        try Task.checkCancellation()
        let waiterId = UUID(), cancellation = MatrixWaiterCancellation()
        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(waiterId: waiterId, cancellation: cancellation, continuation: continuation,
                         key: key, rowCount: rowCount, dims: dims, epoch: epoch, fill: fill)
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancelWaiter(waiterId) }
        }
        if Task.isCancelled {
            await lease?.close()
            throw CancellationError()
        }
        return lease
    }

    private func register(waiterId: UUID, cancellation: MatrixWaiterCancellation,
                          continuation: CheckedContinuation<VectorMatrixLease?, any Error>,
                          key: RetrievalCacheKey, rowCount: Int, dims: Int,
                          epoch: @escaping @Sendable () -> UInt64,
                          fill: @escaping @Sendable (VectorMatrixBuilder) async throws -> Void) {
        guard !cancellation.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        let observed = epoch()
        invalidateObsolete(databaseId: key.databaseId, epoch: observed)
        guard observed == key.epoch else { continuation.resume(returning: nil); return }
        if let id = ready[key], entries[id] != nil {
            entries[id]!.leases += 1
            entries[id]!.tick = nextTick()
            continuation.resume(returning: VectorMatrixLease(matrix: entries[id]!.matrix, cache: self, entryId: id))
            return
        }
        let waiter = Waiter(cancellation: cancellation, continuation: continuation)
        if let id = loadingKeys[key], loading[id] != nil {
            loading[id]!.waiters[waiterId] = waiter
            waiterSlots[waiterId] = id
            notifyWaiterObservations(key)
            return
        }
        guard let bytes = MatrixBudget.charge(rows: rowCount, dims: dims), bytes <= budget.limit,
              dims <= 8_388_608 / MemoryLayout<Float>.size else {
            continuation.resume(returning: nil)
            return
        }
        while !budget.reserve(bytes) {
            guard let victim = evictionCandidate() else { continuation.resume(returning: nil); return }
            let victimKey = entries[victim]!.key, victimBytes = entries[victim]!.bytes
            ready.removeValue(forKey: victimKey)
            entries.removeValue(forKey: victim)
            budget.dropResident(victimBytes)
        }
        // No matrix allocation can occur until the reservation above succeeds.
        let builder = VectorMatrixBuilder(rowCount: rowCount, dims: dims)
        let id = UUID()
        loading[id] = Loading(key: key, bytes: bytes, builder: builder, epoch: epoch,
                              waiters: [waiterId: waiter])
        loadingKeys[key] = id
        waiterSlots[waiterId] = id
        loading[id]!.task = Task.detached { [self, builder] in
            do {
                try Task.checkCancellation()
                guard await beginFill(id) else { throw CancellationError() }
                try await fill(builder)
                try Task.checkCancellation()
                await finishFill(id, error: nil)
            } catch {
                await finishFill(id, error: error)
            }
        }
        notifyWaiterObservations(key)
    }

    private func beginFill(_ id: UUID) -> Bool {
        guard let slot = loading[id], !slot.waiters.isEmpty else { return false }
        loads += 1
        return true
    }

    private func finishFill(_ id: UUID, error: (any Error)?) {
        guard var slot = loading.removeValue(forKey: id) else { return }
        if loadingKeys[slot.key] == id { loadingKeys.removeValue(forKey: slot.key) }
        for waiterId in slot.waiters.keys { waiterSlots.removeValue(forKey: waiterId) }

        // Cancellation's flag is synchronous, so it wins even if its actor
        // cleanup task has not yet reached this completion handler.
        var cancelled: [Waiter] = []
        for (waiterId, waiter) in slot.waiters where waiter.cancellation.isCancelled {
            cancelled.append(waiter)
            slot.waiters.removeValue(forKey: waiterId)
        }
        if let error {
            slot.builder.discard()
            budget.abandon(slot.bytes)
            for waiter in slot.waiters.values { waiter.continuation.resume(throwing: error) }
        } else if slot.invalidated || slot.epoch() != slot.key.epoch || slot.waiters.isEmpty {
            slot.builder.discard()
            budget.abandon(slot.bytes)
            for waiter in slot.waiters.values { waiter.continuation.resume(returning: nil) }
        } else {
            do {
                let matrix = try slot.builder.seal()
                budget.commit(slot.bytes)
                entries[id] = Entry(key: slot.key, bytes: slot.bytes, matrix: matrix,
                                    leases: slot.waiters.count, tick: nextTick())
                ready[slot.key] = id
                for waiter in slot.waiters.values {
                    waiter.continuation.resume(returning: VectorMatrixLease(matrix: matrix, cache: self, entryId: id))
                }
            } catch {
                slot.builder.discard()
                budget.abandon(slot.bytes)
                for waiter in slot.waiters.values { waiter.continuation.resume(throwing: error) }
            }
        }
        for waiter in cancelled { waiter.continuation.resume(throwing: CancellationError()) }
        notifyIdleObservations()
    }

    private func cancelWaiter(_ waiterId: UUID) {
        guard let slotId = waiterSlots.removeValue(forKey: waiterId),
              let waiter = loading[slotId]?.waiters.removeValue(forKey: waiterId) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if loading[slotId]!.waiters.isEmpty {
            let key = loading[slotId]!.key
            if loadingKeys[key] == slotId { loadingKeys.removeValue(forKey: key) }
            // Keep the reservation and builder until the cancelled worker exits.
            loading[slotId]!.task?.cancel()
        }
    }

    public func invalidate(databaseId: String) {
        invalidateEntries { $0.databaseId == databaseId }
        for key in residents.keys where key.databaseId == databaseId && residentSyncs[key] == nil { dropResident(key) }
    }
    private func invalidateObsolete(databaseId: String, epoch: UInt64) {
        invalidateEntries { $0.databaseId == databaseId && $0.epoch != epoch }
    }
    private func invalidateEntries(where matches: (RetrievalCacheKey) -> Bool) {
        let readyIds = ready.filter { matches($0.key) }.map(\.value)
        for id in readyIds {
            guard let key = entries[id]?.key else { continue }
            ready.removeValue(forKey: key)
            if entries[id]!.leases == 0 {
                let bytes = entries[id]!.bytes
                entries.removeValue(forKey: id)
                budget.dropResident(bytes)
            } else {
                entries[id]!.invalidated = true
            }
        }
        let loadingIds = loadingKeys.filter { matches($0.key) }.map(\.value)
        for id in loadingIds {
            guard let key = loading[id]?.key else { continue }
            loadingKeys.removeValue(forKey: key)
            loading[id]!.invalidated = true
        }
    }

    fileprivate func release(_ id: UUID) {
        guard entries[id] != nil else { return }
        precondition(entries[id]!.leases > 0)
        entries[id]!.leases -= 1
        if entries[id]!.leases == 0 && entries[id]!.invalidated {
            let bytes = entries[id]!.bytes
            entries.removeValue(forKey: id)
            budget.dropResident(bytes)
        }
    }
    // MARK: - Resident generation matrices (retrieval-resident-v1)

    /// Loads the pinned pairs this generation's resident matrix lacks (at most one load in
    /// flight per key; concurrent callers wait for it), then scores synchronously. Returns
    /// nil when the matrix cannot be kept within the budget; the caller then streams.
    /// `count` and `fill` run outside the actor; `fill` writes only its own new block.
    internal func residentTopK(key: ResidentMatrixKey, pins: [Int64: Int64], allowed: [Int64: Int64],
                               query: [Float], k: Int,
                               count: @escaping @Sendable ([Int64: Int64]) async throws -> Int,
                               fill: @escaping @Sendable ([Int64: Int64], ResidentBlock) async throws -> Bool) async throws -> ResidentScan? {
        while true {
            try Task.checkCancellation()
            if let inflight = residentSyncs[key] {
                _ = try? await inflight.value
                continue
            }
            let matrix = residents[key]?.matrix ?? ResidentVectorMatrix(dims: key.dims)
            let missing = matrix.missing(pins)
            if missing.isEmpty {
                guard residents[key] != nil || pins.isEmpty else { return nil }
                if residents[key] != nil { residents[key]!.tick = nextTick() }
                return ResidentScan(scored: matrix.topK(query: query, allowed: allowed, k: k),
                                    invalidVectorCount: matrix.invalidVectorCount, peakPageBytes: matrix.peakPageBytes)
            }
            let task = Task<Bool, Error> { [self] in
                try await self.loadResident(key: key, missing: missing, count: count, fill: fill)
            }
            residentSyncs[key] = task
            let admitted: Bool
            do { admitted = try await task.value } catch {
                residentSyncs.removeValue(forKey: key)
                throw error
            }
            residentSyncs.removeValue(forKey: key)
            if !admitted { return nil }
        }
    }

    private func loadResident(key: ResidentMatrixKey, missing: [Int64: Int64],
                              count: @Sendable ([Int64: Int64]) async throws -> Int,
                              fill: @Sendable ([Int64: Int64], ResidentBlock) async throws -> Bool) async throws -> Bool {
        let rows = try await count(missing)
        guard let charge = ResidentBlock.charge(rows: rows, dims: key.dims),
              charge == 0 || reserveEvicting(charge, keeping: key) else {
            dropResident(key)
            return false
        }
        let block = ResidentBlock(capacity: rows, dims: key.dims)
        let complete: Bool
        do { complete = try await fill(missing, block) } catch {
            budget.abandon(charge)
            throw error
        }
        guard complete else {
            // More rows than counted (the pinned pairs changed underneath): never keep a
            // partial pair; this query streams and the next one loads afresh.
            budget.abandon(charge)
            return false
        }
        let actual = ResidentBlock.charge(rows: block.count, dims: key.dims)!
        budget.abandon(charge)
        guard budget.reserve(actual) || actual == 0 else { dropResident(key); return false }
        if actual > 0 { budget.commit(actual) }
        var resident = residents[key] ?? Resident(matrix: ResidentVectorMatrix(dims: key.dims), bytes: 0, tick: 0)
        resident.matrix.commit(block, pairs: missing)
        resident.bytes += actual
        resident.tick = nextTick()
        if resident.matrix.garbageRows > max(4_096, resident.matrix.rows / 2) {
            let compacted = resident.matrix.compacted()
            budget.dropResident(resident.bytes)
            resident.matrix = compacted
            resident.bytes = compacted.bytes
            budget.commitUnchecked(resident.bytes)
        }
        residents[key] = resident
        if !missing.isEmpty { loads += 1 }
        return true
    }

    /// Reserves `bytes`, evicting least-recently-used unleased matrices and other resident
    /// generations first. The resident matrix being extended is never its own victim.
    private func reserveEvicting(_ bytes: Int64, keeping: ResidentMatrixKey) -> Bool {
        while !budget.reserve(bytes) {
            let residentVictim = residents.filter { $0.key != keeping && residentSyncs[$0.key] == nil }
                .min { $0.value.tick < $1.value.tick }
            let entryVictim = evictionCandidate()
            switch (residentVictim, entryVictim) {
            case let (resident?, entry?) where resident.value.tick <= entries[entry]!.tick:
                dropResident(resident.key)
            case let (resident?, nil):
                dropResident(resident.key)
            case let (_, entry?):
                let victimKey = entries[entry]!.key, victimBytes = entries[entry]!.bytes
                ready.removeValue(forKey: victimKey)
                entries.removeValue(forKey: entry)
                budget.dropResident(victimBytes)
            case (nil, nil):
                return false
            }
        }
        return true
    }

    private func dropResident(_ key: ResidentMatrixKey) {
        guard let resident = residents.removeValue(forKey: key) else { return }
        budget.dropResident(resident.bytes)
    }

    /// A store reopened its database: matrices under the retired identity are unreachable.
    public func dropResidents(databaseInstance: String) {
        for key in residents.keys where key.databaseInstance == databaseInstance && residentSyncs[key] == nil { dropResident(key) }
    }

    /// Memory pressure: drops every resident matrix that no load is extending.
    public func trimResidents() {
        for key in residents.keys where residentSyncs[key] == nil { dropResident(key) }
    }

    internal func residentRowCount(_ key: ResidentMatrixKey) -> Int? { residents[key]?.matrix.rows }

    public func statistics() -> VectorCacheStatistics {
        VectorCacheStatistics(residentBytes: budget.resident, reservedBytes: budget.reserved,
                              loadCount: loads, entryCount: ready.count + residents.count)
    }
    internal func residentKeys() -> [RetrievalCacheKey] { ready.keys.sorted(by: Self.keyLess) }

    private func evictionCandidate() -> UUID? {
        entries.keys.filter { entries[$0]!.leases == 0 }.min { lhs, rhs in
            let a = entries[lhs]!, b = entries[rhs]!
            return a.tick == b.tick ? Self.keyLess(a.key, b.key) : a.tick < b.tick
        }
    }
    private static func keyLess(_ lhs: RetrievalCacheKey, _ rhs: RetrievalCacheKey) -> Bool {
        if !lhs.databaseId.utf8.elementsEqual(rhs.databaseId.utf8) {
            return lhs.databaseId.utf8.lexicographicallyPrecedes(rhs.databaseId.utf8)
        }
        if lhs.notebookId != rhs.notebookId { return lhs.notebookId < rhs.notebookId }
        if lhs.generationId != rhs.generationId { return lhs.generationId < rhs.generationId }
        return lhs.epoch < rhs.epoch
    }
    private func nextTick() -> UInt64 {
        if tick == UInt64.max {
            let ids = entries.keys.sorted {
                let a = entries[$0]!, b = entries[$1]!
                return a.tick == b.tick ? Self.keyLess(a.key, b.key) : a.tick < b.tick
            }
            for (index, id) in ids.enumerated() { entries[id]!.tick = UInt64(index) }
            tick = UInt64(ids.count)
        }
        tick += 1
        return tick
    }

    /// Deterministic test barriers; these expose counts, never matrix buffers.
    internal func waiterCount(key: RetrievalCacheKey) -> Int {
        guard let id = loadingKeys[key] else { return 0 }
        return loading[id]?.waiters.count ?? 0
    }
    internal func waitForWaiters(key: RetrievalCacheKey, count: Int) async {
        guard waiterCount(key: key) < count else { return }
        await withCheckedContinuation { continuation in
            waiterObservations[key, default: []].append(WaiterObservation(count: count, continuation: continuation))
        }
    }
    private func notifyWaiterObservations(_ key: RetrievalCacheKey) {
        guard let observations = waiterObservations.removeValue(forKey: key) else { return }
        let count = waiterCount(key: key)
        for observation in observations {
            if count >= observation.count { observation.continuation.resume() }
            else { waiterObservations[key, default: []].append(observation) }
        }
    }
    internal func waitForIdle() async {
        guard !loading.isEmpty else { return }
        await withCheckedContinuation { idleObservations.append($0) }
    }
    private func notifyIdleObservations() {
        guard loading.isEmpty else { return }
        let observers = idleObservations
        idleObservations.removeAll()
        for observer in observers { observer.resume() }
    }
}

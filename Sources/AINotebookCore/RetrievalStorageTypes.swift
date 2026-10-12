import Foundation

public enum RetrievalError: String, Error, Equatable, Sendable {
    case invalidFetchK, closedSnapshot, revisionMismatch, invalidSpan, invalidRadius
    case unsupportedQueryFormat, endpointRevisionMismatch, embeddingSessionRequired
    case legacyProviderUnresolved, invalidMeasurementInput
}

public struct ChunkReference: Equatable, Hashable, Sendable {
    public let chunkId: Int64
    public let sourceId: Int64
    public let revisionId: Int64
    public let ord: Int

    public init(chunkId: Int64, sourceId: Int64, revisionId: Int64, ord: Int) {
        self.chunkId = chunkId
        self.sourceId = sourceId
        self.revisionId = revisionId
        self.ord = ord
    }
}

public struct ScopedSource: Sendable {
    public let sourceId: Int64
    public let folderId: Int64?
    public let relPath: String?
    public let displayName: String
    public let publishedRevisionId: Int64?
    public let vectorRevisionId: Int64?
    /// File modification time (UTC seconds), for the path matcher's date signals.
    public let mtime: Int64?

    public init(sourceId: Int64, folderId: Int64?, relPath: String?, displayName: String, publishedRevisionId: Int64?,
                vectorRevisionId: Int64?, mtime: Int64? = nil) {
        self.sourceId = sourceId
        self.folderId = folderId
        self.relPath = relPath
        self.displayName = displayName
        self.publishedRevisionId = publishedRevisionId
        self.vectorRevisionId = vectorRevisionId
        self.mtime = mtime
    }
}

public struct VectorRow: Sendable {
    public let reference: ChunkReference
    public let values: [Float]

    public init(reference: ChunkReference, values: [Float]) {
        self.reference = reference
        self.values = values
    }
}

public struct ScoredChunk: Sendable {
    public let reference: ChunkReference
    public let score: Float

    public init(reference: ChunkReference, score: Float) {
        self.reference = reference
        self.score = score
    }
}

public struct RankedChunk: Sendable {
    public let reference: ChunkReference
    public let rrfMicro: Int64

    public init(reference: ChunkReference, rrfMicro: Int64) {
        self.reference = reference
        self.rrfMicro = rrfMicro
    }
}

public struct RetrievalCacheKey: Equatable, Hashable, Sendable {
    public let databaseId: String
    public let notebookId: Int64
    public let generationId: Int64
    public let epoch: UInt64

    public init(databaseId: String, notebookId: Int64, generationId: Int64, epoch: UInt64) {
        self.databaseId = databaseId
        self.notebookId = notebookId
        self.generationId = generationId
        self.epoch = epoch
    }
}

public struct ChunkEvidenceRow: Sendable {
    public let reference: ChunkReference
    public let canonicalText: String
    public let chunkText: String
    public let charStart: Int?
    public let charEnd: Int?
    public let pageHint: Int?
    public let chunkerVersion: Int

    public init(reference: ChunkReference, canonicalText: String, chunkText: String, charStart: Int?, charEnd: Int?, pageHint: Int?, chunkerVersion: Int) {
        self.reference = reference
        self.canonicalText = canonicalText
        self.chunkText = chunkText
        self.charStart = charStart
        self.charEnd = charEnd
        self.pageHint = pageHint
        self.chunkerVersion = chunkerVersion
    }
}

public struct EvidencePassage: Sendable {
    public let reference: ChunkReference
    public let text: String
    public let displaySnippet: String
    public let spans: [CitationSpan]
    public let isNeighbour: Bool

    public init(reference: ChunkReference, text: String, displaySnippet: String, spans: [CitationSpan], isNeighbour: Bool) {
        self.reference = reference
        self.text = text
        self.displaySnippet = displaySnippet
        self.spans = spans
        self.isNeighbour = isNeighbour
    }
}

/// Coordinates ownership without holding a lock across SQLite or actor hops.
internal final class RetrievalLeaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var closing = false
    private var borrowers = 0
    private var released = false

    func begin() throws {
        try lock.withLock {
            guard !closing else { throw RetrievalError.closedSnapshot }
            borrowers += 1
        }
    }
    func requestClose() -> Bool {
        lock.withLock { closing = true; return takeRelease() }
    }
    func end() -> Bool {
        lock.withLock {
            precondition(borrowers > 0)
            borrowers -= 1
            return takeRelease()
        }
    }
    private func takeRelease() -> Bool {
        guard closing && borrowers == 0 && !released else { return false }
        released = true
        return true
    }
}

/// Immutable SQL identity plus a synchronized close/borrow state. A close prevents
/// new operations; existing operations keep WP3's pin until their text is copied.
public final class ResolvedRetrievalScope: Sendable {
    public let pin: QueryPin
    public let scope: RetrievalScope
    public let sources: [ScopedSource]
    public let generation: IndexGeneration?
    public let cacheKey: RetrievalCacheKey?
    public var filesInScope: Int { sources.count }
    internal let initialSourceIds: Set<Int64>
    /// Encoded once per query: every retrieval statement binds it (thousands of ids).
    internal let initialSourceIdsJSON: String
    private let store: NotebookStore
    private let state = RetrievalLeaseState()

    internal init(store: NotebookStore, pin: QueryPin, scope: RetrievalScope,
                  sources: [ScopedSource], generation: IndexGeneration?, cacheKey: RetrievalCacheKey?) {
        self.store = store
        self.pin = pin
        self.scope = scope
        self.sources = sources
        self.generation = generation
        self.cacheKey = cacheKey
        initialSourceIds = Set(sources.map(\.sourceId))
        initialSourceIdsJSON = "[" + sources.map(\.sourceId).sorted().map(String.init).joined(separator: ",") + "]"
    }
    public func acquireOperation() throws -> RetrievalOperation {
        try state.begin()
        return RetrievalOperation(snapshot: self)
    }
    public func close() async {
        if state.requestClose() { await store.releaseQuery(pin) }
    }
    internal func endOperation() async {
        if state.end() { await store.releaseQuery(pin) }
    }
    internal func abandonOperation() {
        if state.end() {
            let store = store, pin = pin
            Task { @MainActor in store.releaseQuery(pin) }
        }
    }
    deinit {
        if state.requestClose() {
            let store = store, pin = pin
            Task { @MainActor in store.releaseQuery(pin) }
        }
    }
}

/// Only the idempotent close flag is mutable and is protected by `lock`.
public final class RetrievalOperation: @unchecked Sendable {
    public let snapshot: ResolvedRetrievalScope
    private let lock = NSLock()
    private var closed = false
    internal init(snapshot: ResolvedRetrievalScope) { self.snapshot = snapshot }
    internal func checkOpen() throws {
        try lock.withLock { if closed { throw RetrievalError.closedSnapshot } }
    }
    private func takeClose() -> Bool {
        lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
    }
    public func close() async {
        if takeClose() { await snapshot.endOperation() }
    }
    deinit { if takeClose() { snapshot.abandonOperation() } }
}

internal struct RawVectorRow: Sendable {
    let reference: ChunkReference
    let blob: Data?
}
internal struct RawVectorPage: Sendable {
    let rows: [RawVectorRow]
    let lastScannedChunkId: Int64
    let exhausted: Bool
    let payloadBytes: Int
}

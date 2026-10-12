import Foundation

/// One branch or fused candidate. Every candidate carries its own explicit
/// revision and the query's nullable pinned generation.
public struct PinnedRetrievalCandidate: Sendable, Equatable {
    public let reference: ChunkReference
    public let generationId: Int64?
    public let rrfMicro: Int64

    public init(reference: ChunkReference, generationId: Int64?, rrfMicro: Int64) {
        self.reference = reference
        self.generationId = generationId
        self.rrfMicro = rrfMicro
    }
}

/// `vectorStatus` is one of `used`, `disabled`, `noActiveGeneration`,
/// `invalidQueryVector`, `embeddingFailed`, `endpointRevisionMismatch`,
/// `unsupportedQueryFormat`, `embeddingSessionRequired`,
/// `legacyEndpointUnverified`, `legacyProviderUnresolved`, `oversizedVector`.
/// It never contains provider secrets or raw endpoint strings.
public struct RetrievalDiagnostics: Sendable, Equatable {
    public let vectorStatus: String
    public let invalidVectorCount: Int
    public let streamed: Bool
    public let peakPageBytes: Int64

    public init(vectorStatus: String, invalidVectorCount: Int, streamed: Bool, peakPageBytes: Int64) {
        self.vectorStatus = vectorStatus
        self.invalidVectorCount = invalidVectorCount
        self.streamed = streamed
        self.peakPageBytes = peakPageBytes
    }
}

/// A scoped, revision-pinned candidate pool. It owns the query's scope lease:
/// a consumer copies evidence while the pool is open, then closes it. `fused`
/// is the complete integer-RRF union of both branches, never truncated.
public final class PinnedRetrievalCandidates: Sendable {
    public let lexical: [PinnedRetrievalCandidate]
    public let vector: [PinnedRetrievalCandidate]
    /// First chunks of the best path-matching files (retrieval-paths-v1 §4).
    public let path: [PinnedRetrievalCandidate]
    /// The full best-tier path ranking over the permitted published files.
    public let pathMatches: [PathMatch]
    /// retrieval-paths v2 (§6): a year or document-type term matched the best tier.
    public let pathInventory: Bool
    public let fused: [PinnedRetrievalCandidate]
    public let snapshot: ResolvedRetrievalScope?
    public let diagnostics: RetrievalDiagnostics
    /// Retained only for the legacy adapters, which preserve their historical
    /// contract of propagating provider failures instead of degrading silently.
    internal let embeddingError: (any Error)?

    internal init(lexical: [PinnedRetrievalCandidate], vector: [PinnedRetrievalCandidate],
                  path: [PinnedRetrievalCandidate] = [], pathMatches: [PathMatch] = [], pathInventory: Bool = false,
                  fused: [PinnedRetrievalCandidate], snapshot: ResolvedRetrievalScope?,
                  diagnostics: RetrievalDiagnostics, embeddingError: (any Error)? = nil) {
        self.lexical = lexical
        self.vector = vector
        self.path = path
        self.pathMatches = pathMatches
        self.pathInventory = pathInventory
        self.fused = fused
        self.snapshot = snapshot
        self.diagnostics = diagnostics
        self.embeddingError = embeddingError
    }

    internal static func empty(status: String) -> PinnedRetrievalCandidates {
        PinnedRetrievalCandidates(lexical: [], vector: [], fused: [], snapshot: nil,
            diagnostics: RetrievalDiagnostics(vectorStatus: status, invalidVectorCount: 0, streamed: false, peakPageBytes: 0))
    }

    /// Idempotent; releases the WP3 query pin once no operation still borrows it.
    public func close() async {
        await snapshot?.close()
    }
}

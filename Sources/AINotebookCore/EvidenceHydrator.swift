import Foundation

/// Copies complete, revision-pinned evidence while one operation borrow keeps
/// WP3's query pin alive. Neighbours are returned as separate candidates on the
/// captured published revision; this type never merges, budgets or truncates.
public struct EvidenceHydrator: Sendable {
    public static let displaySnippetScalars = 240

    private let reader: RetrievalReadStore
    private let afterBorrow: (@Sendable () async -> Void)?

    public init(reader: RetrievalReadStore) {
        self.init(reader: reader, afterBorrow: nil)
    }

    /// Test seam: runs after the operation borrow and before the first read.
    internal init(reader: RetrievalReadStore, afterBorrow: (@Sendable () async -> Void)?) {
        self.reader = reader
        self.afterBorrow = afterBorrow
    }

    public func hydrate(_ snapshot: ResolvedRetrievalScope, references: [ChunkReference],
                        neighborRadius: Int = 1) async throws -> [EvidencePassage] {
        guard neighborRadius >= 0 else { throw RetrievalError.invalidRadius }
        let operation = try snapshot.acquireOperation()
        do {
            let passages = try await hydrate(operation, references: references, neighborRadius: neighborRadius)
            await operation.close()
            return passages
        } catch {
            await operation.close()
            throw error
        }
    }

    /// Uses only token-aware reads, so an owner closing mid-hydration cannot
    /// release the pin until this borrow's caller closes the operation.
    internal func hydrate(_ operation: RetrievalOperation, references: [ChunkReference],
                          neighborRadius: Int) async throws -> [EvidencePassage] {
        guard neighborRadius >= 0 else { throw RetrievalError.invalidRadius }
        try operation.checkOpen()
        if let afterBorrow { await afterBorrow() }
        guard !references.isEmpty else { return [] }

        // Conflicting duplicate identities are corruption; the reader then
        // validates every requested identity before returning any row.
        var firstById: [Int64: ChunkReference] = [:], direct: [ChunkReference] = []
        for reference in references {
            if let first = firstById[reference.chunkId] {
                guard first == reference else { throw RetrievalError.revisionMismatch }
                continue
            }
            firstById[reference.chunkId] = reference
            direct.append(reference)
        }
        let directIds = Set(firstById.keys)
        let directRows = try await reader.evidenceRows(operation, references: direct)
        let directById = Dictionary(directRows.map { ($0.reference.chunkId, $0) }, uniquingKeysWith: { first, _ in first })
        let hydratedCenters = direct.filter { directById[$0.chunkId] != nil }

        var neighbours: [ChunkReference] = []
        if neighborRadius > 0 {
            var seen = directIds
            for center in hydratedCenters {
                try Task.checkCancellation()
                for neighbour in try await reader.neighbourReferences(operation, center: center, radius: neighborRadius)
                where seen.insert(neighbour.chunkId).inserted {
                    neighbours.append(neighbour)
                }
            }
        }
        let neighbourRows = neighbours.isEmpty ? [] : try await reader.evidenceRows(operation, references: neighbours)
        let neighbourById = Dictionary(neighbourRows.map { ($0.reference.chunkId, $0) }, uniquingKeysWith: { first, _ in first })

        var scalarCache: [Int64: [Unicode.Scalar]] = [:]
        var passages: [EvidencePassage] = []
        passages.reserveCapacity(hydratedCenters.count + neighbours.count)
        for reference in hydratedCenters {
            passages.append(try Self.passage(directById[reference.chunkId]!, isNeighbour: false, scalars: &scalarCache))
        }
        for reference in neighbours {
            guard let row = neighbourById[reference.chunkId] else { continue }
            passages.append(try Self.passage(row, isNeighbour: true, scalars: &scalarCache))
        }
        return passages
    }

    public static func passage(_ row: ChunkEvidenceRow, isNeighbour: Bool) throws -> EvidencePassage {
        var cache: [Int64: [Unicode.Scalar]] = [:]
        return try passage(row, isNeighbour: isNeighbour, scalars: &cache)
    }

    /// Offsets are Unicode scalar offsets into the revision's canonical text.
    /// A revision's scalar view is materialized once per hydration call.
    private static func passage(_ row: ChunkEvidenceRow, isNeighbour: Bool,
                                scalars cache: inout [Int64: [Unicode.Scalar]]) throws -> EvidencePassage {
        let text: String
        let spans: [CitationSpan]
        if row.chunkerVersion == 1 && row.charStart == nil && row.charEnd == nil {
            text = row.chunkText
            spans = []
        } else {
            guard let start = row.charStart, let end = row.charEnd, start >= 0, end > start else {
                throw RetrievalError.invalidSpan
            }
            let scalars: [Unicode.Scalar]
            if let cached = cache[row.reference.revisionId] {
                scalars = cached
            } else {
                scalars = Array(row.canonicalText.unicodeScalars)
                cache[row.reference.revisionId] = scalars
            }
            guard end <= scalars.count else { throw RetrievalError.invalidSpan }
            text = String(String.UnicodeScalarView(scalars[start..<end]))
            // Only the stored hint is claimed; page ranges are never derived from offsets.
            spans = [CitationSpan(start: start, end: end, pageFrom: row.pageHint, pageTo: row.pageHint)]
        }
        let snippet = String(String.UnicodeScalarView(text.unicodeScalars.prefix(displaySnippetScalars)))
        return EvidencePassage(reference: row.reference, text: text, displaySnippet: snippet,
                               spans: spans, isNeighbour: isNeighbour)
    }
}

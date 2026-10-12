import Foundation

/// Deterministic seams between orchestration steps; production passes none.
internal struct RetrieverHooks: Sendable {
    var afterPass: (@Sendable (Int) async -> Void)?
    init(afterPass: (@Sendable (Int) async -> Void)? = nil) { self.afterPass = afterPass }
}

/// One scoped query: a single SQL scope snapshot and WP3 pin precede embedding;
/// published revisions feed the lexical branch and the pinned generation's done
/// manifest feeds the masked vector heap; integer RRF fuses the complete union.
public actor Retriever {
    private let store: NotebookStore
    private let client: EmbeddingProducing
    private let modelKey: @Sendable () -> String
    public let rrfK: Int
    private let cache: VectorMatrixCache
    private let tables: UnicodeTables?
    private let hooks: RetrieverHooks
    private let defaultFetchK: @Sendable () throws -> Int
    private var reader: RetrievalReadStore?

    /// `modelKey` is read once at the start of every query, so a provider/model
    /// switch in Settings applies to the next query without rebuilding the
    /// retriever, and never reroutes a running one.
    public init(
        store: NotebookStore,
        client: EmbeddingProducing,
        modelKey: @escaping @Sendable () -> String,
        rrfK: Int = 60
    ) {
        self.init(store: store, client: client, modelKey: modelKey, rrfK: rrfK,
                  cache: .shared, tables: nil, hooks: RetrieverHooks())
    }

    /// Convenience for a fixed key (tests, single-provider setups).
    public init(
        store: NotebookStore,
        client: EmbeddingProducing,
        model: String,
        rrfK: Int = 60
    ) {
        self.init(store: store, client: client, modelKey: { model }, rrfK: rrfK)
    }

    /// Injects a matrix cache (process-wide by default) and pinned Unicode tables;
    /// bundled tables load lazily, after the empty-scope guard.
    public init(
        store: NotebookStore,
        client: EmbeddingProducing,
        modelKey: @escaping @Sendable () -> String,
        rrfK: Int = 60,
        cache: VectorMatrixCache,
        tables: UnicodeTables? = nil
    ) {
        self.init(store: store, client: client, modelKey: modelKey, rrfK: rrfK,
                  cache: cache, tables: tables, hooks: RetrieverHooks())
    }

    internal init(store: NotebookStore, client: EmbeddingProducing, modelKey: @escaping @Sendable () -> String,
                  rrfK: Int = 60, cache: VectorMatrixCache, tables: UnicodeTables?, hooks: RetrieverHooks,
                  defaultFetchK: @escaping @Sendable () throws -> Int = { try RagRuntimeTuning.bundled().fetchK }) {
        self.defaultFetchK = defaultFetchK
        self.store = store
        self.client = client
        self.modelKey = modelKey
        self.rrfK = rrfK
        self.cache = cache
        self.tables = tables
        self.hooks = hooks
    }

    // MARK: - Pinned scoped retrieval

    /// Returns a pool that owns the query's scope lease; the caller copies
    /// evidence and then closes it. Each branch selects its own `fetchK`; the
    /// fused union is never truncated. An empty selection performs no SQL, model
    /// read or provider call. Embedding problems leave lexical results available
    /// with a diagnostic; cancellation always propagates.
    public func search(notebookId: Int64, query: String, scope: RetrievalScope,
                       fetchK requestedFetchK: Int? = nil, includeVectors: Bool = true) async throws -> PinnedRetrievalCandidates {
        guard (requestedFetchK ?? 1) > 0, rrfK > 0 else { throw RetrievalError.invalidFetchK }
        guard !scope.isEmptySelection else { return .empty(status: "disabled") }
        // An omitted fetchK resolves once from the bundled runtime tuning.
        let fetchK = try requestedFetchK ?? defaultFetchK()
        guard fetchK > 0 else { throw RetrievalError.invalidFetchK }
        let key = modelKey()
        let store = store
        guard let snapshot = try ScopeResolver.resolve(store: store, notebookId: notebookId, scope: scope, modelKey: key)
        else { return .empty(status: "disabled") }
        let embedded: EmbeddedQuery
        do {
            embedded = try await embedQuery(query, snapshot: snapshot, includeVectors: includeVectors)
        } catch {
            await snapshot.close()
            throw error
        }
        return try await rank(snapshot: snapshot, query: query, embedded: embedded, fetchK: fetchK)
    }

    /// WP7 timing seam: `snapshot` already owns a pin and the vector is already
    /// embedded. Ownership of the snapshot transfers to the returned pool on
    /// success; on failure the snapshot is closed. Callers never close it after.
    public func searchEmbedded(snapshot: ResolvedRetrievalScope, query: String,
                               queryVector: [Float]?, fetchK requestedFetchK: Int? = nil) async throws -> PinnedRetrievalCandidates {
        let fetchK: Int
        do { fetchK = try requestedFetchK ?? defaultFetchK() } catch { await snapshot.close(); throw error }
        let status: String
        if snapshot.generation == nil { status = "noActiveGeneration" }
        else if RetrievalSQL.byteWidth(dims: snapshot.pin.dims ?? 0) == nil { status = "oversizedVector" }
        else if queryVector == nil { status = "disabled" }
        else { status = "used" }
        let embedded = EmbeddedQuery(vector: status == "used" ? queryVector : nil, status: status, error: nil)
        return try await rank(snapshot: snapshot, query: query, embedded: embedded, fetchK: fetchK)
    }

    private struct EmbeddedQuery: Sendable {
        let vector: [Float]?
        let status: String
        let error: (any Error)?
    }

    private static let lexicalOnlyCodes: Set<RetrievalError> = [
        .endpointRevisionMismatch, .unsupportedQueryFormat, .legacyProviderUnresolved, .embeddingSessionRequired,
    ]

    /// Embeds exactly one question against the pinned generation's identity.
    /// No settings or active-generation lookup happens after the pin.
    private func embedQuery(_ query: String, snapshot: ResolvedRetrievalScope,
                            includeVectors: Bool) async throws -> EmbeddedQuery {
        guard includeVectors else { return EmbeddedQuery(vector: nil, status: "disabled", error: nil) }
        guard let generation = snapshot.generation else {
            return EmbeddedQuery(vector: nil, status: "noActiveGeneration", error: nil)
        }
        let identity = generation.identity
        guard RetrievalSQL.byteWidth(dims: identity.dims) != nil else {
            return EmbeddedQuery(vector: nil, status: "oversizedVector", error: nil)
        }
        let values: [[Float]]
        let legacyUnverified: Bool
        do {
            if let preparer = client as? any EmbeddingSessionPreparing {
                let session = try await preparer.prepareEmbedding(identity: identity)
                legacyUnverified = session.legacyEndpointUnverified
                values = try await session.embed(inputs: [query])
            } else if identity.providerId == "legacy" {
                // Direct clients serve legacy identities with the whole stored key.
                try EmbeddingQueryFormat.validate(identity.queryFormatVersion)
                legacyUnverified = true
                values = try await client.embed(model: identity.modelKey, inputs: [query])
            } else {
                return EmbeddedQuery(vector: nil, status: RetrievalError.embeddingSessionRequired.rawValue, error: nil)
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            if let code = error as? RetrievalError, Self.lexicalOnlyCodes.contains(code) {
                return EmbeddedQuery(vector: nil, status: code.rawValue, error: nil)
            }
            return EmbeddedQuery(vector: nil, status: "embeddingFailed", error: error)
        }
        try Task.checkCancellation()
        guard values.count == 1, let vector = values.first, Self.validQuery(vector, dims: identity.dims) else {
            return EmbeddedQuery(vector: nil, status: "invalidQueryVector", error: nil)
        }
        return EmbeddedQuery(vector: vector, status: legacyUnverified ? "legacyEndpointUnverified" : "used", error: nil)
    }

    private static func validQuery(_ vector: [Float], dims: Int) -> Bool {
        MaskedVectorTopK(query: vector, dims: dims, permittedSources: [], k: 1) != nil
    }

    private func readStore() async -> RetrievalReadStore {
        if let reader { return reader }
        let store = store
        let made = store.makeRetrievalReader()
        reader = made
        return made
    }

    /// Both branches use one operation borrow and the same shrinking source mask.
    /// A revocation observed after scoring re-runs both selections against the
    /// smaller mask and the same pinned revisions until two masks agree.
    private func rank(snapshot: ResolvedRetrievalScope, query: String,
                      embedded: EmbeddedQuery, fetchK: Int) async throws -> PinnedRetrievalCandidates {
        var operation: RetrievalOperation?
        var scan: ScanState?
        do {
            guard fetchK > 0, rrfK > 0 else { throw RetrievalError.invalidFetchK }
            let reader = await readStore()
            let op = try snapshot.acquireOperation()
            operation = op
            let unicode = try tables ?? UnicodeTables.bundled()
            let expression = FTSQueryBuilder(tables: unicode).matchExpression(query)
            let dims = snapshot.pin.dims ?? 0
            var status = embedded.status, queryVector = embedded.vector
            if let vector = queryVector, !Self.validQuery(vector, dims: dims) {
                queryVector = nil
                status = "invalidQueryVector"
            }
            var mask = try await reader.permittedSourceIds(op)
            if queryVector != nil {
                scan = try await openScan(reader: reader, operation: op, snapshot: snapshot, dims: dims)
            }
            // retrieval-paths-v1: rank the scope's published files by path/title/date matches once;
            // each pass keeps the still-permitted ones. Their first chunks form the path branch.
            let pathRanking = PathMatcher(tables: unicode).ranking(query: query, files: snapshot.sources.compactMap { source in
                source.publishedRevisionId == nil ? nil : PathMatchFile(sourceId: source.sourceId, relPath: source.relPath,
                                                                        title: source.displayName, mtime: source.mtime)
            })
            let pathMatches = pathRanking.matches
            var pathHeads: [Int64: ChunkReference] = [:]
            if !pathMatches.isEmpty {
                let heads = pathMatches.prefix(fetchK).compactMap { match in
                    snapshot.pin.lexicalRevisions[match.sourceId].map { (match.sourceId, $0) }
                }
                pathHeads = try await reader.firstChunks(op, revisions: Dictionary(heads, uniquingKeysWith: { a, _ in a }))
            }
            var lexical: [ChunkReference] = [], vector: [ScoredChunk] = [], path: [ChunkReference] = [], pass = 0
            while true {
                try Task.checkCancellation()
                lexical = try await reader.lexical(op, expression: expression, limit: fetchK, permittedSources: mask)
                path = pathMatches.lazy.filter { mask.contains($0.sourceId) }.compactMap { pathHeads[$0.sourceId] }.prefix(fetchK).map { $0 }
                if let queryVector, var state = scan {
                    vector = try await scanTopK(&state, reader: reader, operation: op, snapshot: snapshot,
                                                query: queryVector, mask: mask, k: fetchK, dims: dims)
                    scan = state
                }
            pass += 1
                if let afterPass = hooks.afterPass { await afterPass(pass) }
                let current = try await reader.permittedSourceIds(op).intersection(mask)
                if current == mask { break }
                mask = current
            }
            let diagnostics = RetrievalDiagnostics(vectorStatus: status,
                invalidVectorCount: scan?.invalidVectorCount ?? 0, streamed: scan?.streamed ?? false,
                peakPageBytes: scan?.peakPageBytes ?? 0)
            scan = nil
            let generationId = snapshot.pin.generationId
            let vectorRefs = vector.map(\.reference)
            let fused = try RetrievalRanking.fuse(lexical: lexical, vector: vectorRefs, path: path, rrfK: rrfK).map {
                PinnedRetrievalCandidate(reference: $0.reference, generationId: generationId, rrfMicro: $0.rrfMicro)
            }
            await op.close()
            operation = nil
            return PinnedRetrievalCandidates(lexical: branch(lexical, generationId: generationId),
                vector: branch(vectorRefs, generationId: generationId), path: branch(path, generationId: generationId),
                pathMatches: pathMatches.filter { mask.contains($0.sourceId) }, pathInventory: pathRanking.inventory,
                fused: fused, snapshot: snapshot,
                diagnostics: diagnostics, embeddingError: embedded.error)
        } catch {
            await operation?.close()
            await snapshot.close()
            throw error
        }
    }

    private func branch(_ references: [ChunkReference], generationId: Int64?) -> [PinnedRetrievalCandidate] {
        references.enumerated().map { index, reference in
            let (denominator, overflow) = Int64(rrfK).addingReportingOverflow(Int64(index + 1))
            return PinnedRetrievalCandidate(reference: reference, generationId: generationId,
                                            rrfMicro: overflow ? 0 : 1_000_000 / denominator)
        }
    }

    // MARK: - Vector scans

    private struct ScanState: Sendable {
        var resident: ResidentMatrixKey?
        var empty = false
        var streamed = false
        var invalidVectorCount = 0
        var peakPageBytes: Int64 = 0
    }

    /// The pinned generation is served from its resident, revision-checked binary16 matrix
    /// (retrieval-resident-v1), loaded incrementally per pinned (source, revision) pair and
    /// kept across queries, writes and builds; a matrix over budget streams bounded pages.
    private func openScan(reader: RetrievalReadStore, operation: RetrievalOperation,
                          snapshot: ResolvedRetrievalScope, dims: Int) async throws -> ScanState {
        guard let generationId = snapshot.pin.generationId, !snapshot.pin.vectorRevisions.isEmpty else {
            return ScanState(empty: true)
        }
        return ScanState(resident: ResidentMatrixKey(databaseId: reader.databaseId, databaseInstance: reader.databaseInstance,
            notebookId: snapshot.pin.notebookId, generationId: generationId, dims: dims))
    }

    /// Fills one resident block from bounded pages; false when the pairs hold more rows
    /// than were counted (the caller then streams).
    private static func fillResident(_ block: ResidentBlock, pairs: [Int64: Int64], reader: RetrievalReadStore,
                                     snapshot: ResolvedRetrievalScope) async throws -> Bool {
        let operation = try snapshot.acquireOperation()
        do {
            let json = try RetrievalSQL.pairs(pairs)
            var cursor: Int64 = 0
            while true {
                try Task.checkCancellation()
                let page = try await reader.residentPage(operation, pairs: pairs, pairsJSON: json,
                                                         afterChunkId: cursor, rowLimit: 1024)
                guard block.append(page) else { await operation.close(); return false }
                cursor = page.lastScannedChunkId
                if page.exhausted { break }
            }
            await operation.close()
            return true
        } catch {
            await operation.close()
            throw error
        }
    }

    /// Resident and streamed scans feed the same masked heap with identical binary16-rounded
    /// rows; streaming normalizes one bounded page at a time and never sorts all scores.
    private func scanTopK(_ state: inout ScanState, reader: RetrievalReadStore, operation: RetrievalOperation,
                          snapshot: ResolvedRetrievalScope, query: [Float], mask: Set<Int64>,
                          k: Int, dims: Int) async throws -> [ScoredChunk] {
        if state.empty { return [] }
        if let key = state.resident {
            let pins = snapshot.pin.vectorRevisions
            let allowed = pins.filter { mask.contains($0.key) }
            if let result = try await cache.residentTopK(key: key, pins: pins, allowed: allowed, query: query, k: k,
                count: { pairs in
                    let operation = try snapshot.acquireOperation()
                    do {
                        let rows = try await reader.residentCount(operation, pairs: pairs)
                        await operation.close()
                        return rows
                    } catch { await operation.close(); throw error }
                },
                fill: { pairs, block in try await Self.fillResident(block, pairs: pairs, reader: reader, snapshot: snapshot) }) {
                state.invalidVectorCount = result.invalidVectorCount
                state.peakPageBytes = result.peakPageBytes
                return result.scored
            }
            state.resident = nil
            state.streamed = true
        }
        state.streamed = true
        guard var heap = MaskedVectorTopK(query: query, dims: dims, permittedSources: mask, k: k) else { return [] }
        var cursor: Int64 = 0, invalid = 0, peak = state.peakPageBytes
        let row = UnsafeMutablePointer<Float>.allocate(capacity: dims)
        let scratch = UnsafeMutablePointer<Double>.allocate(capacity: dims)
        defer { row.deallocate(); scratch.deallocate() }
        while true {
            try Task.checkCancellation()
            let page = try await reader.rawVectorPage(operation, afterChunkId: cursor, rowLimit: 1024)
            peak = max(peak, Int64(page.payloadBytes))
            for raw in page.rows {
                guard HalfPrecision.decodeNormalized(raw.blob, into: row, dims: dims, scratch: scratch) else { invalid += 1; continue }
                let buffer = UnsafeMutableBufferPointer(start: row, count: dims)
                HalfPrecision.round(buffer)
                heap.offer(raw.reference, normalizedRow: UnsafeBufferPointer(buffer))
            }
            cursor = page.lastScannedChunkId
            if page.exhausted { break }
        }
        state.invalidVectorCount = invalid
        state.peakPageBytes = peak
        return heap.sorted()
    }

    // MARK: - Compatibility adapters

    /// Legacy chat retrieval: empty `sourceIds` means all sources; each branch
    /// fetches `topK`, the fused pool is cut to `topK` with revision-correct
    /// display snippets copied while the pin is held. Provider failures still
    /// propagate, as before; the score is display-only.
    public func search(
        notebookId: Int64,
        query: String,
        topK: Int = 8,
        sourceIds: Set<Int64> = []
    ) async throws -> [RetrievalHit] {
        guard topK > 0 else { return [] }
        let scope: RetrievalScope = sourceIds.isEmpty ? .all : .selection(sourceIds: sourceIds, folderIds: [])
        let pool = try await search(notebookId: notebookId, query: query, scope: scope, fetchK: topK)
        do {
            if let error = pool.embeddingError { throw error }
            let selected = Array(pool.fused.prefix(topK))
            let snippets = try await displaySnippets(pool, references: selected.map(\.reference))
            await pool.close()
            return selected.compactMap(Self.hit(snippets))
        } catch {
            await pool.close()
            throw error
        }
    }

    /// Eval diagnostics: fetchK caps each branch, while fused retains their full
    /// union. Unlike legacy search, an explicit empty selection means no work.
    /// Malformed query vectors and in-scope stored vectors remain eval errors.
    public func candidates(notebookId: Int64, query: String, fetchK: Int = 32,
                           sourceIds: Set<Int64>? = nil, includeVectors: Bool = true) async throws -> RetrievalCandidates {
        guard fetchK > 0, rrfK > 0 else { throw EvalFailure("invalid_fetch_k") }
        if sourceIds?.isEmpty == true { return RetrievalCandidates(lexical: [], vector: [], fused: []) }
        let scope: RetrievalScope = sourceIds.map { .selection(sourceIds: $0, folderIds: []) } ?? .all
        let pool = try await search(notebookId: notebookId, query: query, scope: scope,
                                    fetchK: fetchK, includeVectors: includeVectors)
        do {
            if let error = pool.embeddingError { throw error }
            switch pool.diagnostics.vectorStatus {
            case "invalidQueryVector", "oversizedVector": throw EvalFailure("invalid_embedding")
            case "used", "legacyEndpointUnverified": try await validateScopedVectors(pool)
            default: break
            }
            let snippets = try await displaySnippets(pool, references: (pool.lexical + pool.vector + pool.fused).map(\.reference))
            let result = RetrievalCandidates(lexical: pool.lexical.compactMap(Self.hit(snippets)),
                                             vector: pool.vector.compactMap(Self.hit(snippets)),
                                             fused: pool.fused.compactMap(Self.hit(snippets)))
            await pool.close()
            return result
        } catch {
            await pool.close()
            throw error
        }
    }

    private static func hit(_ snippets: [Int64: String]) -> @Sendable (PinnedRetrievalCandidate) -> RetrievalHit? {
        { candidate in
            snippets[candidate.reference.chunkId].map {
                RetrievalHit(chunkId: candidate.reference.chunkId, sourceId: candidate.reference.sourceId,
                             score: Float(candidate.rrfMicro) / 1_000_000, snippet: $0)
            }
        }
    }

    /// Copies display snippets from the candidates' explicit revisions while the
    /// pool's pin is held; revoked sources yield no snippet and are dropped.
    private func displaySnippets(_ pool: PinnedRetrievalCandidates,
                                 references: [ChunkReference]) async throws -> [Int64: String] {
        guard let snapshot = pool.snapshot, !references.isEmpty else { return [:] }
        let reader = await readStore()
        let operation = try snapshot.acquireOperation()
        do {
            let passages = try await EvidenceHydrator(reader: reader)
                .hydrate(operation, references: references, neighborRadius: 0)
            await operation.close()
            return Dictionary(passages.map { ($0.reference.chunkId, $0.displaySnippet) }, uniquingKeysWith: { first, _ in first })
        } catch {
            await operation.close()
            throw error
        }
    }

    /// Eval-only strictness: every in-scope stored vector must be well-formed,
    /// finite and nonzero; corruption outside the scope does not fail the query.
    private func validateScopedVectors(_ pool: PinnedRetrievalCandidates) async throws {
        guard let snapshot = pool.snapshot, let dims = snapshot.pin.dims else { return }
        let reader = await readStore()
        let operation = try snapshot.acquireOperation()
        do {
            let permitted = try await reader.permittedSourceIds(operation)
            var cursor: Int64 = 0
            while true {
                try Task.checkCancellation()
                let page = try await reader.rawVectorPage(operation, afterChunkId: cursor, rowLimit: 1024)
                for raw in page.rows where permitted.contains(raw.reference.sourceId) {
                    guard let row = RetrievalSQL.decode(raw, dims: dims), row.values.contains(where: { $0 != 0 }) else {
                        throw EvalFailure("invalid_embedding")
                    }
                }
                cursor = page.lastScannedChunkId
                if page.exhausted { break }
            }
            await operation.close()
        } catch {
            await operation.close()
            throw error
        }
    }
}

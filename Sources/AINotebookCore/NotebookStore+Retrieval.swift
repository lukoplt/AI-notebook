import Foundation
import GRDB

extension NotebookStore {
    /// embedding-raw-format-v2 §3: the one-line path header of each chunk's source.
    func embeddingHeaders(chunkIds: [Int64]) throws -> [Int64: String] {
        guard !chunkIds.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id,s.rel_path,s.title FROM source_chunks c JOIN sources s ON s.id=c.source_id
                WHERE c.id IN (SELECT CAST(value AS INTEGER) FROM json_each(?))
                """, arguments: [try RetrievalSQL.json(chunkIds)])
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0["id"] as Int64, RawEmbeddingFormat.header(relPath: $0["rel_path"], title: $0["title"]))
            })
        }
    }

    public func makeRetrievalReader() -> RetrievalReadStore {
        RetrievalReadStore(queue: dbQueue, invalidation: retrievalInvalidation, databaseId: generationDatabaseIdentity)
    }
}

internal enum RetrievalSQL {
    static let predicate = """
        s.notebook_id=$nb AND s.availability='present' AND s.eligible=1
        AND ($all=1 OR s.id IN (SELECT CAST(value AS INTEGER) FROM json_each($sourceIds))
             OR s.folder_id IN (SELECT CAST(value AS INTEGER) FROM json_each($folderIds)))
        """
    static let initial = "s.id IN (SELECT CAST(value AS INTEGER) FROM json_each($initialSourceIds))"
    static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    static func arguments(notebookId: Int64, scope: RetrievalScope) throws -> StatementArguments {
        let all: Int, sources: [Int64], folders: [Int64]
        switch scope {
        case .all: all = 1; sources = []; folders = []
        case let .selection(s, f): all = 0; sources = s.sorted(); folders = f.sorted()
        }
        return ["nb": notebookId, "all": all, "sourceIds": try json(sources), "folderIds": try json(folders)]
    }
    static func arguments(_ snapshot: ResolvedRetrievalScope) throws -> StatementArguments {
        var args = try arguments(notebookId: snapshot.pin.notebookId, scope: snapshot.scope)
        args += ["initialSourceIds": snapshot.initialSourceIdsJSON]
        return args
    }
    static func pairs(_ revisions: [Int64: Int64]) throws -> String {
        try json(revisions.keys.sorted().map { ["sourceId": $0, "revisionId": revisions[$0]!] })
    }
    /// A pinned `(source_id, revision_id)` list as an uncorrelated row-value `IN` operand.
    /// SQLite materializes it once per statement into an ephemeral index (+ bloom filter),
    /// so each candidate row costs one probe. Never `JOIN json_each(...)` with `json_extract`
    /// in the ON clause: that re-parses the whole pin per joined row (O(rows x pairs)).
    static func pinned(_ parameter: String) -> String {
        """
        (SELECT CAST(json_extract(value,'$.sourceId') AS INTEGER),CAST(json_extract(value,'$.revisionId') AS INTEGER) \
        FROM json_each($\(parameter)))
        """
    }
    /// First bm25 window of the lexical branch; widened 8x while filters leave too few rows.
    static func lexicalWindow(limit: Int) -> Int { max(256, limit * 8) }
    static func reference(_ row: Row) -> ChunkReference {
        .init(chunkId: row["id"], sourceId: row["source_id"], revisionId: row["revision_id"], ord: row["ord"])
    }
    static func permitted(_ db: Database, snapshot: ResolvedRetrievalScope) throws -> Set<Int64> {
        Set(try Int64.fetchAll(db, sql: "SELECT s.id FROM sources s WHERE \(predicate) AND \(initial)",
                              arguments: arguments(snapshot)))
    }
    static let vectorFrom = """
        FROM chunk_embeddings ce
        JOIN source_chunks sc ON sc.id=ce.chunk_id
        JOIN index_generation_manifest m ON m.generation_id=ce.generation_id
          AND m.source_id=sc.source_id AND m.revision_id=sc.revision_id AND m.state='done'
        JOIN sources s ON s.id=sc.source_id
        WHERE ce.generation_id=$generation AND s.notebook_id=$nb
          AND s.availability='present' AND s.eligible=1
          AND (sc.source_id,sc.revision_id) IN \(pinned("vectorPairs"))
        """
    static func vectorArguments(_ snapshot: ResolvedRetrievalScope) throws -> StatementArguments {
        ["nb": snapshot.pin.notebookId, "generation": snapshot.pin.generationId,
         "vectorPairs": try pairs(snapshot.pin.vectorRevisions)]
    }
    static func byteWidth(dims: Int) -> Int? {
        guard dims > 0, dims <= 8_388_608 / 4 else { return nil }
        return dims * 4
    }
    static func decode(_ row: RawVectorRow, dims: Int) -> VectorRow? {
        guard let width = byteWidth(dims: dims), let blob = row.blob, blob.count == width else { return nil }
        let values: [Float] = blob.withUnsafeBytes { bytes in
            (0..<dims).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        guard values.allSatisfy(\.isFinite) else { return nil }
        return VectorRow(reference: row.reference, values: values)
    }
}

/// GRDB executes every scan on its database executor. Only copied Sendable values
/// cross the boundary; vector decoding and scoring happen after the read returns.
public struct RetrievalReadStore: Sendable {
    internal let queue: any DatabaseWriter
    private let invalidation: RetrievalInvalidation
    internal init(queue: any DatabaseWriter, invalidation: RetrievalInvalidation, databaseId: String) {
        self.queue = queue
        self.invalidation = invalidation
        self.databaseId = databaseId
    }
    private func borrowing<T: Sendable>(_ snapshot: ResolvedRetrievalScope,
        _ body: @Sendable (RetrievalOperation) async throws -> T) async throws -> T {
        let operation = try snapshot.acquireOperation()
        do {
            let value = try await body(operation)
            await operation.close()
            return value
        } catch {
            await operation.close()
            throw error
        }
    }
    public func lexical(_ snapshot: ResolvedRetrievalScope, expression: String?, limit: Int) async throws -> [ChunkReference] {
        try await borrowing(snapshot) { operation in
            guard expression != nil else { return [] }
            let permitted = try await permittedSourceIds(operation)
            return try await lexical(operation, expression: expression, limit: limit, permittedSources: permitted)
        }
    }
    internal func lexical(_ operation: RetrievalOperation, expression: String?, limit: Int,
                          permittedSources: Set<Int64>) async throws -> [ChunkReference] {
        try operation.checkOpen()
        guard let expression else { return [] }
        guard limit > 0 else { throw RetrievalError.invalidFetchK }
        let snapshot = operation.snapshot
        var args = try RetrievalSQL.arguments(snapshot)
        args += ["published": try RetrievalSQL.pairs(snapshot.pin.lexicalRevisions), "query": expression,
                 "limit": limit, "permittedSources": try RetrievalSQL.json(permittedSources.sorted())]
        var window = RetrievalSQL.lexicalWindow(limit: limit)
        while true {
            try Task.checkCancellation()
            var bound = args
            bound += ["window": window]
            let statement = bound
            // bm25 is computed once per FTS match inside the materialized window; only the
            // window's rows are joined and filtered. (score, rowid) is the global order and
            // rowid = chunk id, so the filtered prefix of a window holding >= `limit` rows,
            // or of an exhausted window, equals the filtered prefix of the full match set.
            let (rows, windowRows) = try await queue.read { db -> ([ChunkReference], Int) in
                let rows = try Row.fetchAll(db, sql: """
                    WITH hits AS MATERIALIZED (
                      SELECT rowid AS id,bm25(chunks_fts) AS score FROM chunks_fts
                      WHERE chunks_fts MATCH $query ORDER BY score,rowid LIMIT $window),
                    picked AS (
                      SELECT hits.score,sc.id,sc.source_id,sc.revision_id,sc.ord
                      FROM hits JOIN source_chunks sc ON sc.id=hits.id
                      JOIN sources s ON s.id=sc.source_id
                      WHERE (sc.source_id,sc.revision_id) IN \(RetrievalSQL.pinned("published"))
                        AND \(RetrievalSQL.predicate) AND \(RetrievalSQL.initial)
                        AND s.id IN (SELECT CAST(value AS INTEGER) FROM json_each($permittedSources))
                      ORDER BY hits.score,sc.id LIMIT $limit)
                    SELECT (SELECT count(*) FROM hits) AS window_rows,picked.id,picked.source_id,picked.revision_id,picked.ord
                    FROM (SELECT 1) LEFT JOIN picked ON 1 ORDER BY picked.score,picked.id
                    """, arguments: statement)
                let total: Int = rows.first?["window_rows"] ?? 0
                return (rows.compactMap { row in
                    (row["id"] as Int64?) == nil ? nil : RetrievalSQL.reference(row)
                }, total)
            }
            if rows.count >= limit || windowRows < window || window < 0 { return rows }
            window = window > Int.max / 64 ? -1 : window * 8
        }
    }
    public func vectorCount(_ snapshot: ResolvedRetrievalScope) async throws -> Int {
        try await borrowing(snapshot) { try await vectorCount($0) }
    }
    internal func vectorCount(_ operation: RetrievalOperation) async throws -> Int {
        try operation.checkOpen()
        let snapshot = operation.snapshot
        guard snapshot.pin.generationId != nil,
              RetrievalSQL.byteWidth(dims: snapshot.pin.dims ?? 0) != nil else { return 0 }
        let args = try RetrievalSQL.vectorArguments(snapshot)
        return try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) \(RetrievalSQL.vectorFrom)", arguments: args)!
        }
    }
    internal func rawVectorPage(_ operation: RetrievalOperation, afterChunkId: Int64, rowLimit: Int) async throws -> RawVectorPage {
        try operation.checkOpen()
        let snapshot = operation.snapshot
        guard snapshot.pin.generationId != nil,
              let width = RetrievalSQL.byteWidth(dims: snapshot.pin.dims ?? 0) else {
            return RawVectorPage(rows: [], lastScannedChunkId: afterChunkId, exhausted: true, payloadBytes: 0)
        }
        let limit = min(max(rowLimit, 1), 1024, 8_388_608 / width)
        var args = try RetrievalSQL.vectorArguments(snapshot)
        args += ["byteWidth": width, "after": afterChunkId, "limit": limit]
        let bound = args
        return try await queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT sc.id,sc.source_id,sc.revision_id,sc.ord,
                  CASE WHEN length(ce.embedding)=$byteWidth THEN ce.embedding ELSE NULL END AS embedding
                \(RetrievalSQL.vectorFrom) AND ce.chunk_id>$after ORDER BY ce.chunk_id LIMIT $limit
                """, arguments: bound).map { RawVectorRow(reference: RetrievalSQL.reference($0), blob: $0["embedding"]) }
            return RawVectorPage(rows: rows, lastScannedChunkId: rows.last?.reference.chunkId ?? afterChunkId,
                                 exhausted: rows.count < limit, payloadBytes: rows.reduce(0) { $0 + ($1.blob?.count ?? 0) })
        }
    }
    /// Resident-matrix loads read a generation's rows of the given (source, revision) pairs by
    /// identity only: availability, eligibility and the manifest are the pin's business, so a
    /// pair loaded once stays valid for every later pin that names it (retrieval-resident-v1 §2).
    /// Few pairs are read through the revision index, many by one pass over the generation.
    static let residentPairDriverLimit = 64
    private static func residentFrom(_ pairs: Int) -> String {
        pairs <= residentPairDriverLimit ? """
            FROM source_chunks sc JOIN chunk_embeddings ce ON ce.chunk_id=sc.id AND ce.generation_id=$generation
            WHERE sc.revision_id IN (SELECT CAST(json_extract(value,'$.revisionId') AS INTEGER) FROM json_each($pairs))
              AND (sc.source_id,sc.revision_id) IN \(RetrievalSQL.pinned("pairs"))
            """ : """
            FROM chunk_embeddings ce JOIN source_chunks sc ON sc.id=ce.chunk_id
            WHERE ce.generation_id=$generation AND (sc.source_id,sc.revision_id) IN \(RetrievalSQL.pinned("pairs"))
            """
    }
    /// The driving table's id column, so the page order is an index order (no sort).
    private static func residentOrder(_ pairs: Int) -> String { pairs <= residentPairDriverLimit ? "sc.id" : "ce.chunk_id" }
    internal func residentCount(_ operation: RetrievalOperation, pairs: [Int64: Int64]) async throws -> Int {
        try operation.checkOpen()
        guard let generation = operation.snapshot.pin.generationId, !pairs.isEmpty else { return 0 }
        let args: StatementArguments = ["generation": generation, "pairs": try RetrievalSQL.pairs(pairs)]
        let sql = "SELECT count(*) " + Self.residentFrom(pairs.count)
        return try await queue.read { try Int.fetchOne($0, sql: sql, arguments: args)! }
    }
    internal func residentPage(_ operation: RetrievalOperation, pairs: [Int64: Int64], pairsJSON: String,
                               afterChunkId: Int64, rowLimit: Int) async throws -> RawVectorPage {
        try operation.checkOpen()
        guard let generation = operation.snapshot.pin.generationId, !pairs.isEmpty,
              let width = RetrievalSQL.byteWidth(dims: operation.snapshot.pin.dims ?? 0) else {
            return RawVectorPage(rows: [], lastScannedChunkId: afterChunkId, exhausted: true, payloadBytes: 0)
        }
        let limit = min(max(rowLimit, 1), 1024, 8_388_608 / width)
        let args: StatementArguments = ["generation": generation, "pairs": pairsJSON, "byteWidth": width,
                                        "after": afterChunkId, "limit": limit]
        let sql = """
            SELECT sc.id,sc.source_id,sc.revision_id,sc.ord,
              CASE WHEN length(ce.embedding)=$byteWidth THEN ce.embedding ELSE NULL END AS embedding
            \(Self.residentFrom(pairs.count)) AND \(Self.residentOrder(pairs.count))>$after
            ORDER BY \(Self.residentOrder(pairs.count)) LIMIT $limit
            """
        return try await queue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: args).map {
                RawVectorRow(reference: RetrievalSQL.reference($0), blob: $0["embedding"])
            }
            return RawVectorPage(rows: rows, lastScannedChunkId: rows.last?.reference.chunkId ?? afterChunkId,
                                 exhausted: rows.count < limit, payloadBytes: rows.reduce(0) { $0 + ($1.blob?.count ?? 0) })
        }
    }
    internal var databaseInstance: String { invalidation.instanceId }
    internal let databaseId: String

    public func vectorPage(_ snapshot: ResolvedRetrievalScope, afterChunkId: Int64, limit: Int) async throws -> [VectorRow] {
        try await borrowing(snapshot) { operation in
            guard limit > 0 else { throw RetrievalError.invalidFetchK }
            guard let width = RetrievalSQL.byteWidth(dims: snapshot.pin.dims ?? 0) else { return [] }
            let wanted = min(limit, 1024, 8_388_608 / width)
            var permitted = try await permittedSourceIds(operation)
            while true {
                var result: [VectorRow] = [], cursor = afterChunkId
                while result.count < wanted {
                    try Task.checkCancellation()
                    let page = try await rawVectorPage(operation, afterChunkId: cursor, rowLimit: wanted - result.count)
                    cursor = page.lastScannedChunkId
                    for row in page.rows where permitted.contains(row.reference.sourceId) {
                        if let decoded = RetrievalSQL.decode(row, dims: snapshot.pin.dims!) { result.append(decoded) }
                    }
                    if page.exhausted { break }
                }
                let current = try await permittedSourceIds(operation).intersection(permitted)
                if current == permitted { return result }
                // Retry from the caller's cursor: a revoked row cannot turn a
                // partially filled page into false EOF and hide later valid rows.
                permitted = current
                try Task.checkCancellation()
            }
        }
    }
    public func permittedSourceIds(_ snapshot: ResolvedRetrievalScope) async throws -> Set<Int64> {
        try await borrowing(snapshot) { try await permittedSourceIds($0) }
    }
    internal func permittedSourceIds(_ operation: RetrievalOperation) async throws -> Set<Int64> {
        try operation.checkOpen()
        return try await queue.read { try RetrievalSQL.permitted($0, snapshot: operation.snapshot) }
    }
    public func evidenceRows(_ snapshot: ResolvedRetrievalScope, references: [ChunkReference]) async throws -> [ChunkEvidenceRow] {
        try await borrowing(snapshot) { try await evidenceRows($0, references: references) }
    }
    internal func evidenceRows(_ operation: RetrievalOperation, references: [ChunkReference]) async throws -> [ChunkEvidenceRow] {
        try operation.checkOpen()
        guard !references.isEmpty else { return [] }
        let ids = try RetrievalSQL.json(Set(references.map(\.chunkId)).sorted())
        let snapshot = operation.snapshot
        return try await queue.read { db in
            // Identity validation precedes permission filtering: a mismatched request
            // is corruption even when its supplied revision is outside the pin.
            let rows = try Row.fetchAll(db, sql: """
                SELECT id,source_id,revision_id,ord,text,char_start,char_end,page_hint FROM source_chunks
                WHERE id IN (SELECT CAST(value AS INTEGER) FROM json_each(?))
                """, arguments: [ids])
            let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as Int64, $0) })
            for reference in references {
                if let actual = byId[reference.chunkId] {
                    let source: Int64 = actual["source_id"], revision: Int64? = actual["revision_id"]
                    guard source == reference.sourceId, revision == reference.revisionId else { throw RetrievalError.revisionMismatch }
                }
            }
            let permitted = try RetrievalSQL.permitted(db, snapshot: snapshot)
            let selected = references.compactMap { ref -> Row? in
                guard permitted.contains(ref.sourceId),
                      snapshot.pin.lexicalRevisions[ref.sourceId] == ref.revisionId || snapshot.pin.vectorRevisions[ref.sourceId] == ref.revisionId
                else { return nil }
                return byId[ref.chunkId]
            }
            let revisions = try RetrievalSQL.json(Set(selected.map { $0["revision_id"] as Int64 }).sorted())
            let texts = try Row.fetchAll(db, sql: """
                SELECT id,canonical_text,chunker_version FROM source_revisions
                WHERE id IN (SELECT CAST(value AS INTEGER) FROM json_each(?))
                """, arguments: [revisions])
            let byRevision = Dictionary(uniqueKeysWithValues: texts.map { row in
                (row["id"] as Int64, (text: row["canonical_text"] as String, version: row["chunker_version"] as Int))
            })
            return selected.compactMap { row in
                guard let revision = byRevision[row["revision_id"] as Int64] else { return nil }
                return ChunkEvidenceRow(reference: RetrievalSQL.reference(row), canonicalText: revision.text,
                    chunkText: row["text"], charStart: row["char_start"], charEnd: row["char_end"],
                    pageHint: row["page_hint"], chunkerVersion: revision.version)
            }
        }
    }
    public func neighbourReferences(_ snapshot: ResolvedRetrievalScope, center: ChunkReference, radius: Int) async throws -> [ChunkReference] {
        try await borrowing(snapshot) { try await neighbourReferences($0, center: center, radius: radius) }
    }
    internal func neighbourReferences(_ operation: RetrievalOperation, center: ChunkReference, radius: Int) async throws -> [ChunkReference] {
        try operation.checkOpen()
        guard radius >= 0 else { throw RetrievalError.invalidRadius }
        let snapshot = operation.snapshot
        // Initial-scope membership is a set lookup here: binding the whole id list would make
        // SQLite materialize it for every one of the pack's neighbour reads.
        guard radius > 0, snapshot.initialSourceIds.contains(center.sourceId),
              let published = snapshot.pin.lexicalRevisions[center.sourceId] else { return [] }
        let (sum, overflow) = Int64(center.ord).addingReportingOverflow(Int64(radius))
        let (difference, underflow) = Int64(center.ord).subtractingReportingOverflow(Int64(radius))
        var args = try RetrievalSQL.arguments(notebookId: snapshot.pin.notebookId, scope: snapshot.scope)
        args += ["source": center.sourceId, "publishedRevision": published,
                 "firstOrd": underflow ? 0 : max(0, difference), "lastOrd": overflow ? Int64.max : sum, "centerChunk": center.chunkId]
        let bound = args
        return try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT sc.id,sc.source_id,sc.revision_id,sc.ord FROM source_chunks sc JOIN sources s ON s.id=sc.source_id
                WHERE sc.source_id=$source AND sc.revision_id=$publishedRevision
                  AND sc.ord BETWEEN $firstOrd AND $lastOrd AND sc.id<>$centerChunk
                  AND \(RetrievalSQL.predicate) ORDER BY sc.ord,sc.id
                """, arguments: bound).map(RetrievalSQL.reference)
        }
    }
    /// The lowest-ordinal chunk of each given (source, published revision), keyed by source.
    internal func firstChunks(_ operation: RetrievalOperation, revisions: [Int64: Int64]) async throws -> [Int64: ChunkReference] {
        try operation.checkOpen()
        guard !revisions.isEmpty else { return [:] }
        let args: StatementArguments = [try RetrievalSQL.pairs(revisions)]
        return try await queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT sc.id,sc.source_id,sc.revision_id,sc.ord FROM json_each(?) p
                JOIN source_chunks sc ON sc.revision_id=CAST(json_extract(p.value,'$.revisionId') AS INTEGER)
                  AND sc.source_id=CAST(json_extract(p.value,'$.sourceId') AS INTEGER)
                WHERE sc.ord=(SELECT min(c.ord) FROM source_chunks c WHERE c.revision_id=sc.revision_id)
                """, arguments: args).map(RetrievalSQL.reference)
            return Dictionary(rows.map { ($0.sourceId, $0) }, uniquingKeysWith: { a, b in a.chunkId < b.chunkId ? a : b })
        }
    }
    public func metadata(_ snapshot: ResolvedRetrievalScope) async throws -> [ScopedSource] {
        try await borrowing(snapshot) { operation in
            let permitted = try await permittedSourceIds(operation)
            return snapshot.sources.filter { $0.publishedRevisionId != nil && permitted.contains($0.sourceId) }
        }
    }
    public func currentEpoch(_ snapshot: ResolvedRetrievalScope) async throws -> UInt64 {
        try await borrowing(snapshot) { try await currentEpoch($0) }
    }
    internal func currentEpoch(_ operation: RetrievalOperation) async throws -> UInt64 {
        try operation.checkOpen()
        return try await queue.read { try invalidation.observe(db: $0) }
    }
    public func observedEpoch() -> UInt64 { invalidation.observedEpoch() }
}

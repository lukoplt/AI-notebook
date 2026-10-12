import Foundation
import GRDB

/// Stateless generation operations composed inside the caller's transaction.
enum GenerationSQL {
    static func generation(_ db: Database, id: Int64) throws -> IndexGeneration? {
        try Row.fetchOne(db, sql: "SELECT * FROM index_generations WHERE id=?", arguments: [id]).map(decodeGeneration)
    }

    static func activeGeneration(_ db: Database, notebookId: Int64) throws -> IndexGeneration? {
        try Row.fetchOne(db, sql: "SELECT * FROM index_generations WHERE notebook_id=? AND state='active'",
                         arguments: [notebookId]).map(decodeGeneration)
    }

    /// retrieval-partial-index-v1 §3.1: with no active generation, the newest building
    /// generation of the query's storage model key may serve its completed sources.
    static func partialCandidate(_ db: Database, notebookId: Int64, modelKey: String) throws -> IndexGeneration? {
        guard !modelKey.isEmpty else { return nil }
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM index_generations WHERE notebook_id=? AND state='building' ORDER BY id DESC",
                                    arguments: [notebookId])
        return rows.lazy.map(decodeGeneration).first { $0.identity.modelKey.utf8.elementsEqual(modelKey.utf8) }
    }

    static func manifest(_ db: Database, generationId: Int64) throws -> [ManifestEntry] {
        guard try generation(db, id: generationId) != nil else { throw StorageV19Error.notFound }
        return try Row.fetchAll(db, sql: """
            SELECT source_id,revision_id,state,reason FROM index_generation_manifest WHERE generation_id=? ORDER BY source_id
            """, arguments: [generationId]).map {
                ManifestEntry(sourceId: $0["source_id"], revisionId: $0["revision_id"], state: $0["state"], reason: $0["reason"])
            }
    }

    static func create(_ db: Database, notebookId: Int64, identity: GenerationIdentity, now: Int64) throws -> IndexGeneration {
        guard identity.dims > 0, identity.dims <= Int.max / MemoryLayout<Float>.size,
              !identity.providerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !identity.endpointRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !identity.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["legacy", "l2"].contains(identity.normalization),
              validFormat(identity.queryFormatVersion) || EmbeddingProfiles.isFormatVersion(identity.queryFormatVersion, purpose: .query),
              validFormat(identity.docFormatVersion) || EmbeddingProfiles.isFormatVersion(identity.docFormatVersion, purpose: .document),
              validFormat(identity.chunkerVersion) else { throw StorageV19Error.invalidValue }
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM notebooks WHERE id=?", arguments: [notebookId]) != nil else {
            throw StorageV19Error.notFound
        }
        try db.execute(sql: """
            INSERT INTO index_generations(notebook_id,provider_id,endpoint_revision,model,model_digest,dims,
                normalization,query_format_version,doc_format_version,chunker_version,state,created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,'building',?)
            """, arguments: [notebookId, identity.providerId, identity.endpointRevision, identity.model,
                               identity.modelDigest, identity.dims, identity.normalization, identity.queryFormatVersion,
                               identity.docFormatVersion, identity.chunkerVersion, Date(timeIntervalSince1970: TimeInterval(now))])
        let id = db.lastInsertedRowID
        try db.execute(sql: """
            INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state)
            SELECT ?,id,current_revision,'pending' FROM sources
            WHERE notebook_id=? AND availability='present' AND eligible=1 AND current_revision IS NOT NULL
            """, arguments: [id, notebookId])
        return IndexGeneration(id: id, notebookId: notebookId, identity: identity, state: "building", createdAt: now, activatedAt: nil)
    }

    static func reconcile(_ db: Database, generationId: Int64) throws {
        let generation = try requireBuilding(db, id: generationId)
        // A source without a current extraction is coverage-pending and cannot be a manifest member.
        try db.execute(sql: """
            DELETE FROM index_generation_manifest WHERE generation_id=? AND source_id IN
                (SELECT id FROM sources WHERE current_revision IS NULL)
            """, arguments: [generationId])
        // Runs before every background batch: only rows whose manifest entry the loop
        // below would change are returned, so a settled manifest is neither decoded
        // nor rewritten (an identical exclusion is not upserted again).
        let sources = try Row.fetchAll(db, sql: """
            SELECT s.id,s.current_revision,s.availability,s.eligible,m.revision_id,m.state,m.reason
            FROM sources s LEFT JOIN index_generation_manifest m ON m.source_id=s.id AND m.generation_id=?
            WHERE s.notebook_id=? AND s.current_revision IS NOT NULL
              AND CASE WHEN s.availability<>'present' OR s.eligible=0
                THEN m.source_id IS NOT NULL AND NOT (m.revision_id=s.current_revision AND m.state='excluded'
                    AND m.reason=(CASE WHEN s.availability<>'present' THEN s.availability ELSE 'ineligible' END))
                ELSE m.source_id IS NULL OR m.revision_id<>s.current_revision
                    OR (m.state='excluded' AND m.reason IN ('missing','unavailable','ineligible')) END
            ORDER BY s.id
            """, arguments: [generationId, generation.notebookId])
        for row in sources {
            let sourceId: Int64 = row["id"]
            let current: Int64 = row["current_revision"]
            let previousRevision: Int64? = row["revision_id"]
            let previousState: String? = row["state"]
            let previousReason: String? = row["reason"]
            let availability: String = row["availability"]
            let eligible: Bool = row["eligible"]
            let reason: String? = availability != "present" ? availability : (!eligible ? "ineligible" : nil)
            if let reason {
                // Initial creation omits unavailable sources; only prior members need an exclusion row.
                if previousRevision != nil {
                    try upsertManifest(db, generationId: generationId,
                                       entry: ManifestEntry(sourceId: sourceId, revisionId: current, state: "excluded", reason: reason))
                }
            } else if previousRevision != current ||
                (previousState == "excluded" && ["missing", "unavailable", "ineligible"].contains(previousReason ?? "")) {
                try upsertManifest(db, generationId: generationId,
                                   entry: ManifestEntry(sourceId: sourceId, revisionId: current, state: "pending", reason: nil))
            }
        }
    }

    static func setManifest(_ db: Database, generationId: Int64, entries: [ManifestEntry]) throws {
        let generation = try requireBuilding(db, id: generationId)
        for entry in entries {
            guard ["pending", "done", "excluded"].contains(entry.state),
                  entry.state != "excluded" || !(entry.reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
                throw StorageV19Error.invalidValue
            }
            try validateManifestOwner(db, generation: generation, entry: entry)
            if entry.state == "done" {
                guard try revisionComplete(db, generation: generation, sourceId: entry.sourceId, revisionId: entry.revisionId) else {
                    throw StorageV19Error.generationNotReady
                }
            }
        }
        for entry in entries {
            try upsertManifest(db, generationId: generationId, entry: entry)
        }
    }

    static func storeEmbedding(_ db: Database, generationId: Int64, chunkId: Int64, vector: EmbeddingVector) throws {
        try storeEmbedding(db, building: try requireBuilding(db, id: generationId), chunkId: chunkId, vector: vector)
    }

    /// Kernel for a generation the caller already read as `building` in this
    /// transaction (batch commits store many vectors). Statements are cached.
    static func storeEmbedding(_ db: Database, building generation: IndexGeneration, chunkId: Int64, vector: EmbeddingVector) throws {
        guard generation.state == "building" else { throw StorageV19Error.generationNotReady }
        let generationId = generation.id
        guard vector.dim == generation.identity.dims else { throw StorageV19Error.invalidVector }
        guard let chunk = try Row.fetchOne(db.cachedStatement(sql: """
            SELECT c.source_id,c.revision_id,s.notebook_id FROM source_chunks c JOIN sources s ON s.id=c.source_id WHERE c.id=?
            """), arguments: [chunkId]) else { throw StorageV19Error.notFound }
        let notebookId: Int64 = chunk["notebook_id"]
        let sourceId: Int64 = chunk["source_id"]
        let revisionId: Int64? = chunk["revision_id"]
        guard notebookId == generation.notebookId else { throw StorageV19Error.notebookMismatch }
        guard let revisionId, try Int.fetchOne(db.cachedStatement(sql: """
            SELECT 1 FROM index_generation_manifest WHERE generation_id=? AND source_id=? AND revision_id=?
            """), arguments: [generationId, sourceId, revisionId]) != nil else { throw StorageV19Error.staleRevision }
        let data: Data
        if generation.identity.normalization == "l2" {
            guard vector.values.allSatisfy(\.isFinite) else { throw StorageV19Error.invalidVector }
            let normSquared = vector.values.reduce(0.0) { $0 + Double($1) * Double($1) }
            guard normSquared.isFinite, normSquared > 0 else { throw StorageV19Error.invalidVector }
            let norm = normSquared.squareRoot()
            data = EmbeddingVector(values: vector.values.map { Float(Double($0) / norm) }).asData()
        } else {
            // Legacy vectors are copied byte-for-byte, including historical zero vectors.
            data = vector.asData()
        }
        try db.cachedStatement(sql: """
            INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES(?,?,?)
            ON CONFLICT(chunk_id,generation_id) DO UPDATE SET embedding=excluded.embedding
            """).execute(arguments: [chunkId, generationId, data])
    }

    static func activate(_ db: Database, id: Int64, fence: JobFence?, now: Int64) throws {
        if let fence {
            guard let job = try RevisionJobSQL.validateFence(db, fence: fence, now: now) else { throw StorageV19Error.staleLease }
            guard job.draft.kind == "embed", job.draft.target == "generation:\(id)" else { throw StorageV19Error.invalidValue }
        }
        let generation = try requireBuilding(db, id: id)
        let entries = try manifest(db, generationId: id)
        for entry in entries {
            try validateManifestOwner(db, generation: generation, entry: entry)
            guard entry.state != "pending" else { throw StorageV19Error.generationNotReady }
            if entry.state == "excluded" {
                guard !(entry.reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
                    throw StorageV19Error.generationNotReady
                }
            } else if entry.state == "done" {
                guard try revisionComplete(db, generation: generation, sourceId: entry.sourceId, revisionId: entry.revisionId) else {
                    throw StorageV19Error.generationNotReady
                }
            } else {
                throw StorageV19Error.generationNotReady
            }
        }
        guard try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM sources s
                LEFT JOIN index_generation_manifest m ON m.source_id=s.id AND m.generation_id=?
                WHERE s.notebook_id=? AND s.availability='present' AND s.eligible=1 AND s.current_revision IS NOT NULL
                  AND (m.source_id IS NULL OR m.revision_id IS NOT s.current_revision))
            """, arguments: [id, generation.notebookId]) == false else { throw StorageV19Error.generationNotReady }
        try db.execute(sql: "UPDATE index_generations SET state='retired' WHERE notebook_id=? AND state='active'",
                       arguments: [generation.notebookId])
        try db.execute(sql: "UPDATE index_generations SET state='active',activated_at=? WHERE id=? AND state='building'",
                       arguments: [Date(timeIntervalSince1970: TimeInterval(now)), id])
        if let fence {
            guard try RevisionJobSQL.completeJob(db, fence: fence, now: now) else { throw StorageV19Error.staleLease }
        }
    }

    static func retire(_ db: Database, id: Int64) throws {
        guard try generation(db, id: id) != nil else { throw StorageV19Error.notFound }
        try db.execute(sql: "UPDATE index_generations SET state='retired' WHERE id=? AND state<>'retired'", arguments: [id])
    }

    static func copyUnchangedVectors(_ db: Database, from: Int64, to: Int64, excludingChunkId: Int64?) throws {
        guard let original = try generation(db, id: from) else { throw StorageV19Error.notFound }
        let successor = try requireBuilding(db, id: to)
        guard original.notebookId == successor.notebookId else { throw StorageV19Error.notebookMismatch }
        guard original.identity == successor.identity else { throw StorageV19Error.invalidValue }
        try db.execute(sql: """
            INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding)
            SELECT e.chunk_id,?,e.embedding FROM chunk_embeddings e
            JOIN source_chunks c ON c.id=e.chunk_id
            JOIN index_generation_manifest old ON old.generation_id=e.generation_id
                AND old.source_id=c.source_id AND old.revision_id=c.revision_id
            JOIN index_generation_manifest new ON new.generation_id=? AND new.source_id=old.source_id
                AND new.revision_id=old.revision_id
            WHERE e.generation_id=? AND (? IS NULL OR e.chunk_id<>?)
            ON CONFLICT(chunk_id,generation_id) DO NOTHING
            """, arguments: [to, to, from, excludingChunkId, excludingChunkId])
        // Carried vectors stay dedup sources in the successor (`embedding-plan-v1` §5), as provider vectors.
        try db.execute(sql: """
            INSERT OR IGNORE INTO generation_text_hashes(generation_id,chunk_id,text_hash,copied)
            SELECT ?,d.chunk_id,d.text_hash,0 FROM generation_text_hashes d
            JOIN chunk_embeddings e ON e.chunk_id=d.chunk_id AND e.generation_id=?
            WHERE d.generation_id=?
            """, arguments: [to, to, from])
        for entry in try manifest(db, generationId: to) where entry.state != "excluded" {
            let complete = try revisionComplete(db, generation: successor, sourceId: entry.sourceId, revisionId: entry.revisionId)
            try upsertManifest(db, generationId: to, entry: ManifestEntry(sourceId: entry.sourceId,
                                revisionId: entry.revisionId, state: complete ? "done" : "pending", reason: nil))
        }
    }

    private static func requireBuilding(_ db: Database, id: Int64) throws -> IndexGeneration {
        guard let generation = try generation(db, id: id) else { throw StorageV19Error.notFound }
        guard generation.state == "building" else { throw StorageV19Error.generationNotReady }
        return generation
    }

    private static func validFormat(_ value: String) -> Bool {
        value == "legacy" || (!value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } && (Int(value) ?? 0) > 0)
    }

    private static func validateManifestOwner(_ db: Database, generation: IndexGeneration, entry: ManifestEntry) throws {
        guard let source = try Row.fetchOne(db, sql: "SELECT notebook_id,current_revision FROM sources WHERE id=?",
                                           arguments: [entry.sourceId]) else { throw StorageV19Error.notFound }
        let notebookId: Int64 = source["notebook_id"]
        let current: Int64? = source["current_revision"]
        guard notebookId == generation.notebookId else { throw StorageV19Error.notebookMismatch }
        guard current != nil else { throw StorageV19Error.generationNotReady }
        guard let owner = try Int64.fetchOne(db, sql: "SELECT source_id FROM source_revisions WHERE id=?",
                                            arguments: [entry.revisionId]) else { throw StorageV19Error.notFound }
        guard owner == entry.sourceId else { throw StorageV19Error.staleRevision }
    }

    private static func revisionComplete(_ db: Database, generation: IndexGeneration, sourceId: Int64, revisionId: Int64) throws -> Bool {
        guard try Int64.fetchOne(db, sql: "SELECT published_revision_id FROM sources WHERE id=?", arguments: [sourceId]) == revisionId else {
            return false
        }
        // Only embeddable chunks need a vector (`embedding-plan-v1` §3: capped spreadsheet rows stay full-text only).
        return try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM source_chunks c JOIN sources s ON s.id=c.source_id
                LEFT JOIN chunk_embeddings e ON e.chunk_id=c.id AND e.generation_id=?
                WHERE c.revision_id=? AND \(EmbeddingPlan.embeddableSQL())
                  AND (e.chunk_id IS NULL OR length(e.embedding)<>?))
            """, arguments: [generation.id, revisionId, generation.identity.dims * MemoryLayout<Float>.size]) == true
    }

    private static func upsertManifest(_ db: Database, generationId: Int64, entry: ManifestEntry) throws {
        try db.execute(sql: """
            INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state,reason) VALUES(?,?,?,?,?)
            ON CONFLICT(generation_id,source_id) DO UPDATE SET revision_id=excluded.revision_id,state=excluded.state,reason=excluded.reason
            """, arguments: [generationId, entry.sourceId, entry.revisionId, entry.state, entry.reason])
    }

    private static func decodeGeneration(_ row: Row) -> IndexGeneration {
        let created: Date = row["created_at"]
        let activated: Date? = row["activated_at"]
        return IndexGeneration(id: row["id"], notebookId: row["notebook_id"], identity: GenerationIdentity(
            providerId: row["provider_id"], endpointRevision: row["endpoint_revision"], model: row["model"],
            modelDigest: row["model_digest"], dims: row["dims"], normalization: row["normalization"],
            queryFormatVersion: row["query_format_version"], docFormatVersion: row["doc_format_version"], chunkerVersion: row["chunker_version"]),
            state: row["state"], createdAt: Int64(created.timeIntervalSince1970), activatedAt: activated.map { Int64($0.timeIntervalSince1970) })
    }
}

extension NotebookStore {
    public func createGeneration(notebookId: Int64, identity: GenerationIdentity, now: Int64) throws -> IndexGeneration {
        try dbQueue.write { try GenerationSQL.create($0, notebookId: notebookId, identity: identity, now: now) }
    }

    public func generation(id: Int64) throws -> IndexGeneration? {
        try dbQueue.read { try GenerationSQL.generation($0, id: id) }
    }

    public func activeGeneration(notebookId: Int64) throws -> IndexGeneration? {
        try dbQueue.read { try GenerationSQL.activeGeneration($0, notebookId: notebookId) }
    }

    public func setManifest(generationId: Int64, entries: [ManifestEntry]) throws {
        try dbQueue.write { try GenerationSQL.setManifest($0, generationId: generationId, entries: entries) }
    }

    public func manifest(generationId: Int64) throws -> [ManifestEntry] {
        try dbQueue.read { try GenerationSQL.manifest($0, generationId: generationId) }
    }

    public func reconcileManifest(generationId: Int64) throws {
        try dbQueue.write { try GenerationSQL.reconcile($0, generationId: generationId) }
    }

    public func storeGenerationEmbedding(generationId: Int64, chunkId: Int64, vector: EmbeddingVector) throws {
        try dbQueue.write { try GenerationSQL.storeEmbedding($0, generationId: generationId, chunkId: chunkId, vector: vector) }
    }

    public func activateGeneration(id: Int64, now: Int64) throws {
        try dbQueue.write { try GenerationSQL.activate($0, id: id, fence: nil, now: now) }
    }

    public func retireGeneration(id: Int64) throws {
        try dbQueue.write { try GenerationSQL.retire($0, id: id) }
    }

    /// MainActor serializes registry access and SQLite snapshot creation together across stores.
    /// There is no suspension between checking the registry, reading SQLite and publishing the pin.
    public func pinQuery(notebookId: Int64, modelKey: String) throws -> QueryPin {
        try withQueryPin(notebookId: notebookId, modelKey: modelKey) { _, _ in () }.pin
    }

    /// The registry lock is WP3's registry gate (formerly the MainActor): the pin's
    /// snapshot read and its registration are atomic against `garbageCollect`'s
    /// retained-ID check and delete. The callback shares the pin's SQL snapshot.
    internal func withQueryPin<T>(notebookId: Int64, modelKey: String,
        read: (Database, QueryPin) throws -> T) throws -> (pin: QueryPin, value: T) {
        try QueryPinRegistry.lock.withLock { try withQueryPinLocked(notebookId: notebookId, modelKey: modelKey, read: read) }
    }

    private func withQueryPinLocked<T>(notebookId: Int64, modelKey: String,
        read: (Database, QueryPin) throws -> T) throws -> (pin: QueryPin, value: T) {
        let key = generationDatabaseIdentity
        let result = try dbQueue.read { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM notebooks WHERE id=?", arguments: [notebookId]) != nil else { throw StorageV19Error.notFound }
            let active = try GenerationSQL.activeGeneration(db, notebookId: notebookId)
            var matching = active.flatMap { $0.identity.modelKey.utf8.elementsEqual(modelKey.utf8) ? $0 : nil }
            let lexical = try Row.fetchAll(db, sql: """
                SELECT id,published_revision_id FROM sources
                WHERE notebook_id=? AND availability='present' AND eligible=1 AND published_revision_id IS NOT NULL
                """, arguments: [notebookId])
            let lexicalRevisions = Dictionary(uniqueKeysWithValues: lexical.map { ($0["id"] as Int64, $0["published_revision_id"] as Int64) })
            var vectorRevisions: [Int64: Int64] = [:]
            if let matching {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT m.source_id,m.revision_id FROM index_generation_manifest m JOIN sources s ON s.id=m.source_id
                    WHERE m.generation_id=? AND m.state='done' AND s.notebook_id=? AND s.availability='present' AND s.eligible=1
                    """, arguments: [matching.id, notebookId])
                vectorRevisions = Dictionary(uniqueKeysWithValues: rows.map { ($0["source_id"] as Int64, $0["revision_id"] as Int64) })
            } else if active == nil, let building = try GenerationSQL.partialCandidate(db, notebookId: notebookId, modelKey: modelKey) {
                // retrieval-partial-index-v1 §3: only completed sources at their current published revision.
                let rows = try Row.fetchAll(db, sql: """
                    SELECT m.source_id,m.revision_id FROM index_generation_manifest m JOIN sources s ON s.id=m.source_id
                    WHERE m.generation_id=? AND m.state='done' AND s.notebook_id=? AND s.availability='present' AND s.eligible=1
                      AND s.published_revision_id=m.revision_id
                    """, arguments: [building.id, notebookId])
                if !rows.isEmpty {
                    matching = building
                    vectorRevisions = Dictionary(uniqueKeysWithValues: rows.map { ($0["source_id"] as Int64, $0["revision_id"] as Int64) })
                }
            }
            let pin = QueryPin(token: UUID().uuidString, notebookId: notebookId, generationId: matching?.id,
                modelKey: matching?.identity.modelKey, dims: matching?.identity.dims,
                lexicalRevisions: lexicalRevisions, vectorRevisions: vectorRevisions)
            return (pin: pin, value: try read(db, pin))
        }
        let pin = result.pin
        if QueryPinRegistry.databases[key] == nil {
            QueryPinRegistry.databases[key] = QueryPinRegistry.DatabasePins(queue: dbQueue, pins: [:])
        }
        QueryPinRegistry.databases[key]!.pins[pin.token] = pin
        return result
    }

    public func releaseQuery(_ pin: QueryPin) {
        let key = generationDatabaseIdentity
        QueryPinRegistry.lock.withLock {
            QueryPinRegistry.databases[key]?.pins.removeValue(forKey: pin.token)
            if QueryPinRegistry.databases[key]?.pins.isEmpty == true { QueryPinRegistry.databases.removeValue(forKey: key) }
        }
    }

    /// Retrieval only: a registered pin may read a retired generation, but never a source whose
    /// vectors are incomplete (a building generation is pinned only through its done sources).
    /// Current eligibility still revokes access even though the pin retains revision identity.
    public func pinnedEmbeddings(_ pin: QueryPin) throws -> [StoredEmbedding] {
        let key = generationDatabaseIdentity
        guard let registered = QueryPinRegistry.lock.withLock({ QueryPinRegistry.databases[key]?.pins[pin.token] }), registered == pin,
              let generationId = registered.generationId, let dims = registered.dims else { return [] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.chunk_id,c.source_id,c.revision_id,e.embedding
                FROM chunk_embeddings e JOIN source_chunks c ON c.id=e.chunk_id
                JOIN sources s ON s.id=c.source_id
                JOIN index_generation_manifest m ON m.generation_id=e.generation_id AND m.source_id=c.source_id AND m.revision_id=c.revision_id
                WHERE e.generation_id=? AND m.state='done' AND s.notebook_id=? AND s.availability='present' AND s.eligible=1
                ORDER BY e.chunk_id
                """, arguments: [generationId, registered.notebookId])
            return try rows.compactMap { row in
                let source: Int64 = row["source_id"], revision: Int64 = row["revision_id"]
                let bytes: Data = row["embedding"]
                guard registered.vectorRevisions[source] == revision, bytes.count / 4 == dims, bytes.count % 4 == 0 else { return nil }
                return StoredEmbedding(chunkId: row["chunk_id"], sourceId: source, vector: try EmbeddingVector(data: bytes))
            }
        }
    }

    public func garbageCollect(notebookId: Int64) throws -> GarbageCollectionResult {
        // The registry lock is the coordination gate. It remains held through the synchronous
        // transaction, so another store cannot publish a pin across the retained-ID safety check.
        try QueryPinRegistry.lock.withLock { try garbageCollectLocked(notebookId: notebookId) }
    }

    private func garbageCollectLocked(notebookId: Int64) throws -> GarbageCollectionResult {
        let pins = Array(QueryPinRegistry.databases[generationDatabaseIdentity]?.pins.values ?? Dictionary<String, QueryPin>().values)
            .filter { $0.notebookId == notebookId }
        let retainedGenerations = Set(pins.compactMap(\.generationId)).sorted()
        let retainedRevisions = Set(pins.flatMap { Array($0.lexicalRevisions.values) + Array($0.vectorRevisions.values) }).sorted()
        return try dbQueue.write { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM notebooks WHERE id=?", arguments: [notebookId]) != nil else { throw StorageV19Error.notFound }
            func counts() throws -> GarbageCollectionResult {
                let generations = try Int.fetchOne(db, sql: "SELECT count(*) FROM index_generations WHERE notebook_id=?", arguments: [notebookId])!
                let revisions = try Int.fetchOne(db, sql: "SELECT count(*) FROM source_revisions r JOIN sources s ON s.id=r.source_id WHERE s.notebook_id=?", arguments: [notebookId])!
                let chunks = try Int.fetchOne(db, sql: "SELECT count(*) FROM source_chunks c JOIN sources s ON s.id=c.source_id WHERE s.notebook_id=?", arguments: [notebookId])!
                let vectors = try Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_embeddings e JOIN index_generations g ON g.id=e.generation_id WHERE g.notebook_id=?", arguments: [notebookId])!
                return GarbageCollectionResult(generations: generations, revisions: revisions, chunks: chunks, vectors: vectors)
            }
            let before = try counts()
            let generationsPredicate = retainedGenerations.isEmpty ? "1" : "id NOT IN (" + retainedGenerations.map { _ in "?" }.joined(separator: ",") + ")"
            var args: StatementArguments = [notebookId]
            args += StatementArguments(retainedGenerations)
            try db.execute(sql: "DELETE FROM index_generations WHERE notebook_id=? AND state IN ('retired','failed') AND \(generationsPredicate)", arguments: args)
            let revisionPredicate = retainedRevisions.isEmpty ? "1" : "r.id NOT IN (" + retainedRevisions.map { _ in "?" }.joined(separator: ",") + ")"
            args = [notebookId]
            args += StatementArguments(retainedRevisions)
            try db.execute(sql: """
                DELETE FROM source_revisions WHERE id IN (
                    SELECT r.id FROM source_revisions r JOIN sources s ON s.id=r.source_id
                    WHERE s.notebook_id=? AND s.current_revision IS NOT r.id AND s.published_revision_id IS NOT r.id
                      AND NOT EXISTS(SELECT 1 FROM index_generation_manifest m JOIN index_generations g ON g.id=m.generation_id
                                     WHERE m.revision_id=r.id AND g.state IN ('active','building'))
                      AND NOT EXISTS(SELECT 1 FROM ingest_jobs j WHERE j.target_revision=r.id
                                     AND (j.state IN ('queued','running','paused') OR (j.state='failed' AND j.next_retry_at IS NOT NULL)))
                      AND \(revisionPredicate)
                )
                """, arguments: args)
            let after = try counts()
            return GarbageCollectionResult(generations: before.generations - after.generations,
                revisions: before.revisions - after.revisions, chunks: before.chunks - after.chunks, vectors: before.vectors - after.vectors)
        }
    }

    var generationDatabaseIdentity: String { Self.generationDatabaseIdentity(dbQueue) }

    internal nonisolated static func generationDatabaseIdentity(_ dbQueue: any DatabaseWriter) -> String {
        if dbQueue.path == ":memory:" || dbQueue.path.isEmpty { return "memory:\(ObjectIdentifier(dbQueue as AnyObject))" }
        return "file:" + URL(fileURLWithPath: dbQueue.path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Process-wide query pins. `lock` guards `databases` and is the coordination
/// gate between pin creation and garbage collection (any thread).
private enum QueryPinRegistry {
    struct DatabasePins {
        // Retaining the queue also prevents ObjectIdentifier reuse while a memory database has pins.
        let queue: any DatabaseWriter
        var pins: [String: QueryPin]
    }
    static let lock = NSLock()
    nonisolated(unsafe) static var databases: [String: DatabasePins] = [:]
}

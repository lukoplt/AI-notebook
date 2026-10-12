import Foundation
import GRDB

public struct StoredEmbedding: Equatable, Sendable {
    public let chunkId: Int64
    public let sourceId: Int64
    public let vector: EmbeddingVector
}

struct CapturedEmbeddingChunk: Sendable {
    let chunk: SourceChunk
    let notebookId: Int64
    let generationId: Int64?
}

struct EmbeddingBatchResult: Sendable {
    let written: Int
    let generationIds: [Int64: Int64]
}

extension NotebookStore {
    public func storeEmbedding(chunkId: Int64, model: String, vector: EmbeddingVector) throws {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT c.source_id,c.revision_id,s.notebook_id,s.published_revision_id,s.availability,s.eligible
                FROM source_chunks c JOIN sources s ON s.id=c.source_id WHERE c.id=?
                """, arguments: [chunkId]) else { throw StorageV19Error.notFound }
            let notebookId: Int64 = row["notebook_id"]
            let revision: Int64? = row["revision_id"], published: Int64? = row["published_revision_id"]
            let availability: String = row["availability"], eligible: Bool = row["eligible"]
            guard revision != nil, revision == published, availability == "present", eligible else { throw StorageV19Error.staleRevision }
            let now = Int64(Date().timeIntervalSince1970)
            let generation = try EmbeddingWorkSQL.prepare(db, notebookId: notebookId, modelKey: model,
                dims: vector.dim, now: now, copyExisting: true, excludingChunkId: chunkId)
            try GenerationSQL.storeEmbedding(db, generationId: generation.id, chunkId: chunkId, vector: vector)
            _ = try EmbeddingWorkSQL.complete(db, id: generation.id, selectedModelKey: model, now: now)
        }
    }

    /// Work inspection: newest building work takes precedence and may contain partial revisions.
    /// Retrieval must use pinnedEmbeddings, which requires completed manifest membership.
    public func embeddings(notebookId: Int64, model: String) throws -> [StoredEmbedding] {
        try dbQueue.read { db in
            guard let generation = try EmbeddingWorkSQL.work(db, notebookId: notebookId, modelKey: model) else { return [] }
            return try Row.fetchAll(db, sql: """
                SELECT e.chunk_id,c.source_id,e.embedding FROM chunk_embeddings e
                JOIN source_chunks c ON c.id=e.chunk_id JOIN sources s ON s.id=c.source_id
                JOIN index_generation_manifest m ON m.generation_id=e.generation_id AND m.source_id=c.source_id AND m.revision_id=c.revision_id
                WHERE e.generation_id=? AND s.notebook_id=? AND s.availability='present' AND s.eligible=1 AND m.state<>'excluded'
                ORDER BY e.chunk_id
                """, arguments: [generation.id, notebookId]).map {
                    StoredEmbedding(chunkId: $0["chunk_id"], sourceId: $0["source_id"], vector: try EmbeddingVector(data: $0["embedding"]))
                }
        }
    }

    public func unembeddedChunks(model: String, limit: Int) throws -> [SourceChunk] {
        guard limit > 0 else { return [] }
        return try dbQueue.read { db in
            try SourceChunk.fetchAll(db, sql: EmbeddingWorkSQL.pendingSQL(projection: "c.*") + " ORDER BY c.id LIMIT ?", arguments: [model, limit])
        }
    }

    public func unembeddedCount(model: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: EmbeddingWorkSQL.pendingSQL(projection: "count(*)"), arguments: [model]) ?? 0
        }
    }

    /// Starts empty reindex work; active and pinned vectors survive until normal GC.
    public func deleteAllEmbeddings(model: String) throws {
        try dbQueue.write { db in
            let notebooks = try Int64.fetchAll(db, sql: "SELECT DISTINCT notebook_id FROM index_generations WHERE \(EmbeddingWorkSQL.keySQL)=? ORDER BY notebook_id", arguments: [model])
            for notebookId in notebooks {
                guard let previous = try EmbeddingWorkSQL.work(db, notebookId: notebookId, modelKey: model) ?? EmbeddingWorkSQL.latest(db, notebookId: notebookId, modelKey: model) else { continue }
                try EmbeddingWorkSQL.retireWork(db, notebookId: notebookId, modelKey: model)
                _ = try EmbeddingWorkSQL.prepare(db, notebookId: notebookId, modelKey: model, dims: previous.identity.dims,
                    now: Int64(Date().timeIntervalSince1970), copyExisting: false, excludingChunkId: nil)
            }
        }
    }

    public func prepareEmbeddingGeneration(notebookId: Int64, modelKey: String, dims: Int, now: Int64, copyExisting: Bool) throws -> IndexGeneration {
        try dbQueue.write { try EmbeddingWorkSQL.prepare($0, notebookId: notebookId, modelKey: modelKey, dims: dims, now: now, copyExisting: copyExisting, excludingChunkId: nil) }
    }

    public func completeEmbeddingGeneration(id: Int64, selectedModelKey: String, now: Int64) throws -> Bool {
        try dbQueue.write { try EmbeddingWorkSQL.complete($0, id: id, selectedModelKey: selectedModelKey, now: now) }
    }

    func completeEmbeddingWork(modelKey: String, selectedModelKey: String, now: Int64) throws {
        try dbQueue.write { db in
            // Empty publications have no pending chunk to start a successor. Advance their
            // manifest here so clearing a note cannot retain its former vector evidence forever.
            let changed = try Row.fetchAll(db, sql: """
                SELECT id,notebook_id,dims FROM index_generations g
                WHERE \(EmbeddingWorkSQL.keySQL)=? AND state='active'
                  AND EXISTS(SELECT 1 FROM sources s
                      WHERE s.notebook_id=g.notebook_id AND s.availability='present' AND s.eligible=1
                        AND s.published_revision_id IS NOT NULL
                        AND NOT EXISTS(SELECT 1 FROM index_generation_manifest m
                            WHERE m.generation_id=g.id AND m.source_id=s.id AND m.revision_id=s.published_revision_id))
                """, arguments: [modelKey])
            for row in changed {
                let notebookId: Int64 = row["notebook_id"]
                if try EmbeddingWorkSQL.work(db, notebookId: notebookId, modelKey: modelKey)?.state != "building" {
                    _ = try EmbeddingWorkSQL.prepare(db, notebookId: notebookId, modelKey: modelKey,
                        dims: row["dims"], now: now, copyExisting: true, excludingChunkId: nil)
                }
            }
            let ids = try Int64.fetchAll(db, sql: """
                SELECT max(id) FROM index_generations WHERE \(EmbeddingWorkSQL.keySQL)=? AND state='building' GROUP BY notebook_id
                """, arguments: [modelKey])
            for id in ids {
                try EmbeddingWorkSQL.reconcilePublished(db, generationId: id)
                _ = try EmbeddingWorkSQL.complete(db, id: id, selectedModelKey: selectedModelKey, now: now)
            }
        }
    }

    func captureEmbeddingBatch(model: String, limit: Int, generations: [Int64: Int64]) throws -> [CapturedEmbeddingChunk] {
        guard limit > 0 else { return [] }
        return try dbQueue.read { db in
            let chunks = try SourceChunk.fetchAll(db, sql: EmbeddingWorkSQL.pendingSQL(projection: "c.*") + " ORDER BY c.id LIMIT ?", arguments: [model, limit])
            return try chunks.map { chunk in
                let notebook = try Int64.fetchOne(db, sql: "SELECT notebook_id FROM sources WHERE id=?", arguments: [chunk.sourceId])!
                let work = try EmbeddingWorkSQL.work(db, notebookId: notebook, modelKey: model)
                return CapturedEmbeddingChunk(chunk: chunk, notebookId: notebook,
                    generationId: generations[notebook] ?? (work?.state == "building" ? work?.id : nil))
            }
        }
    }

    func writeEmbeddingBatch(_ batch: [CapturedEmbeddingChunk], vectors: [[Float]], modelKey: String, selectedModelKey: String, now: Int64) throws -> EmbeddingBatchResult {
        guard let dims = vectors.first?.count, dims > 0, vectors.count == batch.count,
              vectors.allSatisfy({ $0.count == dims }) else { throw StorageV19Error.invalidVector }
        return try dbQueue.write { db in
            var generations: [Int64: IndexGeneration] = [:]
            for item in batch where generations[item.notebookId] == nil {
                if let captured = item.generationId {
                    guard let generation = try GenerationSQL.generation(db, id: captured), generation.state == "building",
                          generation.identity.modelKey.utf8.elementsEqual(modelKey.utf8) else { continue }
                    guard generation.identity.dims == dims else { throw StorageV19Error.invalidVector }
                    try EmbeddingWorkSQL.reconcilePublished(db, generationId: captured)
                    generations[item.notebookId] = generation
                } else {
                    generations[item.notebookId] = try EmbeddingWorkSQL.prepare(db, notebookId: item.notebookId,
                        modelKey: modelKey, dims: dims, now: now, copyExisting: true, excludingChunkId: nil)
                }
            }
            var written = 0
            for (item, values) in zip(batch, vectors) {
                guard let generation = generations[item.notebookId], let chunkId = item.chunk.id, let revisionId = item.chunk.revisionId,
                      try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM source_chunks c JOIN sources s ON s.id=c.source_id
                            JOIN index_generation_manifest m ON m.generation_id=? AND m.source_id=s.id AND m.revision_id=c.revision_id
                            WHERE c.id=? AND c.revision_id=? AND s.published_revision_id=c.revision_id AND s.availability='present' AND s.eligible=1)
                        """, arguments: [generation.id, chunkId, revisionId]) == true else { continue }
                try GenerationSQL.storeEmbedding(db, generationId: generation.id, chunkId: chunkId, vector: EmbeddingVector(values: values))
                written += 1
            }
            for generation in generations.values {
                _ = try EmbeddingWorkSQL.complete(db, id: generation.id, selectedModelKey: selectedModelKey, now: now)
            }
            return EmbeddingBatchResult(written: written, generationIds: generations.mapValues(\.id))
        }
    }
}

enum EmbeddingWorkSQL {
    static let keySQL = "CASE WHEN provider_id='legacy' THEN model ELSE provider_id||':'||model END"

    static func work(_ db: Database, notebookId: Int64, modelKey: String) throws -> IndexGeneration? {
        guard let id = try Int64.fetchOne(db, sql: """
            SELECT id FROM index_generations WHERE notebook_id=? AND \(keySQL)=? AND state IN ('building','active')
            ORDER BY (state='building') DESC,id DESC LIMIT 1
            """, arguments: [notebookId, modelKey]) else { return nil }
        return try GenerationSQL.generation(db, id: id)
    }

    static func latest(_ db: Database, notebookId: Int64, modelKey: String) throws -> IndexGeneration? {
        guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM index_generations WHERE notebook_id=? AND \(keySQL)=? ORDER BY id DESC LIMIT 1", arguments: [notebookId, modelKey]) else { return nil }
        return try GenerationSQL.generation(db, id: id)
    }

    static func retireWork(_ db: Database, notebookId: Int64, modelKey: String) throws {
        try db.execute(sql: "UPDATE index_generations SET state='retired' WHERE notebook_id=? AND \(keySQL)=? AND state='building'", arguments: [notebookId, modelKey])
    }

    static func prepare(_ db: Database, notebookId: Int64, modelKey: String, dims: Int, now: Int64, copyExisting: Bool, excludingChunkId: Int64?) throws -> IndexGeneration {
        let identity = GenerationIdentity(providerId: "legacy", endpointRevision: "legacy", model: modelKey,
            modelDigest: nil, dims: dims, normalization: "legacy", queryFormatVersion: "legacy", docFormatVersion: "legacy", chunkerVersion: "legacy")
        if let existing = try work(db, notebookId: notebookId, modelKey: modelKey), existing.state == "building", existing.identity == identity {
            try reconcilePublished(db, generationId: existing.id)
            return existing
        }
        try retireWork(db, notebookId: notebookId, modelKey: modelKey)
        let generation = try GenerationSQL.create(db, notebookId: notebookId, identity: identity, now: now)
        try reconcilePublished(db, generationId: generation.id)
        if copyExisting, let active = try GenerationSQL.activeGeneration(db, notebookId: notebookId), active.identity == identity {
            try GenerationSQL.copyUnchangedVectors(db, from: active.id, to: generation.id, excludingChunkId: excludingChunkId)
        }
        return generation
    }

    /// Compatibility embedding consumes published text while a newer extraction may still be pending.
    /// Activation independently checks current revisions, so this work cannot replace active evidence early.
    static func reconcilePublished(_ db: Database, generationId: Int64) throws {
        guard let generation = try GenerationSQL.generation(db, id: generationId) else { throw StorageV19Error.notFound }
        let prior = Dictionary(uniqueKeysWithValues: try GenerationSQL.manifest(db, generationId: generationId).map { ($0.sourceId, $0) })
        try GenerationSQL.reconcile(db, generationId: generationId)
        let awaitingPublication = try Row.fetchAll(db, sql: """
            SELECT id,published_revision_id FROM sources
            WHERE notebook_id=? AND availability='present' AND eligible=1
              AND published_revision_id IS NOT NULL AND current_revision IS NOT NULL
              AND published_revision_id IS NOT current_revision
            """, arguments: [generation.notebookId])
        let entries: [ManifestEntry] = awaitingPublication.map { row in
            let sourceId: Int64 = row["id"], published: Int64 = row["published_revision_id"]
            if let previous = prior[sourceId], previous.revisionId == published { return previous }
            return ManifestEntry(sourceId: sourceId, revisionId: published, state: "pending", reason: nil)
        }
        try GenerationSQL.setManifest(db, generationId: generationId, entries: entries)
    }

    static func complete(_ db: Database, id: Int64, selectedModelKey: String, now: Int64) throws -> Bool {
        guard let generation = try GenerationSQL.generation(db, id: id) else { throw StorageV19Error.notFound }
        guard generation.state == "building" else {
            return generation.state == "active" && generation.identity.modelKey.utf8.elementsEqual(selectedModelKey.utf8)
        }
        let completeSources = try Row.fetchAll(db, sql: """
            SELECT m.source_id,m.revision_id FROM index_generation_manifest m JOIN sources s ON s.id=m.source_id
            WHERE m.generation_id=? AND m.state='pending' AND s.published_revision_id=m.revision_id
              AND NOT EXISTS(SELECT 1 FROM source_chunks c LEFT JOIN chunk_embeddings e ON e.chunk_id=c.id AND e.generation_id=m.generation_id
                             WHERE c.revision_id=m.revision_id AND (e.chunk_id IS NULL OR length(e.embedding)<>?))
            """, arguments: [id, generation.identity.dims * MemoryLayout<Float>.size])
        try GenerationSQL.setManifest(db, generationId: id, entries: completeSources.map {
            ManifestEntry(sourceId: $0["source_id"], revisionId: $0["revision_id"], state: "done", reason: nil)
        })
        guard generation.identity.modelKey.utf8.elementsEqual(selectedModelKey.utf8) else { return false }
        do {
            try GenerationSQL.activate(db, id: id, fence: nil, now: now)
            return true
        } catch StorageV19Error.generationNotReady {
            return false
        }
    }

    static func pendingSQL(projection: String) -> String {
        """
        SELECT \(projection) FROM source_chunks c JOIN sources s ON s.id=c.source_id
        LEFT JOIN index_generations work ON work.id=(
            SELECT id FROM index_generations WHERE notebook_id=s.notebook_id AND \(keySQL)=? AND state IN ('building','active')
            ORDER BY (state='building') DESC,id DESC LIMIT 1)
        WHERE s.availability='present' AND s.eligible=1 AND c.revision_id=s.published_revision_id
          AND NOT EXISTS(SELECT 1 FROM chunk_embeddings e
              JOIN index_generation_manifest m ON m.generation_id=e.generation_id AND m.source_id=c.source_id AND m.revision_id=c.revision_id
              WHERE e.chunk_id=c.id AND e.generation_id=work.id AND length(e.embedding)=work.dims*4)
        """
    }
}

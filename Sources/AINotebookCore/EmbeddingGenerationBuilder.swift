import Foundation

public struct EmbeddingGenerationError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public init(code: String) { self.code = code }
    public var description: String { "EmbeddingGenerationError(\(code))" }
}

/// Stages a complete embedding generation for one notebook through a document-purpose
/// session. Staging never activates and never deletes an existing vector; a failure
/// retires only a generation this call created (benchmark-v1 §8 `stage`).
@MainActor public enum EmbeddingGenerationBuilder {
    public static func stage(store: NotebookStore, notebookId: Int64, identity: GenerationIdentity,
                             session: ProviderEmbeddingSession, existingGeneration: IndexGeneration? = nil,
                             reuseActive: Bool = false,
                             now: @escaping @Sendable () -> Int64) async throws -> IndexGeneration {
        try await stage(store: store, notebookId: notebookId, identity: identity, sessionIdentity: session.identity,
                        now: now, embedDocuments: { try await session.embedDocuments(inputs: $0) },
                        existingGeneration: existingGeneration, reuseActive: reuseActive)
    }

    /// Internal injection seam. `sessionIdentity` is the captured identity of the
    /// embedding session (nil for legacy/raw sessions).
    static func stage(store: NotebookStore, notebookId: Int64, identity: GenerationIdentity,
                      sessionIdentity: GenerationIdentity? = nil,
                      now: @escaping @Sendable () -> Int64,
                      embedDocuments: ([String]) async throws -> [[Float]],
                      existingGeneration: IndexGeneration? = nil,
                      reuseActive: Bool = false) async throws -> IndexGeneration {
        // The whole captured identity must equal the requested one; storage key or
        // endpoint alone is insufficient. A raw session can never stage a named profile.
        if let sessionIdentity {
            guard sessionIdentity == identity else { throw EmbeddingGenerationError(code: "profileIdentityMismatch") }
        } else if OllamaBenchmarkClient.profileId(fromFormatVersion: identity.queryFormatVersion) != nil
                    || OllamaBenchmarkClient.profileId(fromFormatVersion: identity.docFormatVersion) != nil {
            throw EmbeddingGenerationError(code: "profileIdentityMismatch")
        }
        let eligible = try store.sourcesIncludingShadow(notebookId: notebookId)
            .filter { $0.availability == "present" && $0.eligible && $0.currentRevision != nil }
        for source in eligible where source.currentRevision != source.publishedRevisionId {
            throw EmbeddingGenerationError(code: "refreshPending")
        }
        if let supplied = existingGeneration {
            guard let stored = try store.generation(id: supplied.id), stored.notebookId == notebookId,
                  stored.identity == identity, stored.state == "building" else {
                throw EmbeddingGenerationError(code: "invalidGeneration")
            }
        }
        try Task.checkCancellation()
        let generation = try existingGeneration ?? store.createGeneration(notebookId: notebookId, identity: identity,
                                                                         now: now())
        do {
            if reuseActive, let active = try store.activeGeneration(notebookId: notebookId), active.identity == identity {
                try copyUnchangedVectors(store, from: active.id, to: generation.id)
            }
            let manifest = try store.manifest(generationId: generation.id).sorted { $0.sourceId < $1.sourceId }
            for entry in manifest where entry.state == "pending" {
                try Task.checkCancellation()
                // One source's chunk snapshot at a time keeps memory bounded.
                let chunks = try store.chunks(sourceId: entry.sourceId)
                guard chunks.allSatisfy({ $0.revisionId == entry.revisionId }) else {
                    throw EmbeddingGenerationError(code: "staleRevision")
                }
                for chunk in chunks {
                    try Task.checkCancellation()
                    // Canonical chunk text: the profile format names no enrichment policy.
                    let vectors = try await embedDocuments([chunk.text])
                    try Task.checkCancellation()
                    try requireCurrent(store, entry)
                    guard vectors.count == 1, let chunkId = chunk.id, vectors[0].count == identity.dims,
                          vectors[0].allSatisfy(\.isFinite) else {
                        throw EmbeddingGenerationError(code: "invalidEmbedding")
                    }
                    try store.storeGenerationEmbedding(generationId: generation.id, chunkId: chunkId,
                                                       vector: EmbeddingVector(values: vectors[0]))
                }
                try Task.checkCancellation()
                try requireCurrent(store, entry)
                try store.setManifest(generationId: generation.id, entries: [
                    ManifestEntry(sourceId: entry.sourceId, revisionId: entry.revisionId, state: "done", reason: nil)
                ])
            }
            return generation
        } catch {
            // Caller-owned generations belong to a fenced worker; only it may retire them.
            if existingGeneration == nil { try? store.retireGeneration(id: generation.id) }
            throw error
        }
    }

    /// Publication of a staged named-profile generation: revalidates the captured model
    /// digest on the same endpoint (only `/api/tags`) and activates only on a match; a
    /// changed model leaves the active generation untouched (§3 `publish`).
    public static func publish(store: NotebookStore, generation: IndexGeneration, client: OllamaBenchmarkClient,
                               now: @escaping @Sendable () -> Int64) async throws {
        let identity = generation.identity
        if let profileId = OllamaBenchmarkClient.profileId(fromFormatVersion: identity.queryFormatVersion) {
            let profile = try EmbeddingProfiles.require(profileId)
            _ = try await OllamaBenchmarkClient.revalidate(identity, profile: profile, client: client)
        }
        try Task.checkCancellation()
        guard let stored = try store.generation(id: generation.id), stored.identity == identity,
              stored.state == "building" else { throw EmbeddingGenerationError(code: "invalidGeneration") }
        try store.activateGeneration(id: generation.id, now: now())
    }

    private static func copyUnchangedVectors(_ store: NotebookStore, from: Int64, to: Int64) throws {
        try store.dbQueue.write { db in
            try GenerationSQL.copyUnchangedVectors(db, from: from, to: to, excludingChunkId: nil)
        }
    }

    private static func requireCurrent(_ store: NotebookStore, _ entry: ManifestEntry) throws {
        guard let current = try store.source(id: entry.sourceId), current.currentRevision == entry.revisionId,
              current.publishedRevisionId == entry.revisionId, current.availability == "present", current.eligible
        else { throw EmbeddingGenerationError(code: "staleRevision") }
    }
}

import Foundation
import GRDB

extension NotebookStore {
    /// All notebook IDs, ascending.
    public func embeddingRebuildNotebookIds() throws -> [Int64] {
        try dbQueue.read { try Int64.fetchAll($0, sql: "SELECT id FROM notebooks ORDER BY id") }
    }

    /// Activates one staged generation per notebook in a single transaction: the target set
    /// must equal the current notebook set, and every target must be a building generation
    /// of its notebook with the requested profile identity. Any failure rolls back all.
    public func activateEmbeddingRebuild(_ targets: [EmbeddingRebuildTarget], requested: EmbeddingModelChoice,
                                         now: Int64) throws {
        guard let profileId = requested.profileId else { throw EmbeddingRecommendationError(code: "profileRequired") }
        let profile = try EmbeddingProfiles.require(profileId)
        try dbQueue.write { db in
            let notebooks = try Int64.fetchAll(db, sql: "SELECT id FROM notebooks ORDER BY id")
            let ordered = targets.sorted { $0.notebookId < $1.notebookId }
            guard Set(targets.map(\.notebookId)).count == targets.count, ordered.map(\.notebookId) == notebooks else {
                throw EmbeddingRecommendationError(code: "rebuildScopeChanged")
            }
            for target in ordered {
                guard let generation = try GenerationSQL.generation(db, id: target.generationId),
                      generation.notebookId == target.notebookId, generation.state == "building" else {
                    throw EmbeddingRecommendationError(code: "invalidGeneration")
                }
                let i = generation.identity
                guard i.providerId == requested.providerId, i.normalization == "l2",
                      (try? profile.validateIdentity(model: i.model, dims: i.dims, queryFormatVersion: i.queryFormatVersion,
                                                     docFormatVersion: i.docFormatVersion)) != nil else {
                    throw EmbeddingRecommendationError(code: "profileIdentityMismatch")
                }
                try GenerationSQL.activate(db, id: target.generationId, fence: nil, now: now)
            }
        }
    }
}

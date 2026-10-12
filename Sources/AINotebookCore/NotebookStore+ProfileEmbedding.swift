import Foundation
import GRDB

/// Result of one fenced profile publication attempt (benchmark-v1 §8 `drain`).
enum ProfileActivationOutcome: Equatable, Sendable {
    case activated
    case leaseLost
    case selectionChanged
    case activeChanged
    case invalidGeneration
}

extension NotebookStore {
    /// Notebooks (ascending) whose ordinary embedding work the selected named profile still
    /// owes: an eligible present source has a published revision absent from (or not done
    /// in) a matching active generation, or no active generation matches the selection.
    /// Empty notebooks and legacy selections are never work. A source whose current
    /// revision is ahead of its published one is not work by itself.
    public func profileEmbeddingWork(_ selection: EmbeddingModelChoice) throws -> [Int64] {
        guard let profileId = selection.profileId else { return [] }
        let profile = try EmbeddingProfiles.require(profileId)
        return try dbQueue.read { db in
            let notebooks = try Int64.fetchAll(db, sql: """
                SELECT DISTINCT notebook_id FROM sources
                WHERE availability='present' AND eligible=1 AND published_revision_id IS NOT NULL
                ORDER BY notebook_id
                """)
            return try notebooks.filter { notebookId in
                guard let active = try GenerationSQL.activeGeneration(db, notebookId: notebookId),
                      Self.profileIdentity(active.identity, matches: selection, profile: profile) else { return true }
                return try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM sources s
                        WHERE s.notebook_id=? AND s.availability='present' AND s.eligible=1
                          AND s.published_revision_id IS NOT NULL
                          AND NOT EXISTS(SELECT 1 FROM index_generation_manifest m
                              WHERE m.generation_id=? AND m.source_id=s.id
                                AND m.revision_id=s.published_revision_id AND m.state='done'))
                    """, arguments: [notebookId, active.id]) == true
            }
        }
    }

    /// One transaction: creates the building generation, enqueues its embed job and claims
    /// exactly that job, so a lease exists before the first embedding request and no
    /// scheduler can claim in between. Options carry the nonsecret WP6 selection.
    public func beginProfileEmbedding(notebookId: Int64, identity: GenerationIdentity,
                                      now: Int64, leaseToken: String) throws -> (generation: IndexGeneration, fence: JobFence) {
        let started = try dbQueue.write { db -> (IndexGeneration, JobFence) in
            let generation = try GenerationSQL.create(db, notebookId: notebookId, identity: identity, now: now)
            let options = try EmbeddingSelection(identity: identity).optionsJSON(copyExisting: true)
            let jobId = try RevisionJobSQL.enqueueJob(db, draft: IngestJobDraft(kind: "embed", target: "generation:\(generation.id)",
                                                                                targetRevision: nil, optionsJSON: options), now: now)
            guard let job = try RevisionJobSQL.claimJob(db, now: now, leaseToken: leaseToken, id: jobId), job.id == jobId else {
                throw StorageV19Error.staleLease
            }
            return (generation, JobFence(jobId: jobId, leaseToken: leaseToken))
        }
        notifyFolderIngestionChanged(notebookId: notebookId)
        return started
    }

    /// One transaction: requires the live fence, the still-selected profile bundle and an
    /// unchanged active generation, then activates through the fenced WP3 kernel, which
    /// completes the job. A stale selection or a newer active generation cancels the owned
    /// attempt and returns false; staged data stays for orderly retirement.
    public func activateProfileEmbedding(generationId: Int64, previousActiveId: Int64?, fence: JobFence,
                                         selected: EmbeddingModelChoice, now: Int64) throws -> Bool {
        try profileActivation(generationId: generationId, previousActiveId: previousActiveId, fence: fence,
                              selected: selected, now: now) == .activated
    }

    func profileActivation(generationId: Int64, previousActiveId: Int64?, fence: JobFence,
                           selected: EmbeddingModelChoice, now: Int64) throws -> ProfileActivationOutcome {
        let (outcome, notebookId) = try dbQueue.write { db -> (ProfileActivationOutcome, Int64?) in
            guard let job = try RevisionJobSQL.validateFence(db, fence: fence, now: now), job.draft.kind == "embed",
                  job.draft.target == "generation:\(generationId)" else { return (.leaseLost, nil) }
            guard let generation = try GenerationSQL.generation(db, id: generationId), generation.state == "building" else {
                _ = try RevisionJobSQL.cancelJob(db, fence: fence, now: now)
                return (.invalidGeneration, nil)
            }
            let profile = try selected.profileId.map { try EmbeddingProfiles.require($0) }
            guard let profile, Self.profileIdentity(generation.identity, matches: selected, profile: profile) else {
                _ = try RevisionJobSQL.cancelJob(db, fence: fence, now: now)
                return (.selectionChanged, generation.notebookId)
            }
            guard try GenerationSQL.activeGeneration(db, notebookId: generation.notebookId)?.id == previousActiveId else {
                _ = try RevisionJobSQL.cancelJob(db, fence: fence, now: now)
                return (.activeChanged, generation.notebookId)
            }
            try GenerationSQL.activate(db, id: generationId, fence: fence, now: now)
            return (.activated, generation.notebookId)
        }
        if let notebookId { notifyFolderIngestionChanged(notebookId: notebookId) }
        return outcome
    }

    /// Exact provider/model/profile agreement with fixed dimensions and both format strings;
    /// the effective ctx limit is read from (and preserved by) the stored identity.
    nonisolated static func profileIdentity(_ identity: GenerationIdentity, matches selection: EmbeddingModelChoice,
                                            profile: EmbeddingProfile) -> Bool {
        guard selection.profileId.map({ Data($0.utf8) }) == Data(profile.id.utf8),
              Data(identity.providerId.utf8) == Data(selection.providerId.utf8),
              Data(identity.model.utf8) == Data(selection.model.utf8),
              OllamaBenchmarkClient.profileId(fromFormatVersion: identity.queryFormatVersion) == profile.id,
              identity.normalization == "l2", identity.chunkerVersion == "2" else { return false }
        return (try? profile.validateIdentity(model: identity.model, dims: identity.dims,
                                              queryFormatVersion: identity.queryFormatVersion,
                                              docFormatVersion: identity.docFormatVersion)) != nil
    }
}

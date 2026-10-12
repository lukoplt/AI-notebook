import Foundation

/// The durable `{selection, copyExisting}` options of an embed job.
struct EmbedJobOptions: Sendable, Equatable {
    let selection: EmbeddingSelection
    let copyExisting: Bool

    /// Nil when the options do not decode.
    init?(json: String) {
        guard let (selection, copyExisting) = try? EmbeddingSelection.fromOptions(json) else { return nil }
        self.init(selection: selection, copyExisting: copyExisting)
    }

    init(selection: EmbeddingSelection, copyExisting: Bool) {
        self.selection = selection
        self.copyExisting = copyExisting
    }
}

/// One embed job row as the planners see it.
struct EmbedJobSnapshot: Sendable, Equatable {
    let id: Int64
    let target: String
    let state: String
    let attempts: Int
    let nextRetryAt: Int64?
    let error: String?
    let options: EmbedJobOptions?

    var isBootstrap: Bool { target.hasPrefix("notebook:") }

    /// queued|running|paused, or failed with an automatic retry pending.
    var isUnfinished: Bool {
        switch state {
        case "queued", "running", "paused": return true
        case "failed": return attempts < 5 && nextRetryAt != nil
        default: return false
        }
    }

    /// A notebook-target job nobody owns that would still run (`ingestion-build-merge-v1` §1).
    var isUnclaimedBootstrap: Bool { isBootstrap && state != "running" && isUnfinished }

    /// The selection of a copy-existing (incremental) bootstrap.
    var incrementalSelection: EmbeddingSelection? { options?.copyExisting == true ? options?.selection : nil }
}

/// One generation of the notebook as the planners see it.
struct GenerationSnapshot: Sendable, Equatable {
    let id: Int64
    let state: String
    let identity: GenerationIdentity
}

/// Pure decisions of `indexing-status-v1` §8 and `ingestion-build-merge-v1`.
enum EmbedJobPlanning {
    /// Same vector space: every field equal; an unknown selection dimension matches any.
    static func compatible(_ selection: EmbeddingSelection, _ identity: GenerationIdentity) -> Bool {
        FolderEmbeddingSession.compatible(selection, EmbeddingSelection(identity: identity))
    }

    struct StatusJob: Sendable, Equatable {
        let job: EmbedJobSnapshot
        let bootstrap: Bool
        let progressGenerationId: Int64?
    }

    /// The embed job behind the status (`indexing-status-v1` §8): running first, then any other
    /// unfinished job, then finished ones, the highest id within a class.
    static func statusJob(jobs: [EmbedJobSnapshot], generations: [GenerationSnapshot]) -> StatusJob? {
        func rank(_ job: EmbedJobSnapshot) -> Int { job.state == "running" ? 0 : job.isUnfinished ? 1 : 2 }
        guard let pick = jobs.min(by: { (rank($0), -$0.id) < (rank($1), -$1.id) }) else { return nil }
        if let generationId = generationTarget(pick.target) {
            return StatusJob(job: pick, bootstrap: false, progressGenerationId: generationId)
        }
        if let selection = pick.incrementalSelection,
           let building = generations.filter({ $0.state == "building" && compatible(selection, $0.identity) }).map(\.id).max() {
            return StatusJob(job: pick, bootstrap: false, progressGenerationId: building)
        }
        return StatusJob(job: pick, bootstrap: pick.isBootstrap, progressGenerationId: nil)
    }

    /// The generation whose verified identity a build request adopts (`ingestion-build-merge-v1` §2).
    static func resolveBuild(selection: EmbeddingSelection, copyExisting: Bool,
                             generations: [GenerationSnapshot]) -> GenerationSnapshot? {
        guard selection.identity == nil, copyExisting else { return nil }
        for state in ["building", "active"] {
            if let match = generations.filter({ $0.state == state && compatible(selection, $0.identity) }).max(by: { $0.id < $1.id }) {
                return match
            }
        }
        return nil
    }

    /// Unclaimed incremental bootstraps the generation job of `identity` covers, in id order (§3).
    static func superseded(identity: GenerationIdentity, jobs: [EmbedJobSnapshot]) -> [Int64] {
        jobs.filter { job in
            guard job.isUnclaimedBootstrap, let selection = job.incrementalSelection else { return false }
            return compatible(selection, identity)
        }.map(\.id).sorted()
    }

    enum StartupAction: String, Sendable, Equatable {
        case keep, merge, noop
    }

    /// What runtime start does with one existing bootstrap (§4).
    static func startup(job: EmbedJobSnapshot, generations: [GenerationSnapshot], needsEmbedding: Bool) -> StartupAction {
        guard job.isUnclaimedBootstrap, let selection = job.incrementalSelection,
              let resolved = resolveBuild(selection: selection, copyExisting: true, generations: generations) else { return .keep }
        return resolved.state == "building" || needsEmbedding ? .merge : .noop
    }

    static func generationTarget(_ target: String) -> Int64? {
        target.hasPrefix("generation:") ? Int64(target.dropFirst("generation:".count)) : nil
    }
}

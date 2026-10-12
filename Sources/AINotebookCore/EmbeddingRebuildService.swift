import Foundation

/// Explicit embedding-profile rebuild across all notebooks: stage every notebook, then
/// journal → atomic activation → persist selection → clear journal with no await in
/// between. Failures before activation keep every old generation and selection.
@MainActor public final class EmbeddingRebuildService {
    private let store: NotebookStore
    private let journal: EmbeddingRebuildJournal
    private let current: @MainActor () -> EmbeddingModelChoice
    private let persist: @MainActor (EmbeddingModelChoice) throws -> Void
    private let stage: @MainActor (Int64, EmbeddingModelChoice) async throws -> IndexGeneration
    private let now: @Sendable () -> Int64
    private let verifyBeforeActivation: (@MainActor ([EmbeddingRebuildTarget]) async throws -> Void)?
    private var busy = false

    public init(store: NotebookStore, journal: EmbeddingRebuildJournal,
                current: @escaping @MainActor () -> EmbeddingModelChoice,
                persist: @escaping @MainActor (EmbeddingModelChoice) throws -> Void,
                stage: @escaping @MainActor (Int64, EmbeddingModelChoice) async throws -> IndexGeneration,
                now: @escaping @Sendable () -> Int64,
                verifyBeforeActivation: (@MainActor ([EmbeddingRebuildTarget]) async throws -> Void)? = nil) {
        self.verifyBeforeActivation = verifyBeforeActivation
        self.store = store
        self.journal = journal
        self.current = current
        self.persist = persist
        self.stage = stage
        self.now = now
    }

    public func rebuild(_ requested: EmbeddingModelChoice) async throws {
        guard !busy else { throw EmbeddingRecommendationError(code: "rebuildInProgress") }
        busy = true
        defer { busy = false }
        guard requested.profileId != nil else { throw EmbeddingRecommendationError(code: "profileRequired") }
        let previous = current()
        let notebooks = try store.embeddingRebuildNotebookIds()
        var targets: [EmbeddingRebuildTarget] = []
        do {
            try Task.checkCancellation()
            for notebookId in notebooks {
                let generation = try await stage(notebookId, requested)
                targets.append(EmbeddingRebuildTarget(notebookId: notebookId, generationId: generation.id))
                try Task.checkCancellation()
            }
            // e.g. revalidate the captured model digest on the same endpoint (publish rule).
            if let verifyBeforeActivation { try await verifyBeforeActivation(targets) }
            try Task.checkCancellation()
            // From here on, no suspension until the selection is persisted.
            try journal.write(EmbeddingRebuildRecord(previous: previous, requested: requested, targets: targets))
            do {
                try store.activateEmbeddingRebuild(targets, requested: requested, now: now())
            } catch {
                try? journal.clear()
                throw error
            }
        } catch {
            retireBuilding(targets)
            throw error
        }
        do { try persist(requested) }
        catch { throw EmbeddingRecommendationError(code: "selectionPersistenceFailed") }
        try journal.clear()
    }

    /// Startup recovery, before routers/workers exist. Idempotent.
    public func recover() throws {
        guard let record = try journal.read() else { return }
        let states = try record.targets.map { target -> String? in
            guard let g = try store.generation(id: target.generationId), g.notebookId == target.notebookId else { return nil }
            return g.state
        }
        if states.allSatisfy({ $0 == "active" }) {
            try persist(record.requested)
            try journal.clear()
        } else if states.allSatisfy({ $0 == "building" || $0 == "retired" }) {
            retireBuilding(record.targets)
            try journal.clear()
        } else {
            throw EmbeddingRecommendationError(code: "rebuildRecoveryConflict")
        }
    }

    private func retireBuilding(_ targets: [EmbeddingRebuildTarget]) {
        for target in targets where (try? store.generation(id: target.generationId))??.state == "building" {
            try? store.retireGeneration(id: target.generationId)
        }
    }
}

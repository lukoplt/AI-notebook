import Foundation

/// Typed outcome of a profile drain that could not publish (benchmark-v1 §8 `drain`):
/// `leaseLost`, `selectionChanged`, `activeChanged` or `invalidGeneration`.
public struct ProfileEmbeddingDrainError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: String
    public init(code: String) { self.code = code }
    public var description: String { "ProfileEmbeddingDrainError(\(code))" }
}

/// Ordinary (non-rebuild) embedding work for a selected named WP7 profile. It runs as the
/// first step of `Embedder.embedAllPending`, so `EmbeddingWorker` stays the single
/// coalescing entry point. Each notebook with work keeps a matching active identity
/// (resumed, ctx and digest preserved) or uses one prepared identity per run; the build
/// is staged under a freshly claimed, renewed lease and published only through the
/// fenced activation. A legacy selection returns nil (the legacy drain then runs).
@MainActor public final class ProfileEmbeddingDrain {
    /// Lease renewal cadence (the WP3 lease lasts 300 seconds).
    public static let renewalInterval: Int64 = 60

    private let store: NotebookStore
    private let selection: @Sendable () -> EmbeddingModelChoice
    private let prepare: @Sendable (EmbeddingModelChoice) async throws -> PreparedEmbeddingProfile
    private let resume: @Sendable (GenerationIdentity) async throws -> ProviderEmbeddingSession
    private let clock: any IngestLeaseClock

    public init(store: NotebookStore,
                selection: @escaping @Sendable () -> EmbeddingModelChoice,
                prepare: @escaping @Sendable (EmbeddingModelChoice) async throws -> PreparedEmbeddingProfile,
                resume: @escaping @Sendable (GenerationIdentity) async throws -> ProviderEmbeddingSession,
                clock: any IngestLeaseClock = SystemIngestLeaseClock()) {
        self.store = store
        self.selection = selection
        self.prepare = prepare
        self.resume = resume
        self.clock = clock
    }

    /// Nil for a legacy selection; otherwise the number of vectors embedded. A failure in
    /// one notebook does not starve the next; the first such error is rethrown at the end.
    /// Cancellation and a changed selection stop the run immediately.
    public func run() async throws -> Int? {
        let selected = selection()
        guard let profileId = selected.profileId else { return nil }
        let profile = try EmbeddingProfiles.require(profileId)
        var prepared: PreparedEmbeddingProfile?
        var written = 0
        var deferred: (any Error)?
        for notebookId in try store.profileEmbeddingWork(selected) {
            try Task.checkCancellation()
            let previous = try store.activeGeneration(notebookId: notebookId)
            let identity: GenerationIdentity
            let session: ProviderEmbeddingSession
            do {
                if let previous, NotebookStore.profileIdentity(previous.identity, matches: selected, profile: profile) {
                    session = try await resume(previous.identity)
                    identity = previous.identity
                } else {
                    let ready: PreparedEmbeddingProfile
                    if let prepared { ready = prepared } else {
                        // Provider discovery failure stops the run: no notebook can proceed without it.
                        do { ready = try await prepare(selected) } catch { throw DiscoveryFailure(underlying: error) }
                        prepared = ready
                    }
                    identity = ready.identity
                    session = ready.session
                }
                try Task.checkCancellation()
                guard Self.same(selection(), selected) else { throw ProfileEmbeddingDrainError(code: "selectionChanged") }
                written += try await build(notebookId: notebookId, identity: identity, session: session,
                                           previousActiveId: previous?.id)
            } catch let error as ProfileEmbeddingDrainError where error.code == "selectionChanged" {
                throw error
            } catch let failure as DiscoveryFailure {
                throw failure.underlying
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if deferred == nil { deferred = error }
            }
        }
        if let deferred { throw deferred }
        return written
    }

    private func build(notebookId: Int64, identity: GenerationIdentity, session: ProviderEmbeddingSession,
                       previousActiveId: Int64?) async throws -> Int {
        // Same guard as staging: the whole captured identity, never a storage key alone.
        guard session.identity == identity, session.endpointRevision == identity.endpointRevision else {
            throw EmbeddingGenerationError(code: "profileIdentityMismatch")
        }
        let store = self.store, clock = self.clock
        let started = try store.beginProfileEmbedding(notebookId: notebookId, identity: identity, now: clock.now(),
                                                      leaseToken: UUID().uuidString)
        let fence = started.fence
        let progress = DrainProgress()
        let stage = Task { @MainActor in
            try await EmbeddingGenerationBuilder.stage(
                store: store, notebookId: notebookId, identity: identity, sessionIdentity: session.identity,
                now: { clock.now() },
                embedDocuments: { inputs in
                    let vectors = try await session.embedDocuments(inputs: inputs)
                    progress.embedded += vectors.count
                    return vectors
                },
                existingGeneration: started.generation, reuseActive: true)
        }
        let renewal = Task { @MainActor in
            do {
                while true {
                    try await clock.wait(until: clock.now() + Self.renewalInterval)
                    guard try store.renewJob(fence: fence, now: clock.now()) else {
                        progress.leaseLost = true
                        stage.cancel()
                        return
                    }
                }
            } catch is CancellationError {
            } catch {
                progress.leaseLost = true
                stage.cancel()
            }
        }
        let staged: Result<IndexGeneration, any Error>
        do {
            staged = .success(try await withTaskCancellationHandler { try await stage.value } onCancel: { stage.cancel() })
        } catch {
            staged = .failure(error)
        }
        renewal.cancel()
        await renewal.value
        if progress.leaseLost { throw ProfileEmbeddingDrainError(code: "leaseLost") }
        if case let .failure(error) = staged {
            if error is CancellationError || Task.isCancelled {
                _ = try? store.cancelJob(fence: fence, now: clock.now())
                throw CancellationError()
            }
            _ = try? store.failEmbeddingJob(fence: fence, error: Self.failureCode(error), now: clock.now())
            throw error
        }
        let outcome: ProfileActivationOutcome
        do {
            // The selection is re-read after the last await, inside the publication transaction.
            outcome = try store.profileActivation(generationId: started.generation.id, previousActiveId: previousActiveId,
                                                  fence: fence, selected: selection(), now: clock.now())
        } catch {
            _ = try? store.failEmbeddingJob(fence: fence, error: Self.failureCode(error), now: clock.now())
            throw error
        }
        switch outcome {
        case .activated: return progress.embedded
        case .leaseLost: throw ProfileEmbeddingDrainError(code: "leaseLost")
        case .selectionChanged: throw ProfileEmbeddingDrainError(code: "selectionChanged")
        case .activeChanged: throw ProfileEmbeddingDrainError(code: "activeChanged")
        case .invalidGeneration: throw ProfileEmbeddingDrainError(code: "invalidGeneration")
        }
    }

    /// Sanitized job error: typed codes only, never provider text.
    static func failureCode(_ error: any Error) -> String {
        if let e = error as? EmbeddingGenerationError { return e.code }
        if let e = error as? EmbeddingProfileError { return e.code }
        if let e = error as? IngestionError { return e.code }
        if let e = error as? StorageV19Error { return e.code }
        return "provider-error"
    }

    private static func same(_ a: EmbeddingModelChoice, _ b: EmbeddingModelChoice) -> Bool {
        Data(a.providerId.utf8) == Data(b.providerId.utf8) && Data(a.model.utf8) == Data(b.model.utf8)
            && a.profileId.map { Data($0.utf8) } == b.profileId.map { Data($0.utf8) }
    }
}

private struct DiscoveryFailure: Error { let underlying: any Error }

@MainActor private final class DrainProgress {
    var embedded = 0
    var leaseLost = false
}

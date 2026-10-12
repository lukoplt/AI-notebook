import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

/// Lease clock advanced only by the test. `advance(_:wake:false)` models a suspended
/// process: time passes the lease while no renewal timer fires.
final class DrainLeaseClock: IngestLeaseClock, @unchecked Sendable {
    private struct Waiter { let id: UUID; let until: Int64; let continuation: CheckedContinuation<Void, Error> }
    private let lock = NSLock()
    private var current: Int64
    private var waiters: [Waiter] = []

    init(now: Int64) { current = now }

    func now() -> Int64 { lock.withLock { current } }

    func wait(until: Int64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                if current >= until { lock.unlock(); continuation.resume(); return }
                waiters.append(Waiter(id: id, until: until, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.firstIndex { $0.id == id }.map { waiters.remove(at: $0) }
            lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Suspends until a renewal timer is registered, so a time jump never races its arming.
    func waitForTimer() async {
        while lock.withLock({ waiters.isEmpty }) { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    func advance(_ seconds: Int64, wake: Bool) {
        lock.lock()
        current += seconds
        let due = wake ? waiters.filter { $0.until <= current } : []
        waiters.removeAll { waiter in due.contains { $0.id == waiter.id } }
        lock.unlock()
        for waiter in due { waiter.continuation.resume() }
    }
}

/// Fixture strict transport: records formatted inputs and native dimensions.
final class DrainTransport: StrictEmbeddingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(input: String, nativeDims: Int)] = []
    private var hooks: [@Sendable () async -> Void]
    let vector: [Float]
    let promptTokens: Int

    init(vector: [Float], promptTokens: Int, hooks: [@Sendable () async -> Void] = []) {
        self.vector = vector
        self.promptTokens = promptTokens
        self.hooks = hooks
    }

    var requests: [String] { lock.withLock { recorded.map(\.input) } }
    var nativeDims: [Int] { lock.withLock { recorded.map(\.nativeDims) } }

    func embed(model: String, input: String, nativeDims: Int, inputLimit: Int) async throws -> StrictEmbeddingResult {
        let hook: (@Sendable () async -> Void)? = lock.withLock {
            recorded.append((input, nativeDims))
            return hooks.isEmpty ? nil : hooks.removeFirst()
        }
        if let hook { await hook() }
        try Task.checkCancellation()
        return StrictEmbeddingResult(vector: vector, promptTokens: promptTokens, totalDurationNs: nil, loadDurationNs: nil)
    }
}

/// The case's `/api/tags` + `/api/show`, derived exactly as `prepareProfile` does.
struct DrainDiscovery: Sendable {
    static let root = "http://127.0.0.1:11434"
    let rows: [OllamaBenchmarkClient.TagRow]
    let show: Data

    init(_ c: [String: Any]) throws {
        rows = ((c["tags"] as! [String: Any])["models"] as! [[String: Any]]).map {
            OllamaBenchmarkClient.TagRow(name: $0["name"] as! String, digest: $0["digest"] as! String)
        }
        show = try JSONSerialization.data(withJSONObject: c["show"]!)
    }

    func prepared(_ selection: EmbeddingModelChoice, transport: DrainTransport) throws -> PreparedEmbeddingProfile {
        guard let profileId = selection.profileId else { throw EmbeddingProfileError(code: "profileRequired") }
        let profile = try EmbeddingProfiles.require(profileId)
        guard let context = try ProviderLimitPolicy.contextWindow(fromOllamaShow: show) else {
            throw EmbeddingProfileError(code: "modelMetadataUnavailable")
        }
        let limit = min(profile.maxInputTokens, context)
        let identity = try EmbeddingRecommendation.identity(
            selection: selection, endpointRevision: EmbeddingEndpointRevision.make(type: .ollama, normalizedRoot: Self.root),
            modelDigest: OllamaBenchmarkClient.exactDigest(model: profile.model, rows: rows), chunkerVersion: "2",
            effectiveLimit: limit)
        return PreparedEmbeddingProfile(identity: identity, session: try Self.session(identity, transport: transport),
                                        effectiveLimit: limit)
    }

    /// Resume of a stored identity: exact catalog profile, ctx parsed from the stored formats.
    static func session(_ identity: GenerationIdentity, transport: DrainTransport) throws -> ProviderEmbeddingSession {
        guard let profileId = OllamaBenchmarkClient.profileId(fromFormatVersion: identity.queryFormatVersion) else {
            throw EmbeddingProfileError(code: "profileIdentityMismatch")
        }
        let profile = try EmbeddingProfiles.require(profileId)
        let limit = try profile.validateIdentity(model: identity.model, dims: identity.dims,
                                                 queryFormatVersion: identity.queryFormatVersion,
                                                 docFormatVersion: identity.docFormatVersion)
        return ProviderEmbeddingSession(storageKey: identity.providerId + ":" + identity.model,
                                        endpointRevision: identity.endpointRevision, identity: identity, profile: profile,
                                        pipeline: StrictEmbeddingPipeline(transport: transport), effectiveLimit: limit)
    }
}

final class DrainSelectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: EmbeddingModelChoice
    init(_ value: EmbeddingModelChoice) { self.value = value }
    func get() -> EmbeddingModelChoice { lock.withLock { value } }
    func set(_ next: EmbeddingModelChoice) { lock.withLock { value = next } }
}

final class DrainCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func hit(_ key: String) { lock.withLock { counts[key, default: 0] += 1 } }
    func count(_ key: String) -> Int { lock.withLock { counts[key] ?? 0 } }
}

@MainActor final class ProfileEmbeddingDrainTests: XCTestCase {

    // MARK: - Fixture helpers

    private func identity(_ object: Any?) -> GenerationIdentity? {
        guard let o = object as? [String: Any] else { return nil }
        return GenerationIdentity(providerId: o["providerId"] as! String, endpointRevision: o["endpointRevision"] as! String,
                                  model: o["model"] as! String, modelDigest: o["modelDigest"] as? String,
                                  dims: o["dims"] as! Int, normalization: o["normalization"] as! String,
                                  queryFormatVersion: o["queryFormatVersion"] as! String,
                                  docFormatVersion: o["docFormatVersion"] as! String,
                                  chunkerVersion: o["chunkerVersion"] as! String)
    }

    private func choice(_ object: Any?) -> EmbeddingModelChoice {
        let o = object as! [String: Any]
        return EmbeddingModelChoice(providerId: o["providerId"] as! String, model: o["model"] as! String,
                                    profileId: o["profileId"] as? String)
    }

    private func draft(_ text: String) -> RevisionDraft {
        RevisionDraft(contentHash: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
                      canonicalText: text, textFormatVersion: 1, chunkerVersion: 2)
    }

    private func code(_ error: any Error) -> String {
        if let e = error as? ProfileEmbeddingDrainError { return e.code }
        if let e = error as? EmbeddingGenerationError { return e.code }
        if let e = error as? EmbeddingProfileError { return e.code }
        if error is CancellationError { return "cancelled" }
        return "unexpected:\(error)"
    }

    /// A complete active generation of `identity` over the notebook's published corpus.
    @discardableResult
    private func activate(_ store: NotebookStore, notebookId: Int64, identity: GenerationIdentity, now: Int64) async throws -> IndexGeneration {
        let generation = try await EmbeddingGenerationBuilder.stage(
            store: store, notebookId: notebookId, identity: identity, sessionIdentity: identity, now: { now },
            embedDocuments: { inputs in inputs.map { _ in [1] + [Float](repeating: 0, count: identity.dims - 1) } })
        try store.activateGeneration(id: generation.id, now: now)
        return generation
    }

    private func query<T>(_ store: NotebookStore, _ body: (Database) throws -> T) throws -> T {
        try store.dbQueue.read(body)
    }

    private func vectorRows(_ store: NotebookStore, generations: [Int64]) throws -> Int {
        try generations.reduce(0) { total, id in
            total + (try store.dbQueue.read {
                try Int.fetchOne($0, sql: "SELECT count(*) FROM chunk_embeddings WHERE generation_id=?", arguments: [id]) ?? 0
            })
        }
    }

    private func jobState(_ store: NotebookStore, generations: [Int64]) throws -> String? {
        try store.dbQueue.read { db in
            try generations.compactMap { id in
                try String.fetchOne(db, sql: "SELECT state FROM ingest_jobs WHERE kind='embed' AND target=? ORDER BY id DESC LIMIT 1",
                                    arguments: ["generation:\(id)"])
            }.last
        }
    }

    private func maxGenerationId(_ store: NotebookStore) throws -> Int64 {
        try store.dbQueue.read { try Int64.fetchOne($0, sql: "SELECT coalesce(max(id),0) FROM index_generations") ?? 0 }
    }

    // MARK: - Shared drain matrix

    func testSharedDrainCases() async throws {
        let rows = try BenchmarkFixture.cases("embedding-default-v1.json", kind: "drain")
        XCTAssertEqual(rows.map { $0["name"] as! String }, [
            "fresh-import", "restart-no-work", "same-model-other-dims", "legacy-no-profile", "refresh-pending",
            "lost-lease", "selected-profile-changed", "changed-active-during-request"])
        for c in rows { try await runDrainCase(c) }
    }

    private func runDrainCase(_ c: [String: Any]) async throws {
        let name = c["name"] as! String
        let expected = c["expected"] as! [String: Any]
        let store = try NotebookStore(path: .inMemory)
        let notebookId = try XCTUnwrap(try store.createNotebook(name: name).id)
        let sourceId = try XCTUnwrap(try store.createSource(notebookId: notebookId, type: .text, title: "doc", uri: nil,
                                                            rawPath: nil).id)
        let text = c["canonicalText"] as! String
        let revisions = c["source"] as! [String: Any]
        for r in 0..<(revisions["publishedRevision"] as! Int) {
            _ = try store.commitForegroundRevision(sourceId: sourceId, draft: draft(text), chunks: ScalarChunker.chunk(text),
                                                   now: Int64(r), leaseToken: "fixture-extract-\(r)")
        }
        var previous: IndexGeneration?
        if let before = identity(c["activeBefore"]) {
            previous = try await activate(store, notebookId: notebookId, identity: before, now: 5)
        }
        if (revisions["currentRevision"] as! Int) > (revisions["publishedRevision"] as! Int) {
            _ = try store.insertRevision(sourceId: sourceId, draft: draft("refresh"), now: 6)
        }
        let setupMax = try maxGenerationId(store)

        let clock = DrainLeaseClock(now: 100)
        let selection = DrainSelectionBox(choice(c["selection"]))
        let other = DrainOtherActivation()
        var hooks: [@Sendable () async -> Void] = []
        for event in c["events"] as! [[String: Any]] {
            XCTAssertEqual(event["after"] as? String, "request", name)
            switch event["kind"] as! String {
            case "advanceClock":
                let seconds = Int64(event["seconds"] as! Int)
                hooks.append { await clock.waitForTimer(); clock.advance(seconds, wake: false) }
            case "changeSelection":
                let next = choice(event["selection"])
                hooks.append { selection.set(next) }
            case "activateOther":
                let otherIdentity = try XCTUnwrap(identity(event["identity"]))
                hooks.append { [store] in
                    await MainActor.run {
                        do {
                            let g = try store.createGeneration(notebookId: notebookId, identity: otherIdentity, now: clock.now())
                            for chunk in try store.chunks(sourceId: sourceId) {
                                try store.storeGenerationEmbedding(generationId: g.id, chunkId: chunk.id!, vector:
                                    EmbeddingVector(values: [1] + [Float](repeating: 0, count: otherIdentity.dims - 1)))
                            }
                            try store.reconcileManifest(generationId: g.id)
                            try store.setManifest(generationId: g.id, entries: try store.manifest(generationId: g.id).map {
                                ManifestEntry(sourceId: $0.sourceId, revisionId: $0.revisionId, state: "done", reason: nil)
                            })
                            try store.activateGeneration(id: g.id, now: clock.now())
                            other.id = g.id
                        } catch { XCTFail("activateOther: \(error)") }
                    }
                }
            default: XCTFail("unknown event \(event)")
            }
        }
        let transportSpec = c["transport"] as! [String: Any]
        let transport = DrainTransport(vector: BenchmarkFixture.vector(transportSpec["vector"]),
                                       promptTokens: transportSpec["promptTokens"] as! Int, hooks: hooks)
        let calls = DrainCallCounter()
        let discovery = try DrainDiscovery(c)
        let drain = ProfileEmbeddingDrain(
            store: store, selection: { selection.get() },
            prepare: { chosen in
                calls.hit("prepare")
                return try discovery.prepared(chosen, transport: transport)
            },
            resume: { stored in
                calls.hit("resume")
                return try DrainDiscovery.session(stored, transport: transport)
            },
            clock: clock)

        var result: Int??
        var thrown: (any Error)?
        do { result = .some(try await drain.run()) } catch { thrown = error }

        XCTAssertEqual(thrown.map(code), expected["error"] as? String, name)
        if thrown == nil { XCTAssertEqual(result!, expected["result"] as? Int, name) }
        XCTAssertEqual(transport.requests, expected["requests"] as! [String], name)
        if let native = expected["nativeDims"] as? Int {
            XCTAssertEqual(transport.nativeDims, [native], name)
        }
        // WP0 scheduler sweep: an expired attempt is requeued with backoff, never published.
        _ = try store.recoverExpiredJobs(now: clock.now())
        let created = try query(store) { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM index_generations WHERE id>? ORDER BY id", arguments: [setupMax])
        }.filter { $0 != other.id }
        XCTAssertEqual(try vectorRows(store, generations: created), expected["rowsWritten"] as! Int, name)
        XCTAssertEqual(try jobState(store, generations: created), expected["jobState"] as? String, name)
        let active = try store.activeGeneration(notebookId: notebookId)
        XCTAssertEqual(active?.identity, identity(expected["activeIdentity"]), name)
        XCTAssertEqual(active.map { created.contains($0.id) } ?? false, expected["published"] as! Bool, name)
        if expected["activeGenerationUnchanged"] as? Bool == true {
            XCTAssertEqual(active?.id, previous?.id, name)
            XCTAssertEqual(calls.count("prepare") + calls.count("resume"), 0, name)
        }
        if expected["previousActiveRetired"] as? Bool == true, let previous {
            XCTAssertEqual(try store.generation(id: previous.id)?.state, "retired", name)
        }
        if let dims = expected["dims"] as? Int, let active, expected["published"] as! Bool {
            XCTAssertEqual(active.identity.dims, dims, name)
            XCTAssertEqual(active.identity.queryFormatVersion, expected["queryFormatVersion"] as? String, name)
            XCTAssertEqual(active.identity.docFormatVersion, expected["docFormatVersion"] as? String, name)
            let stored = try XCTUnwrap(try query(store) { db in
                try Data.fetchOne(db, sql: "SELECT embedding FROM chunk_embeddings WHERE generation_id=?", arguments: [active.id])
            }, name)
            let values = try EmbeddingVector(data: stored).values
            XCTAssertEqual(values.count, dims, name)
            XCTAssertEqual(values[0], 1, accuracy: 1e-6, name)
            XCTAssertEqual(values.dropFirst().map(abs).max() ?? 0, 0, accuracy: 1e-6, name)
        }
        if expected["result"] is NSNull, expected["error"] == nil {
            XCTAssertEqual(calls.count("prepare") + calls.count("resume"), 0, name) // legacy: untouched
        }
    }

    // MARK: - Restart, resume and lease renewal

    func testReopenedFileStoreWithPersistedSelectionDoesNoProviderWork() async throws {
        let c = try XCTUnwrap(try BenchmarkFixture.cases("embedding-default-v1.json", kind: "drain")
            .first { $0["name"] as? String == "fresh-import" })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = StorePath(fileURL: dir.appendingPathComponent("db.sqlite"))
        let persisted = choice(c["selection"])
        let text = c["canonicalText"] as! String
        let transport = DrainTransport(vector: BenchmarkFixture.vector((c["transport"] as! [String: Any])["vector"]),
                                       promptTokens: 7)
        let calls = DrainCallCounter()
        let discovery = try DrainDiscovery(c)
        func drain(_ store: NotebookStore) -> ProfileEmbeddingDrain {
            ProfileEmbeddingDrain(store: store, selection: { persisted },
                prepare: { chosen in calls.hit("prepare"); return try discovery.prepared(chosen, transport: transport) },
                resume: { stored in calls.hit("resume"); return try DrainDiscovery.session(stored, transport: transport) },
                clock: DrainLeaseClock(now: 100))
        }
        var first: NotebookStore? = try NotebookStore(path: path)
        let notebookId = try XCTUnwrap(try first!.createNotebook(name: "file").id)
        let sourceId = try XCTUnwrap(try first!.createSource(notebookId: notebookId, type: .text, title: "doc", uri: nil,
                                                             rawPath: nil).id)
        _ = try first!.commitForegroundRevision(sourceId: sourceId, draft: draft(text), chunks: ScalarChunker.chunk(text),
                                               now: 1, leaseToken: "fixture-extract")
        let written = try await drain(first!).run()
        XCTAssertEqual(written, 1)
        let generationId = try XCTUnwrap(try first!.activeGeneration(notebookId: notebookId)?.id)
        first = nil

        let reopened = try NotebookStore(path: path)
        XCTAssertEqual(try reopened.profileEmbeddingWork(persisted), [])
        let again = try await drain(reopened).run()
        XCTAssertEqual(again, 0)
        XCTAssertEqual(transport.requests, ["search_document: Záruka platí."])
        XCTAssertEqual(calls.count("prepare"), 1)
        XCTAssertEqual(calls.count("resume"), 0)
        XCTAssertEqual(try reopened.activeGeneration(notebookId: notebookId)?.id, generationId)
    }

    func testMatchingActiveIdentityResumesAndEmbedsOnlyNewRevisions() async throws {
        let c = try XCTUnwrap(try BenchmarkFixture.cases("embedding-default-v1.json", kind: "drain")
            .first { $0["name"] as? String == "restart-no-work" })
        let store = try NotebookStore(path: .inMemory)
        let notebookId = try XCTUnwrap(try store.createNotebook(name: "resume").id)
        let a = try XCTUnwrap(try store.createSource(notebookId: notebookId, type: .text, title: "a", uri: nil, rawPath: nil).id)
        _ = try store.commitForegroundRevision(sourceId: a, draft: draft("alpha"), chunks: ScalarChunker.chunk("alpha"),
                                               now: 1, leaseToken: "extract-a")
        let stored = try XCTUnwrap(identity(c["activeBefore"]))
        let old = try await activate(store, notebookId: notebookId, identity: stored, now: 2)
        let b = try XCTUnwrap(try store.createSource(notebookId: notebookId, type: .text, title: "b", uri: nil, rawPath: nil).id)
        _ = try store.commitForegroundRevision(sourceId: b, draft: draft("beta"), chunks: ScalarChunker.chunk("beta"),
                                               now: 3, leaseToken: "extract-b")
        let selection = choice(c["selection"])
        XCTAssertEqual(try store.profileEmbeddingWork(selection), [notebookId])
        let transport = DrainTransport(vector: BenchmarkFixture.vector((c["transport"] as! [String: Any])["vector"]),
                                       promptTokens: 7)
        let calls = DrainCallCounter()
        let drain = ProfileEmbeddingDrain(store: store, selection: { selection },
            prepare: { _ in calls.hit("prepare"); throw EmbeddingProfileError(code: "unexpectedPrepare") },
            resume: { identity in
                calls.hit("resume")
                XCTAssertEqual(identity, stored)
                return try DrainDiscovery.session(identity, transport: transport)
            }, clock: DrainLeaseClock(now: 100))
        let written = try await drain.run()
        XCTAssertEqual(written, 1)
        XCTAssertEqual(transport.requests, ["search_document: beta"])
        XCTAssertEqual(calls.count("prepare"), 0)
        XCTAssertEqual(calls.count("resume"), 1)
        let active = try XCTUnwrap(try store.activeGeneration(notebookId: notebookId))
        XCTAssertNotEqual(active.id, old.id)
        XCTAssertEqual(active.identity, stored) // ctx suffix and digest preserved
        XCTAssertEqual(try store.generation(id: old.id)?.state, "retired")
        XCTAssertEqual(try vectorRows(store, generations: [active.id]), 2)
    }

    func testRenewalKeepsLongRequestPublishableAndLostRenewalNeverPublishes() async throws {
        let c = try XCTUnwrap(try BenchmarkFixture.cases("embedding-default-v1.json", kind: "drain")
            .first { $0["name"] as? String == "fresh-import" })
        for (steps, publishes) in [([250, 200], true), ([301], false)] as [([Int64], Bool)] {
            let store = try NotebookStore(path: .inMemory)
            let notebookId = try XCTUnwrap(try store.createNotebook(name: "renew").id)
            let sourceId = try XCTUnwrap(try store.createSource(notebookId: notebookId, type: .text, title: "doc", uri: nil,
                                                                rawPath: nil).id)
            _ = try store.commitForegroundRevision(sourceId: sourceId, draft: draft("x"), chunks: ScalarChunker.chunk("x"),
                                                   now: 1, leaseToken: "extract")
            let clock = DrainLeaseClock(now: 100)
            let hook: @Sendable () async -> Void = {
                for step in steps {
                    // The renewal re-arms its timer only after the woken renewal reached the store.
                    await clock.waitForTimer()
                    clock.advance(step, wake: true)
                }
            }
            let transport = DrainTransport(vector: BenchmarkFixture.vector((c["transport"] as! [String: Any])["vector"]),
                                           promptTokens: 7, hooks: [hook])
            let selection = choice(c["selection"])
            let discovery = try DrainDiscovery(c)
            let drain = ProfileEmbeddingDrain(store: store, selection: { selection },
                prepare: { chosen in try discovery.prepared(chosen, transport: transport) },
                resume: { stored in try DrainDiscovery.session(stored, transport: transport) },
                clock: clock)
            do {
                let written = try await drain.run()
                XCTAssertTrue(publishes, "lost renewal published")
                XCTAssertEqual(written, 1)
                XCTAssertNotNil(try store.activeGeneration(notebookId: notebookId))
            } catch {
                XCTAssertFalse(publishes, "renewed request failed: \(error)")
                XCTAssertEqual(code(error), "leaseLost")
                XCTAssertNil(try store.activeGeneration(notebookId: notebookId))
            }
        }
    }

    func testEmptyNotebookAndLegacySelectionAreNotWork() async throws {
        let store = try NotebookStore(path: .inMemory)
        _ = try store.createNotebook(name: "empty")
        let selection = try EmbeddingRecommendation.selection(profileId: "nomic-v2-256")
        XCTAssertEqual(try store.profileEmbeddingWork(selection), [])
        XCTAssertEqual(try store.profileEmbeddingWork(EmbeddingModelChoice(providerId: selection.providerId,
                                                                           model: "nomic-embed-text", profileId: nil)), [])
        let drain = ProfileEmbeddingDrain(store: store, selection: { selection },
            prepare: { _ in throw EmbeddingProfileError(code: "unexpectedPrepare") },
            resume: { _ in throw EmbeddingProfileError(code: "unexpectedResume") }, clock: DrainLeaseClock(now: 1))
        let written = try await drain.run()
        XCTAssertEqual(written, 0)
    }
}

final class DrainOtherActivation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64?
    var id: Int64? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

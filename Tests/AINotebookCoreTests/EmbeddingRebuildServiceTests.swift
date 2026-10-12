import XCTest
@testable import AINotebookCore

@MainActor final class EmbeddingRebuildServiceTests: XCTestCase {

    private func tempJournal() throws -> EmbeddingRebuildJournal {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return EmbeddingRebuildJournal(url: dir.appendingPathComponent(EmbeddingRebuildJournal.fileName))
    }

    private func code(_ error: any Error) -> String {
        if let e = error as? EmbeddingRecommendationError { return e.code }
        if let e = error as? EmbeddingGenerationError { return e.code }
        if error is CancellationError { return "cancelled" }
        return "unexpected:\(error)"
    }

    func testSecondActivationFailureRollsBackFirst() throws {
        let store = try NotebookStore(path: .inMemory)
        let selection = try EmbeddingRecommendation.selection(profileId: "nomic-v2-256")
        let identity = try EmbeddingRecommendation.identity(selection: selection, endpointRevision: "endpoint-v1:test",
                                                            modelDigest: nil, chunkerVersion: "1")
        let a = try store.createNotebook(name: "a").id!
        let b = try store.createNotebook(name: "b").id!
        let oldA = try store.createGeneration(notebookId: a, identity: identity, now: 1)
        let oldB = try store.createGeneration(notebookId: b, identity: identity, now: 1)
        try store.activateGeneration(id: oldA.id, now: 2)
        try store.activateGeneration(id: oldB.id, now: 2)
        let nextA = try store.createGeneration(notebookId: a, identity: identity, now: 3)
        XCTAssertThrowsError(try store.activateEmbeddingRebuild([
            EmbeddingRebuildTarget(notebookId: a, generationId: nextA.id),
            EmbeddingRebuildTarget(notebookId: b, generationId: Int64.max)
        ], requested: selection, now: 4))
        XCTAssertEqual(try store.activeGeneration(notebookId: a)?.id, oldA.id)
        XCTAssertEqual(try store.activeGeneration(notebookId: b)?.id, oldB.id)
        XCTAssertEqual(try store.generation(id: nextA.id)?.state, "building")
    }

    func testCommittedActivationIsRecoveredBeforeSettingsAreReadByRouter() async throws {
        let store = try NotebookStore(path: .inMemory)
        _ = try store.createNotebook(name: "one")
        let old = EmbeddingModelChoice(providerId: ProviderConfig.ollamaId, model: "nomic-embed-text", profileId: nil)
        let next = try EmbeddingRecommendation.selection(profileId: "nomic-v2-256")
        var selected = old
        var failSettingsWrite = true
        let journal = try tempJournal()
        let service = EmbeddingRebuildService(store: store, journal: journal,
            current: { selected }, persist: { value in
                if failSettingsWrite { throw EmbeddingRecommendationError(code: "settingsWriteFailed") }
                selected = value
            }, stage: { notebookId, selection in
                let identity = try EmbeddingRecommendation.identity(selection: selection,
                    endpointRevision: "endpoint-v1:test", modelDigest: nil, chunkerVersion: "1")
                return try store.createGeneration(notebookId: notebookId, identity: identity, now: 1)
            }, now: { 2 })
        do { try await service.rebuild(next); XCTFail("settings write must fail") } catch {}
        XCTAssertEqual(selected, old)
        XCTAssertNotNil(try journal.read())
        failSettingsWrite = false
        try service.recover()
        XCTAssertEqual(selected, next)
        XCTAssertNil(try journal.read())
        try service.recover() // idempotent
        XCTAssertEqual(selected, next)
    }

    func testJournalRoundTripAndCorruption() throws {
        let journal = try tempJournal()
        XCTAssertNil(try journal.read())
        try journal.clear()
        let record = EmbeddingRebuildRecord(
            previous: EmbeddingModelChoice(providerId: ProviderConfig.ollamaId, model: "nomic-embed-text", profileId: nil),
            requested: try EmbeddingRecommendation.selection(profileId: "bge-m3-1024"),
            targets: [EmbeddingRebuildTarget(notebookId: 1, generationId: 7)])
        try journal.write(record)
        XCTAssertEqual(try journal.read(), record)
        let text = String(decoding: try Data(contentsOf: journal.url), as: UTF8.self)
        XCTAssertFalse(text.contains("http"))
        try Data("{".utf8).write(to: journal.url)
        XCTAssertThrowsError(try journal.read()) { XCTAssertEqual(self.code($0), "invalidJournal") }
        let duplicate = EmbeddingRebuildRecord(previous: record.previous, requested: record.requested,
                                               targets: record.targets + record.targets)
        XCTAssertThrowsError(try journal.write(duplicate))
        let unwritable = EmbeddingRebuildJournal(url: URL(fileURLWithPath: "/dev/null/x/embedding-rebuild-v1.json"))
        XCTAssertThrowsError(try unwritable.write(record))
    }

    func testVerifyBeforeActivationFailureKeepsOldGenerations() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "one").id!
        let old = EmbeddingModelChoice(providerId: ProviderConfig.ollamaId, model: "nomic-embed-text", profileId: nil)
        let next = try EmbeddingRecommendation.selection(profileId: "nomic-v2-256")
        var selected = old
        var staged: [Int64] = []
        let journal = try tempJournal()
        let service = EmbeddingRebuildService(store: store, journal: journal, current: { selected },
            persist: { selected = $0 }, stage: { notebookId, selection in
                let identity = try EmbeddingRecommendation.identity(selection: selection, endpointRevision: "e",
                                                                    modelDigest: nil, chunkerVersion: "2")
                let g = try store.createGeneration(notebookId: notebookId, identity: identity, now: 1)
                staged.append(g.id)
                return g
            }, now: { 2 }, verifyBeforeActivation: { targets in
                XCTAssertEqual(targets.map(\.notebookId), [nb])
                throw EmbeddingProfileError(code: "embeddingModelChanged")
            })
        do { try await service.rebuild(next); XCTFail("verified a changed model") }
        catch { XCTAssertEqual((error as? EmbeddingProfileError)?.code, "embeddingModelChanged") }
        XCTAssertEqual(selected, old)
        XCTAssertNil(try journal.read())
        XCTAssertNil(try store.activeGeneration(notebookId: nb))
        XCTAssertEqual(try staged.map { try store.generation(id: $0)?.state }, ["retired"])
    }

    // MARK: - Shared rebuild cases

    func testSharedRebuildCases() async throws {
        let rows = try BenchmarkFixture.cases("embedding-default-v1.json", kind: "rebuild")
        XCTAssertEqual(rows.count, 15)
        for c in rows { try await runRebuildCase(c) }
    }

    private func runRebuildCase(_ c: [String: Any]) async throws {
        let name = c["name"] as! String
        let op = c["operation"] as! [String: Any]
        let failAt = op["failAt"] as? String
        let failNotebook = op["notebook"] as? Int
        let store = try NotebookStore(path: .inMemory)
        let old = EmbeddingModelChoice(providerId: ProviderConfig.ollamaId, model: "nomic-embed-text", profileId: nil)
        let next = try EmbeddingRecommendation.selection(profileId: "nomic-v2-256")
        let oldIdentity = GenerationIdentity(providerId: ProviderConfig.ollamaId, endpointRevision: "endpoint-v1:test",
                                             model: "nomic-embed-text", modelDigest: nil, dims: 768, normalization: "l2",
                                             queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")
        var notebooks: [Int64] = []
        var oldActive: [Int64: Int64] = [:]
        for i in 0..<(c["notebooks"] as! Int) {
            let id = try store.createNotebook(name: "n\(i)").id!
            let g = try store.createGeneration(notebookId: id, identity: oldIdentity, now: 1)
            try store.activateGeneration(id: g.id, now: 1)
            notebooks.append(id)
            oldActive[id] = g.id
        }
        var selected = old
        var failPersist = failAt == "persist"
        var staged: [Int64] = []
        var secondError: String?
        let journal = try tempJournal()
        var service: EmbeddingRebuildService!
        let stage: @MainActor (Int64, EmbeddingModelChoice) async throws -> IndexGeneration = { notebookId, selection in
            let index = (notebooks.firstIndex(of: notebookId) ?? -1) + 1
            if failAt == "addNotebookDuringStage" && index == 1 { _ = try store.createNotebook(name: "late") }
            if failAt == "concurrentRebuild" && index == 1 {
                do { try await service.rebuild(next) } catch { secondError = self.code(error) }
            }
            let identity = try EmbeddingRecommendation.identity(selection: selection, endpointRevision: "endpoint-v1:test",
                                                                modelDigest: nil, chunkerVersion: "2")
            if failAt == "activationTarget" && index == failNotebook {
                return IndexGeneration(id: Int64(Int32.max), notebookId: notebookId, identity: identity, state: "building",
                                       createdAt: 3, activatedAt: nil)
            }
            let g = try store.createGeneration(notebookId: notebookId, identity: identity, now: 3)
            staged.append(g.id)
            if failAt == "stage" && index == failNotebook {
                // Like EmbeddingGenerationBuilder: a failed stage retires the generation it created.
                try store.retireGeneration(id: g.id)
                throw EmbeddingGenerationError(code: "stageFailed")
            }
            if (failAt == "cancelAfterStage" && index == failNotebook)
                || (failAt == "cancelBeforeJournal" && index == notebooks.count) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return g
        }
        service = EmbeddingRebuildService(store: store, journal: journal, current: { selected },
            persist: { value in
                if failPersist { throw EmbeddingRecommendationError(code: "settingsWriteFailed") }
                selected = value
            }, stage: stage, now: { 4 })
        var observed: String?
        switch failAt {
        case "crashAfterActivation", "crashAfterJournal", "mixedJournalTargets":
            var targets: [EmbeddingRebuildTarget] = []
            for nb in notebooks {
                let g = try await stage(nb, next)
                targets.append(EmbeddingRebuildTarget(notebookId: nb, generationId: g.id))
                if failAt == "mixedJournalTargets" && targets.count == 1 { try store.activateGeneration(id: g.id, now: 4) }
            }
            try journal.write(EmbeddingRebuildRecord(previous: old, requested: next, targets: targets))
            if failAt == "crashAfterActivation" { try store.activateEmbeddingRebuild(targets, requested: next, now: 4) }
        case "cancelBeforeStage":
            let task = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                try await service.rebuild(next)
            }
            do { try await task.value } catch { observed = code(error) }
        default:
            // Own task: a cancellation injected by the stage hook must not leak into later cases.
            let task = Task { @MainActor in try await service.rebuild(next) }
            do { try await task.value } catch { observed = code(error) }
        }
        failPersist = false
        for _ in 0..<(op["recover"] as? Int ?? 0) {
            // A fresh service models the next launch.
            let reopened = EmbeddingRebuildService(store: store, journal: journal, current: { selected },
                                                   persist: { selected = $0 }, stage: stage, now: { 5 })
            do { try reopened.recover() } catch { observed = observed ?? code(error) }
        }
        XCTAssertEqual(failAt == "concurrentRebuild" ? secondError : observed, c["expectedError"] as? String, name)
        XCTAssertEqual(selected, (c["expectedSelection"] as? String) == "new" ? next : old, name)
        XCTAssertEqual(try journal.read() != nil, c["journalRetained"] as? Bool, name)
        let active = try notebooks.map { try store.activeGeneration(notebookId: $0)?.id }
        switch c["expectedActive"] as? String {
        case "old": XCTAssertEqual(active, notebooks.map { oldActive[$0] }, name)
        case "new": XCTAssertTrue(active.allSatisfy { $0.map(staged.contains) ?? false }, name)
        case "none": XCTAssertTrue(notebooks.isEmpty, name)
        case "mixed":
            XCTAssertTrue(active.contains { $0.map(staged.contains) ?? false }, name)
            XCTAssertTrue(active.contains { $0.map { oldActive.values.contains($0) } ?? false }, name)
        default: XCTFail(name)
        }
        let states = try staged.map { try store.generation(id: $0)?.state }
        if let expected = c["expectedStagedState"] as? String {
            XCTAssertFalse(states.isEmpty, name)
            XCTAssertTrue(states.allSatisfy { $0 == expected }, "\(name): \(states)")
        } else if failAt != "mixedJournalTargets" {
            XCTAssertTrue(states.isEmpty, name)
        }
    }
}

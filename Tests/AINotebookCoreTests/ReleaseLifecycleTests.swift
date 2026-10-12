import XCTest
@testable import AINotebookCore

/// WP9: restart reconciliation, cancelled extraction + resume with a new job,
/// deletion after a completed scan and immediate rule revocation, each over a
/// fresh upgraded six-file tree.
@MainActor
final class ReleaseLifecycleTests: XCTestCase {

    private func run(_ body: @MainActor (ReleaseHarness) async throws -> Void) async throws {
        let h = try await ReleaseHarness.open()
        do {
            try await body(h)
            await h.close()
            try h.removeTemporaryFiles()
        } catch {
            await h.close()
            try? h.removeTemporaryFiles()
            throw error
        }
    }

    func testRestartReconcilesChangesMadeWhileStopped() async throws {
        try await run { h in
            let row = h.fixture.caseNamed("restart-reconcile")
            let relPath = try XCTUnwrap(row.relPath)
            let before = try h.source(relPath)
            let answer = try await h.send(try await h.prepare())
            let snapshots = answer.citations
            XCTAssertFalse(snapshots.isEmpty)

            await h.close()
            try h.append(caseName: row.name)
            try await h.reopen()
            // Reopening alone changes nothing; only reconciliation rescans.
            XCTAssertEqual(try h.source(relPath).publishedRevisionId, before.publishedRevisionId)
            try await h.reconcile()
            try await h.drain()

            let after = try h.source(relPath)
            XCTAssertEqual(after.id == before.id, row.expected.sameSource)
            XCTAssertEqual(after.publishedRevisionId != before.publishedRevisionId, row.expected.newRevision)
            let revision = try XCTUnwrap(h.store.revision(id: XCTUnwrap(after.publishedRevisionId)))
            XCTAssertTrue(revision.draft.canonicalText.hasSuffix(try XCTUnwrap(row.append)))
            XCTAssertEqual(try h.store.messages(sessionId: h.sessionId).last?.citations, snapshots)
            XCTAssertEqual(try h.store.folders(notebookId: h.notebookId).count, 1)
            XCTAssertEqual(try h.store.sources(notebookId: h.notebookId).filter { $0.folderId == h.folderId }.count,
                           row.expected.files)
            let prepared = try await h.prepare()
            XCTAssertEqual(prepared.request.coverage.corpus.searchable, row.expected.searchable)
            XCTAssertTrue(prepared.request.citationMap.contains {
                $0.sourceId == before.id && $0.text?.contains("WP9-RESTART") == true
            })
        }
    }

    func testCancelMidExtractionThenResumeWithNewJob() async throws {
        try await run { h in
            let row = h.fixture.caseNamed("cancel-resume")
            let relPath = try XCTUnwrap(row.relPath)
            let old = try h.source(relPath)
            let oldRevisionId = try XCTUnwrap(old.publishedRevisionId)
            let oldText = try XCTUnwrap(h.store.revision(id: oldRevisionId)).draft.canonicalText
            try h.append(caseName: row.name)
            try await h.scanOnly()
            let target = "source:\(try XCTUnwrap(old.id))"
            let jobs = try h.store.dueJobs(kind: "extract", now: h.clock.now(), limit: 32).filter { $0.draft.target == target }
            XCTAssertEqual(jobs.count, 1)
            let job = try XCTUnwrap(jobs.first)
            do {
                let entered = expectation(description: "real extraction reached the publication barrier")
                await h.gate.arm { entered.fulfill() }
                let queue = h.queue, worker = h.worker
                let attempt = Task {
                    try await queue.runOne(kind: "extract", reservedBytes: 1) { job, fence in
                        try await worker.execute(job: job, fence: fence)
                    }
                }
                do {
                    await fulfillment(of: [entered], timeout: 10)
                    guard await h.gate.hasEntered else { throw ReleaseIntegrationError(description: "gate timeout") }
                    XCTAssertEqual(try h.store.job(id: job.id)?.state, "running")
                    XCTAssertEqual(try h.store.job(id: job.id)?.attempts, 1)
                } catch {
                    attempt.cancel()
                    await h.gate.release()
                    _ = try? await attempt.value
                    throw error
                }
                // User cancellation: durably cancels the fenced attempt (terminal, not a pause).
                try await h.queue.cancel(jobId: job.id)
                await h.gate.release()
                do { _ = try await attempt.value } catch is CancellationError {}
            }
            let cancelled = try XCTUnwrap(h.store.job(id: job.id))
            XCTAssertEqual(cancelled.state, row.expected.cancelledState)
            XCTAssertNil(cancelled.leaseToken)
            XCTAssertNil(cancelled.leaseUntil)
            XCTAssertEqual(try h.source(relPath).currentRevision, old.currentRevision)
            XCTAssertEqual(try h.source(relPath).publishedRevisionId == oldRevisionId, row.expected.oldRevisionRetained)
            let retainedText = try XCTUnwrap(h.store.revision(id: oldRevisionId)).draft.canonicalText
            XCTAssertEqual(Array(retainedText.utf8), Array(oldText.utf8))
            let oldPack = try await h.prepare()
            XCTAssertEqual(oldPack.request.coverage.corpus.searchable, row.expected.searchable)
            XCTAssertTrue(oldPack.request.citationMap.contains { $0.sourceId == old.id && $0.revisionId == oldRevisionId })

            // Resume = restart + a new verified scan scheduling a NEW extraction job.
            await h.close()
            try await h.reopen()
            try await h.scanOnly()
            let retries = try h.store.dueJobs(kind: "extract", now: h.clock.now(), limit: 32).filter { $0.draft.target == target }
            XCTAssertEqual(retries.count, 1)
            let retry = try XCTUnwrap(retries.first)
            XCTAssertEqual(retry.id != job.id, row.expected.newJob)
            XCTAssertEqual(retry.attempts, 0)
            try await h.drain()
            XCTAssertEqual(try h.store.job(id: retry.id)?.state, "done")
            XCTAssertEqual(try h.store.job(id: retry.id)?.attempts, 1)
            let freshRevisionId = try XCTUnwrap(h.source(relPath).publishedRevisionId)
            XCTAssertEqual(freshRevisionId != oldRevisionId, row.expected.newRevision)
            XCTAssertTrue(try XCTUnwrap(h.store.revision(id: freshRevisionId)).draft.canonicalText
                .hasSuffix(try XCTUnwrap(row.append)))
            XCTAssertEqual(try h.store.job(id: job.id)?.state, row.expected.cancelledState)
            let fresh = try await h.prepare()
            XCTAssertEqual(fresh.request.coverage.corpus.searchable, row.expected.searchable)
            XCTAssertTrue(fresh.request.citationMap.contains { $0.sourceId == old.id && $0.text?.contains("WP9-RESUME") == true })
        }
    }

    func testDeletionBecomesMissingAfterCompletedScanAndKeepsCitation() async throws {
        try await run { h in
            let row = h.fixture.caseNamed("delete-completed-scan")
            let relPath = try XCTUnwrap(row.relPath)
            let source = try h.source(relPath)
            let one = try await h.prepare(scope: .selection(sourceIds: [try XCTUnwrap(source.id)], folderIds: []))
            let answer = try await h.send(one)
            let snapshot = try XCTUnwrap(answer.citations.first?.text)
            try h.delete(relPath: relPath)
            XCTAssertEqual(try h.source(relPath).availability, row.expected.before)
            try await h.scanOnly()
            try await h.drain()
            let folder = try XCTUnwrap(h.store.folders(notebookId: h.notebookId).first)
            XCTAssertEqual(folder.scanState, "idle")
            XCTAssertNotNil(folder.lastFullScanAt)
            XCTAssertEqual(try h.source(relPath).availability, row.expected.after)
            let pack = try await h.prepare()
            XCTAssertEqual(pack.request.coverage.corpus.searchable, row.expected.searchable)
            XCTAssertEqual(pack.request.coverage.corpus.missing, row.expected.missing)
            XCTAssertFalse(pack.request.citationMap.contains { $0.sourceId == source.id })
            let pool = try await h.pool(query: "RE-DE-2026-061")
            XCTAssertFalse(pool.vector.contains { $0.reference.sourceId == source.id })
            XCTAssertFalse(pool.lexical.contains { $0.reference.sourceId == source.id })
            await pool.close()
            await h.close()
            try await h.reopen()
            XCTAssertEqual(try h.store.messages(sessionId: h.sessionId).last?.citations.first?.text == snapshot,
                           row.expected.oldCitationReadable)
        }
    }

    func testRulesImmediatelyRevokeAllBranchesMapAndOverview() async throws {
        try await run { h in
            let row = h.fixture.caseNamed("rules-restrict")
            let relPath = try XCTUnwrap(row.relPath)
            let source = try h.source(relPath)
            let warm = try await h.pool(query: "RE-DE-2026-061")
            XCTAssertTrue(warm.vector.contains { $0.reference.sourceId == source.id })
            XCTAssertTrue(warm.lexical.contains { $0.reference.sourceId == source.id })
            await warm.close()

            let defaults = FolderRules.defaults
            let rules = FolderRules(includeExts: defaults.includeExts, ignoreGlobs: defaults.ignoreGlobs + [try XCTUnwrap(row.pattern)],
                                    limits: defaults.limits, encodingFallback: defaults.encodingFallback)
            try await h.scanner.applyRules(folderId: h.folderId, rules: rules, now: h.clock.now())
            // No scan/drain between applying rules and observing every surface.
            let after = try h.source(relPath)
            XCTAssertEqual(after.eligible, row.expected.eligible)
            XCTAssertEqual(after.availability, row.expected.availability)
            let pool = try await h.pool(query: "RE-DE-2026-061")
            XCTAssertEqual(pool.vector.contains { $0.reference.sourceId == source.id }, row.expected.vectorIncludes)
            XCTAssertEqual(pool.lexical.contains { $0.reference.sourceId == source.id }, row.expected.lexicalIncludes)
            await pool.close()
            let answer = try await h.prepare()
            XCTAssertFalse(answer.request.citationMap.contains { $0.sourceId == source.id })
            XCTAssertEqual(answer.request.coverage.corpus.searchable, row.expected.searchable)
            XCTAssertEqual(answer.request.messages.flatMap(\.sections).filter { $0.kind == "map" }
                .contains { $0.text.contains(relPath) }, row.expected.mapIncludes)
            let overview = try await h.prepare(mode: "overview")
            XCTAssertEqual(overview.request.citationMap.contains { $0.sourceId == source.id }, row.expected.overviewIncludes)
            XCTAssertEqual(overview.request.coverage.corpus.searchable, row.expected.searchable)
            // A stale explicit selection of the excluded file never broadens scope.
            let only = try await h.prepare(scope: .selection(sourceIds: [try XCTUnwrap(source.id)], folderIds: []))
            XCTAssertTrue(only.request.citationMap.isEmpty)
            XCTAssertFalse(only.request.messages.flatMap(\.sections).contains { $0.kind == "evidence" })
        }
    }
}

import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private actor RevisionClaimBarrier {
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    func arrive() async {
        await withCheckedContinuation { continuation in
            arrivals.append(continuation)
            if arrivals.count == 2 {
                for arrival in arrivals { arrival.resume() }
                arrivals.removeAll()
            }
        }
    }
}

@MainActor
final class RevisionJobTests: XCTestCase {
    func testFencedPublicationAndScalarSpans() throws {
        let c = try fixture("scalar-spans")
        let store = try seeded(c)
        let sourceID = try number(c, "sourceId")
        let now = try number(c, "now")
        let token = try XCTUnwrap(c["leaseToken"] as? String)
        let revision = try store.insertRevision(sourceId: sourceID, draft: draft(XCTUnwrap(c["draft"] as? [String: Any])), now: now)
        let jobID = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(sourceID)", targetRevision: revision.id), now: now)
        let lease = try XCTUnwrap(store.claimJob(now: now, leaseToken: token, id: jobID))
        XCTAssertEqual(lease.attempts, 1)
        let chunks = try XCTUnwrap(c["chunks"] as? [[String: Any]]).map(chunk)
        XCTAssertFalse(try store.publishRevision(sourceId: sourceID, revisionId: revision.id, chunks: chunks,
                                                fence: JobFence(jobId: jobID, leaseToken: "stale"), now: now))
        XCTAssertTrue(try store.publishRevision(sourceId: sourceID, revisionId: revision.id, chunks: chunks,
                                               fence: JobFence(jobId: jobID, leaseToken: token), now: now))
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        XCTAssertEqual(revision.id, try number(expected, "revisionId"))
        XCTAssertEqual(revision.draft.canonicalText.unicodeScalars.count, expected["scalarCount"] as? Int)
        XCTAssertEqual(try store.job(id: jobID)?.state, expected["jobState"] as? String)
        try store.runOnDatabase { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT text FROM source_chunks WHERE revision_id=?", arguments: [revision.id]), c["chunkText"] as? String)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM source_chunks WHERE revision_id=?", arguments: [revision.id]), expected["chunkCount"] as? Int)
        }
    }

    func testLeaseTimelineAndBackoff() throws {
        try runJobTimeline(fixture("lease-timeline"))
        try runExtraction(fixture("renew-running-extraction"))
        let c = try fixture("renew-running-extraction")
        let store = try seeded(c)
        let sourceID = try number(c, "sourceId")
        let events = try XCTUnwrap(c["events"] as? [[String: Any]])
        let begin = try XCTUnwrap(events.first)
        let commit = try XCTUnwrap(events.last)
        let fence = try store.beginExtraction(sourceId: sourceID, now: number(begin, "at"), leaseToken: XCTUnwrap(begin["token"] as? String))
        let withoutRenewal = try XCTUnwrap(c["withoutRenewal"] as? [String: Any])
        XCTAssertNil(try store.commitExtraction(sourceId: sourceID, draft: draft(XCTUnwrap(commit["draft"] as? [String: Any])),
                    chunks: XCTUnwrap(commit["chunks"] as? [[String: Any]]).map(chunk), fence: fence, now: number(withoutRenewal, "commitAt")))
        try store.runOnDatabase { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM source_revisions WHERE id<>101"), withoutRenewal["newRevisionCount"] as? Int)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT published_revision_id FROM sources WHERE id=?", arguments: [sourceID]), try number(withoutRenewal, "publishedRevisionId"))
        }
    }

    func testLeaseExpiryAndExhaustion() throws {
        for name in ["token-fence", "expiry-fence", "exhaustion", "expired-fifth"] {
            try runJobTimeline(fixture(name))
        }
    }

    func testPauseResumeCancelAndOrdering() throws {
        try runJobTimeline(fixture("pause-resume-cancel"))
        let c = try fixture("claim-order")
        let store = try seeded(c)
        for value in try XCTUnwrap(c["jobs"] as? [[String: Any]]) {
            let jobID = try store.enqueueJob(jobDraft(value), now: number(value, "nextRetryAt"))
            XCTAssertEqual(jobID, try number(value, "id"))
        }
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        let snapshots = try XCTUnwrap(expected["snapshots"] as? [[String: Any]])
        let events = try XCTUnwrap(c["events"] as? [[String: Any]])
        XCTAssertEqual(snapshots.count, events.count)
        var claimed: [Int64] = []
        for (event, snapshot) in zip(events, snapshots) {
            XCTAssertEqual(event["op"] as? String, "claim")
            let job = try XCTUnwrap(store.claimJob(now: number(event, "at"), leaseToken: XCTUnwrap(event["token"] as? String)))
            claimed.append(job.id)
            XCTAssertEqual(job.id, try number(snapshot, "jobId"))
            assertJob(job, expected: snapshot, result: true)
        }
        XCTAssertEqual(claimed, try XCTUnwrap(expected["claimedJobIds"] as? [NSNumber]).map(\.int64Value))

        // A pause/resume cycle retains a future deadline and never refunds an attempt.
        let later = try XCTUnwrap((c["jobs"] as? [[String: Any]])?.first)
        let jobID = try number(later, "id")
        let original = try XCTUnwrap(store.job(id: jobID))
        try store.pauseJob(id: jobID)
        let now = try number(XCTUnwrap(events.first), "at")
        try store.resumeJob(id: jobID, now: now)
        XCTAssertEqual(try store.job(id: jobID)?.nextRetryAt, original.nextRetryAt)
        XCTAssertNil(try store.claimJob(now: now, leaseToken: "before-deadline", id: jobID))
        XCTAssertEqual(try store.job(id: jobID)?.attempts, original.attempts)
    }

    func testImmutableRevisionAndRollback() throws {
        let c = try fixture("immutable")
        let store = try seeded(c)
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        let revisionID = try number(expected, "revisionId")
        let before = try XCTUnwrap(store.revision(id: revisionID))
        try store.runOnDatabase { db in
            XCTAssertThrowsError(try db.execute(sql: XCTUnwrap(c["sql"] as? String))) { error in
                XCTAssertTrue(String(describing: error).contains(c["expectedSqlError"] as? String ?? ""))
            }
            XCTAssertThrowsError(try db.execute(sql: "UPDATE source_chunks SET char_start=1 WHERE revision_id=?", arguments: [revisionID]))
            try db.execute(sql: "UPDATE source_chunks SET context='derived metadata' WHERE revision_id=?", arguments: [revisionID])
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT context FROM source_chunks WHERE revision_id=?", arguments: [revisionID]), "derived metadata")
        }
        XCTAssertEqual(try store.revision(id: revisionID), before)
        XCTAssertEqual(before.draft.canonicalText, expected["canonicalText"] as? String)
        for name in ["publish-rollback", "invalid-span-range", "invalid-span-order", "invalid-span-null", "invalid-span-text", "wrong-source"] {
            try runPublication(fixture(name))
        }
        let rollback = try fixture("publish-rollback")
        let foreground = try seeded(rollback)
        let old = try foreground.runOnDatabase { db in try Row.fetchAll(db, sql: "SELECT * FROM source_revisions ORDER BY id") }
        assertError(try XCTUnwrap(rollback["expectedError"] as? String)) {
            _ = try foreground.commitForegroundRevision(sourceId: number(rollback, "sourceId"),
                draft: draft(XCTUnwrap(rollback["draft"] as? [String: Any])), chunks: XCTUnwrap(rollback["chunks"] as? [[String: Any]]).map(chunk),
                now: number(rollback, "now"), leaseToken: XCTUnwrap(rollback["leaseToken"] as? String))
        }
        try foreground.runOnDatabase { db in
            XCTAssertEqual(try Row.fetchAll(db, sql: "SELECT * FROM source_revisions ORDER BY id"), old)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM ingest_jobs"), 0)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT current_revision FROM sources WHERE id=1"), revisionID)
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT published_revision_id FROM sources WHERE id=1"), revisionID)
        }
    }

    func testEmptyAndStalePublication() throws {
        for name in ["empty-publication", "old-chunks-retained", "stale-revision-publication", "revision-not-current", "double-publish"] {
            try runPublication(fixture(name))
        }
        try runExtraction(fixture("superseded-extraction"))
    }

    func testRestartReclaim() throws {
        let c = try fixture("restart-reclaim")
        let (store, directory) = try seededFile(c)
        defer { try? FileManager.default.removeItem(at: directory) }
        try runJobTimeline(c, initialStore: store, url: directory.appendingPathComponent("db.sqlite"))
    }

    func testTwoConnectionsClaimOnce() async throws {
        let c = try fixture("two-connections-single-claim")
        let (store, directory) = try seededFile(c)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jobID = try store.enqueueJob(jobDraft(c), now: number(c, "enqueueAt"))
        try store.dbQueue.close()
        let path = directory.appendingPathComponent("db.sqlite").path
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        let first = try DatabaseQueue(path: path, configuration: configuration)
        let second = try DatabaseQueue(path: path, configuration: configuration)
        defer { try? first.close(); try? second.close() }
        let events = try XCTUnwrap(c["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(c["synchronization"] as? String, "release-both-connections-before-claim")
        let nowA = try number(events[0], "at"), nowB = try number(events[1], "at")
        let tokenA = try XCTUnwrap(events[0]["token"] as? String), tokenB = try XCTUnwrap(events[1]["token"] as? String)
        let barrier = RevisionClaimBarrier()
        let a = Task.detached {
            await barrier.arrive()
            return try await first.write { db in try RevisionJobSQL.claimJob(db, now: nowA, leaseToken: tokenA, id: jobID) }
        }
        let b = Task.detached {
            await barrier.arrive()
            return try await second.write { db in try RevisionJobSQL.claimJob(db, now: nowB, leaseToken: tokenB, id: jobID) }
        }
        let claimed = try await [a.value, b.value].compactMap { $0 }
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        XCTAssertEqual(claimed.count, expected["successfulClaims"] as? Int)
        let winner = try XCTUnwrap(claimed.first)
        XCTAssertEqual(winner.attempts, expected["attempts"] as? Int)
        XCTAssertEqual(winner.state, expected["state"] as? String)
        XCTAssertEqual(winner.nextRetryAt, (expected["nextRetryAt"] as? NSNumber)?.int64Value)
        XCTAssertEqual(winner.leaseUntil, try number(expected, "leaseUntil"))
        XCTAssertTrue(try XCTUnwrap(expected["winningTokens"] as? [String]).contains(XCTUnwrap(winner.leaseToken)))
        let persisted = try await first.read { db -> (Int, String, String) in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT attempts,state,lease_token FROM ingest_jobs WHERE id=?", arguments: [jobID]))
            return (row["attempts"], row["state"], row["lease_token"])
        }
        XCTAssertEqual(persisted.0, winner.attempts)
        XCTAssertEqual(persisted.1, winner.state)
        XCTAssertEqual(persisted.2, winner.leaseToken)
    }

    private func runPublication(_ c: [String: Any]) throws {
        XCTAssertEqual(c["operation"] as? String, "publish")
        let store = try seeded(c)
        let sourceID = try number(c, "sourceId")
        let now = try number(c, "now")
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        var revisionID = (c["revisionId"] as? NSNumber)?.int64Value
        var supersedingDrafts: [RevisionDraft] = []
        if let drafts = c["revisionDrafts"] as? [[String: Any]] {
            revisionID = try number(c, "publishRevisionId")
            var reachedTarget = false
            for value in drafts {
                let value = try draft(value)
                if reachedTarget { supersedingDrafts.append(value) }
                else {
                    reachedTarget = try store.insertRevision(sourceId: sourceID, draft: value, now: now).id == revisionID
                }
            }
        } else if let value = c["draft"] as? [String: Any] {
            revisionID = try store.insertRevision(sourceId: sourceID, draft: draft(value), now: now).id
        }
        let revision = try XCTUnwrap(revisionID)
        let owner = (c["jobSourceId"] as? NSNumber)?.int64Value ?? sourceID
        let jobID = try store.enqueueJob(IngestJobDraft(kind: "extract", target: c["target"] as? String ?? "source:\(owner)",
                                targetRevision: (c["targetRevision"] as? NSNumber)?.int64Value ?? revision), now: now)
        let token = try XCTUnwrap(c["leaseToken"] as? String)
        _ = try XCTUnwrap(store.claimJob(now: now, leaseToken: token, id: jobID))
        // These fixtures exercise a revision superseded during a running publication.
        // A target already stale at claim is now cancelled before an attempt starts.
        for value in supersedingDrafts {
            _ = try store.insertRevision(sourceId: sourceID, draft: value, now: now)
        }
        let chunks = try XCTUnwrap(c["chunks"] as? [[String: Any]]).map(chunk)
        let fence = JobFence(jobId: jobID, leaseToken: token)
        if let error = c["expectedError"] as? String {
            assertError(error) { _ = try store.publishRevision(sourceId: sourceID, revisionId: revision, chunks: chunks, fence: fence, now: now) }
        } else if let times = c["publishTimes"] as? [NSNumber] {
            let results = try times.map { try store.publishRevision(sourceId: sourceID, revisionId: revision, chunks: chunks, fence: fence, now: $0.int64Value) }
            XCTAssertEqual(results, expected["results"] as? [Bool])
        } else {
            XCTAssertEqual(try store.publishRevision(sourceId: sourceID, revisionId: revision, chunks: chunks, fence: fence, now: now), expected["result"] as? Bool ?? true)
        }
        if let state = expected["jobState"] as? String { XCTAssertEqual(try store.job(id: jobID)?.state, state) }
        let observed = (expected["observedSourceId"] as? NSNumber)?.int64Value ?? sourceID
        try store.runOnDatabase { db in
            if let current = expected["currentRevision"] as? NSNumber {
                XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT current_revision FROM sources WHERE id=?", arguments: [observed]), current.int64Value)
            }
            if let published = expected["publishedRevisionId"] as? NSNumber {
                XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT published_revision_id FROM sources WHERE id=?", arguments: [observed]), published.int64Value)
            }
            if let count = expected["chunkCount"] as? Int {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM source_chunks WHERE revision_id=?", arguments: [revision]), count)
            }
            if let visible = expected["visibleChunkIds"] as? [NSNumber] {
                XCTAssertEqual(try Int64.fetchAll(db, sql: "SELECT id FROM source_chunks WHERE revision_id=(SELECT published_revision_id FROM sources WHERE id=?) ORDER BY ord", arguments: [sourceID]), visible.map(\.int64Value))
            }
            if let texts = expected["visibleTexts"] as? [String] {
                XCTAssertEqual(try String.fetchAll(db, sql: "SELECT text FROM source_chunks WHERE revision_id=(SELECT published_revision_id FROM sources WHERE id=?) ORDER BY ord", arguments: [sourceID]), texts)
            }
            if let retained = expected["retainedChunkIds"] as? [NSNumber] {
                for id in retained {
                    XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT id FROM source_chunks WHERE id=?", arguments: [id.int64Value]), id.int64Value)
                }
            }
            if let sqlError = c["expectedSqlError"] as? String {
                XCTAssertThrowsError(try db.execute(sql: "UPDATE sources SET published_revision_id=? WHERE id=?", arguments: [revision, sourceID])) {
                    XCTAssertTrue(String(describing: $0).contains(sqlError))
                }
            }
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    private func runJobTimeline(_ c: [String: Any], initialStore: NotebookStore? = nil, url: URL? = nil) throws {
        XCTAssertEqual(c["operation"] as? String, "jobs")
        var store = try initialStore ?? seeded(c)
        defer { if url != nil { try? store.dbQueue.close() } }
        let jobID = try store.enqueueJob(jobDraft(c), now: number(c, "enqueueAt"))
        let events = try XCTUnwrap(c["events"] as? [[String: Any]])
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        let snapshots = try XCTUnwrap(expected["snapshots"] as? [[String: Any]])
        XCTAssertEqual(events.count, snapshots.count)
        var claims = 0
        for (event, snapshot) in zip(events, snapshots) {
            let at = try number(event, "at")
            let fence = JobFence(jobId: jobID, leaseToken: event["token"] as? String ?? "unused")
            var result = false
            func perform() throws -> Bool {
                switch try XCTUnwrap(event["op"] as? String) {
                case "claim":
                    let claimed = try store.claimJob(now: at, leaseToken: XCTUnwrap(event["token"] as? String), id: jobID)
                    if claimed != nil { claims += 1 }
                    return claimed != nil
                case "renew": return try store.renewJob(fence: fence, now: at)
                case "fail": return try store.failJob(fence: fence, error: XCTUnwrap(event["error"] as? String), now: at)
                case "complete": return try store.completeJob(fence: fence, now: at)
                case "retry": return try store.retryJob(id: jobID, now: at)
                case "recover": return try store.recoverExpiredJobs(now: at) > 0
                case "pause": try store.pauseJob(id: jobID); return true
                case "resume": try store.resumeJob(id: jobID, now: at); return true
                case "cancel": try store.cancelJob(id: jobID); return true
                case "publish":
                    return try store.publishRevision(sourceId: 1, revisionId: number(c, "targetRevision"), chunks: [], fence: fence, now: at)
                case "reopen":
                    try store.dbQueue.close()
                    store = try V19TestStore.reopen(at: XCTUnwrap(url), configuredKey: nil)
                    return true
                default: XCTFail("Unknown job event"); return false
                }
            }
            if let error = event["expectedError"] as? String {
                assertError(error) { result = try perform() }
            } else { result = try perform() }
            if event["op"] as? String == "claim", result {
                // Extract jobs cannot be completed without atomically publishing their chunks.
                assertError("invalidValue") { _ = try store.completeJob(fence: fence, now: at) }
            }
            if event["op"] as? String == "renew", !result {
                XCTAssertFalse(try store.cancelJob(fence: fence, now: at))
            }
            if event["op"] as? String == "fail", result {
                try store.runOnDatabase { db in
                    XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM sources WHERE id=1"), "error")
                    XCTAssertEqual(try String.fetchOne(db, sql: "SELECT error FROM sources WHERE id=1"), event["error"] as? String)
                    XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT published_revision_id FROM sources WHERE id=1"), try number(c, "targetRevision"))
                }
            }
            assertJob(try XCTUnwrap(store.job(id: jobID)), expected: snapshot, result: result)
        }
        if let expectedClaims = c["expectedClaims"] as? Int { XCTAssertEqual(claims, expectedClaims) }
        if let published = c["expectedPublishedRevisionId"] as? NSNumber {
            try store.runOnDatabase { db in
                XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT published_revision_id FROM sources WHERE id=1"), published.int64Value)
            }
        }
    }

    private func runExtraction(_ c: [String: Any]) throws {
        XCTAssertEqual(c["operation"] as? String, "extraction")
        let store = try seeded(c)
        let sourceID = try number(c, "sourceId")
        try store.runOnDatabase { db in
            try db.execute(sql: "UPDATE sources SET status='error',error='previous refresh failure' WHERE id=?", arguments: [sourceID])
        }
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        let events = try XCTUnwrap(c["events"] as? [[String: Any]])
        let snapshots = try XCTUnwrap(expected["snapshots"] as? [[String: Any]])
        XCTAssertEqual(events.count, snapshots.count)
        var fences: [String: JobFence] = [:]
        for (event, snapshot) in zip(events, snapshots) {
            let token = try XCTUnwrap(event["token"] as? String)
            let now = try number(event, "at")
            let op = try XCTUnwrap(event["op"] as? String)
            switch op {
            case "begin":
                fences[token] = try store.beginExtraction(sourceId: sourceID, now: now, leaseToken: token)
                try store.runOnDatabase { db in
                    XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM sources WHERE id=?", arguments: [sourceID]), "chunking")
                    XCTAssertNil(try String.fetchOne(db, sql: "SELECT error FROM sources WHERE id=?", arguments: [sourceID]))
                }
            case "renew":
                XCTAssertEqual(try store.renewJob(fence: XCTUnwrap(fences[token]), now: now), snapshot["result"] as? Bool)
            case "commit":
                let revision = try store.commitExtraction(sourceId: sourceID, draft: draft(XCTUnwrap(event["draft"] as? [String: Any])),
                    chunks: XCTUnwrap(event["chunks"] as? [[String: Any]]).map(chunk), fence: XCTUnwrap(fences[token]), now: now)
                XCTAssertEqual(revision?.id, (snapshot["result"] as? NSNumber)?.int64Value)
                if revision == nil {
                    XCTAssertFalse(try store.failJob(fence: XCTUnwrap(fences[token]), error: "stale failure", now: now))
                    XCTAssertFalse(try store.cancelJob(fence: XCTUnwrap(fences[token]), now: now))
                }
                try store.runOnDatabase { db in
                    XCTAssertEqual(try String.fetchOne(db, sql: "SELECT status FROM sources WHERE id=?", arguments: [sourceID]), "ready")
                    XCTAssertNil(try String.fetchOne(db, sql: "SELECT error FROM sources WHERE id=?", arguments: [sourceID]))
                }
            default: XCTFail("Unknown extraction event")
            }
            if let states = snapshot["jobStates"] as? [String: String] {
                for (key, state) in states { XCTAssertEqual(try store.job(id: XCTUnwrap(fences[key]).jobId)?.state, state) }
            } else {
                let job = try XCTUnwrap(store.job(id: XCTUnwrap(fences[token]).jobId))
                assertJob(job, expected: snapshot, result: nil)
            }
            try store.runOnDatabase { db in
                if let current = snapshot["currentRevision"] as? NSNumber {
                    XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT current_revision FROM sources WHERE id=?", arguments: [sourceID]), current.int64Value)
                }
                if let published = snapshot["publishedRevisionId"] as? NSNumber {
                    XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT published_revision_id FROM sources WHERE id=?", arguments: [sourceID]), published.int64Value)
                }
            }
        }
        try store.runOnDatabase { db in
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT current_revision FROM sources WHERE id=?", arguments: [sourceID]), try number(expected, "currentRevision"))
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT published_revision_id FROM sources WHERE id=?", arguments: [sourceID]), try number(expected, "publishedRevisionId"))
            if let text = expected["publishedText"] as? String {
                XCTAssertEqual(try String.fetchOne(db, sql: "SELECT canonical_text FROM source_revisions WHERE id=(SELECT published_revision_id FROM sources WHERE id=?)", arguments: [sourceID]), text)
            }
            if let count = expected["newRevisionCount"] as? Int {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM source_revisions WHERE source_id=? AND id<>101", arguments: [sourceID]), count)
            }
        }
    }

    private func assertJob(_ job: IngestJob, expected: [String: Any], result: Bool?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(job.state, expected["state"] as? String, file: file, line: line)
        XCTAssertEqual(job.attempts, expected["attempts"] as? Int, file: file, line: line)
        XCTAssertEqual(job.nextRetryAt, (expected["nextRetryAt"] as? NSNumber)?.int64Value, file: file, line: line)
        XCTAssertEqual(job.leaseUntil, (expected["leaseUntil"] as? NSNumber)?.int64Value, file: file, line: line)
        XCTAssertEqual(job.leaseToken, expected["leaseToken"] as? String, file: file, line: line)
        if expected.keys.contains("error") { XCTAssertEqual(job.error, expected["error"] as? String, file: file, line: line) }
        if let result { XCTAssertEqual(result, expected["result"] as? Bool, file: file, line: line) }
    }

    private func assertError(_ expected: String, file: StaticString = #filePath, line: UInt = #line, _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual(($0 as? StorageV19Error)?.code, expected, file: file, line: line)
        }
    }

    private func jobDraft(_ value: [String: Any]) throws -> IngestJobDraft {
        IngestJobDraft(kind: try XCTUnwrap(value["kind"] as? String), target: try XCTUnwrap(value["target"] as? String),
                       targetRevision: (value["targetRevision"] as? NSNumber)?.int64Value)
    }

    private func seededFile(_ c: [String: Any]) throws -> (NotebookStore, URL) {
        let store = try seeded(c)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let url = directory.appendingPathComponent("db.sqlite")
            let queue = try DatabaseQueue(path: url.path)
            try store.dbQueue.backup(to: queue)
            try queue.close()
            try store.dbQueue.close()
            return (try V19TestStore.reopen(at: url, configuredKey: nil), directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let root = try SharedFixtures.json("contracts/storage-jobs-revisions-v1.json")
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let names: Set<String> = ["scalar-spans", "immutable", "empty-publication", "old-chunks-retained", "wrong-source",
            "stale-revision-publication", "revision-not-current", "publish-rollback", "double-publish", "invalid-span-range",
            "invalid-span-order", "invalid-span-null", "invalid-span-text", "superseded-extraction", "renew-running-extraction",
            "lease-timeline", "token-fence", "expiry-fence", "exhaustion", "expired-fifth", "pause-resume-cancel", "claim-order",
            "restart-reclaim", "two-connections-single-claim"]
        XCTAssertEqual(Set(cases.compactMap { $0["name"] as? String }), names)
        XCTAssertEqual(Set(cases.compactMap { $0["operation"] as? String }), ["publish", "revision-update", "extraction", "jobs"])
        return try RetryCapSupersession.apply(XCTUnwrap(cases.first { $0["name"] as? String == name }, name),
                                              fixture: "storage-jobs-revisions-v1.json")
    }

    private func seeded(_ c: [String: Any]) throws -> NotebookStore {
        let store = try V19TestStore.make()
        try store.runOnDatabase { db in
            for sql in try XCTUnwrap(c["setupSql"] as? [String]) { try db.execute(sql: sql) }
        }
        return store
    }

    private func number(_ value: [String: Any], _ key: String) throws -> Int64 {
        try XCTUnwrap(value[key] as? NSNumber, key).int64Value
    }

    private func draft(_ value: [String: Any]) throws -> RevisionDraft {
        RevisionDraft(contentHash: try XCTUnwrap(value["contentHash"] as? String), canonicalText: try XCTUnwrap(value["canonicalText"] as? String),
                      textFormatVersion: try XCTUnwrap(value["textFormatVersion"] as? Int), chunkerVersion: try XCTUnwrap(value["chunkerVersion"] as? Int))
    }

    private func chunk(_ value: [String: Any]) throws -> RevisionChunkDraft {
        RevisionChunkDraft(text: try XCTUnwrap(value["text"] as? String), tokenCount: try XCTUnwrap(value["tokenCount"] as? Int),
                           pageHint: value["pageHint"] as? Int, charStart: value["charStart"] as? Int, charEnd: value["charEnd"] as? Int,
                           lang: value["lang"] as? String, langInherited: try XCTUnwrap(value["langInherited"] as? Bool))
    }
}

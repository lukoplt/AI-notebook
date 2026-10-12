import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

@MainActor
final class JobTransitionContractTests: XCTestCase {
    func testEveryFrozenJobTransitionAgainstStore() throws {
        let contract = try JSONDecoder().decode(TransitionContract.self,
            from: RetryCapSupersession.data("job-transitions-v1.json"))
        XCTAssertEqual(contract.contract, "job-transitions")
        XCTAssertEqual(contract.version, 1)
        XCTAssertEqual(contract.cases.count, 21)
        let expectedNames: Set<String> = [
            "first-start-increments-attempts", "second-start-increments-once", "fifth-attempt-may-start",
            "failure-backoff-from-started-count", "fourth-failure-backoff-480-seconds", "fifth-failure-terminal",
            "failed-retry-before-backoff-rejected", "failed-retry-at-backoff-no-increment", "exhausted-failure-cannot-retry",
            "expiry-backoff-without-increment", "fifth-expiry-terminal", "live-lease-cannot-expire",
            "renew-after-60-seconds-no-increment", "expired-worker-cannot-renew", "replaced-worker-cannot-renew",
            "replaced-worker-cannot-publish", "replaced-worker-cannot-fail-replacement", "expired-worker-cannot-publish",
            "replacement-publishes-with-current-token", "superseded-revision-cancels-current-worker",
            "queued-cannot-start-before-backoff"
        ]
        var visited: Set<String> = []
        for fixture in contract.cases {
            XCTAssertTrue(visited.insert(fixture.name).inserted, fixture.name)
            try XCTContext.runActivity(named: fixture.name) { _ in
                try run(fixture)
            }
        }
        XCTAssertEqual(visited, expectedNames)
    }

    private func run(_ fixture: TransitionCase) throws {
        let store = try V19TestStore.make()
        let input = fixture.input.job
        let event = fixture.input.event
        try store.runOnDatabase { db in
            try db.execute(sql: """
                INSERT INTO notebooks(id,name,created_at,updated_at)
                VALUES(1,'transitions','2026-01-02 03:04:05.000','2026-01-02 03:04:05.000');
                INSERT INTO sources(id,notebook_id,type,title,status,ingested_at)
                VALUES(1,1,'text','transition source','pending','2026-01-02 03:04:05.000');
                INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                VALUES(11,1,1,'revision-11','',1,2,'2026-01-02 03:04:05.000');
                UPDATE sources SET current_revision=11 WHERE id=1;
                """)
            try db.execute(sql: """
                INSERT INTO ingest_jobs(id,kind,target,target_revision,state,attempts,next_retry_at,lease_until,lease_token)
                VALUES(1,'extract','source:1',?,?,?,?,?,?)
                """, arguments: [input.targetRevision, input.state, input.attempts, input.nextRetryAt,
                                    input.leaseUntil, input.leaseToken])
            if let requested = event.requestedRevision, requested != input.targetRevision {
                try db.execute(sql: """
                    INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES(?,1,2,'replacement','',1,2,'2026-01-02 03:04:05.000')
                    """, arguments: [requested])
                try db.execute(sql: "UPDATE sources SET current_revision=? WHERE id=1", arguments: [requested])
            }
        }

        let fence = JobFence(jobId: 1, leaseToken: event.leaseToken ?? "unused")
        let accepted: Bool
        var published = false
        switch event.kind {
        case "start":
            accepted = try store.claimJob(now: event.now, leaseToken: XCTUnwrap(event.leaseToken), id: 1) != nil
        case "fail":
            accepted = try store.failJob(fence: fence, error: "fixture failure", now: event.now)
        case "retry":
            accepted = try store.retryJob(id: 1, now: event.now)
        case "expire":
            accepted = try store.recoverExpiredJobs(now: event.now) > 0
        case "renew":
            accepted = try store.renewJob(fence: fence, now: event.now)
        case "publish":
            published = try store.publishRevision(sourceId: 1, revisionId: XCTUnwrap(input.targetRevision),
                chunks: [], fence: fence, now: event.now)
            // A live owner accepts a superseded completion by cancelling it, without publishing.
            let completionState = try store.job(id: 1)?.state
            accepted = published || completionState == "cancelled"
        default:
            XCTFail("Unknown frozen job event: \(event.kind)")
            return
        }

        let job = try XCTUnwrap(store.job(id: 1))
        let snapshot = JobSnapshot(state: job.state, attempts: job.attempts, nextRetryAt: job.nextRetryAt,
            leaseUntil: job.leaseUntil, leaseToken: job.leaseToken, targetRevision: job.draft.targetRevision)
        XCTAssertEqual(snapshot, fixture.expected.job)
        XCTAssertEqual(accepted, fixture.expected.accepted)
        XCTAssertEqual(published, fixture.expected.published)
        try store.runOnDatabase { db in
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT published_revision_id FROM sources WHERE id=1"),
                fixture.expected.published ? input.targetRevision : nil)
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }
}

private struct TransitionContract: Decodable {
    let contract: String
    let version: Int
    let cases: [TransitionCase]
}

private struct TransitionCase: Decodable {
    let name: String
    let input: TransitionInput
    let expected: TransitionExpected
}

private struct TransitionInput: Decodable {
    let job: JobSnapshot
    let event: TransitionEvent
}

private struct TransitionEvent: Decodable {
    let kind: String
    let now: Int64
    let leaseToken: String?
    let requestedRevision: Int64?
}

private struct TransitionExpected: Decodable {
    let job: JobSnapshot
    let accepted: Bool
    let published: Bool
}

private struct JobSnapshot: Decodable, Equatable {
    let state: String
    let attempts: Int
    let nextRetryAt: Int64?
    let leaseUntil: Int64?
    let leaseToken: String?
    let targetRevision: Int64?
}

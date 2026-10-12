import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

@MainActor
final class JobHandoffContractTests: XCTestCase {
    func testEverySharedJobHandoffTraceAgainstStore() throws {
        let contract = try JSONDecoder().decode(HandoffContract.self,
            from: RetryCapSupersession.data("storage-job-handoff-v1.json"))
        XCTAssertEqual(contract.contract, "storage-job-handoff")
        XCTAssertEqual(contract.version, 1)
        var expectedNames: Set<String> = [
            "failure-due-retry-claim", "stale-claim-preserves-newer-error",
            "stale-due-retry-preserves-newer-error", "options-upgrade-freezes-at-first-claim",
            "notebook-bootstrap-retarget-complete", "notebook-orphan-claim-cancels",
            "initial-retry", "stale-initial-claim", "stale-initial-due-retry",
            "notebook-bootstrap-atomic-complete",
            "newer-job-cancels-initial-claim", "newer-job-cancels-initial-retry",
            "newer-job-cancels-refresh-claim", "newer-job-cancels-refresh-retry"
        ]
        for mode in ["failure", "expiry"] {
            for source in ["initial", "refresh"] {
                for successor in ["current", "newer-revision", "newer-failed-job", "newer-running-job"] {
                    expectedNames.insert("terminal-\(mode)-\(source)-\(successor)")
                }
            }
        }
        for source in ["initial", "refresh"] {
            for successor in ["current", "newer-revision", "newer-failed-job", "newer-running-job"] {
                expectedNames.insert("nonterminal-expiry-\(source)-\(successor)")
            }
        }
        var visited: Set<String> = []
        for fixture in contract.cases {
            XCTAssertTrue(visited.insert(fixture.name).inserted, fixture.name)
            XCTAssertEqual(fixture.operation, "trace", fixture.name)
            try XCTContext.runActivity(named: fixture.name) { _ in
                try run(fixture, setupSQL: contract.setupSql)
            }
        }
        XCTAssertEqual(visited, expectedNames)
    }

    private func run(_ fixture: HandoffCase, setupSQL: [String]) throws {
        let store = try V19TestStore.make()
        try store.runOnDatabase { db in
            for sql in setupSQL + (fixture.setupSql ?? []) { try db.execute(sql: sql) }
        }
        let draft = fixture.input.draft
        let id = try store.enqueueJob(IngestJobDraft(kind: draft.kind, target: draft.target,
            targetRevision: draft.targetRevision, optionsJSON: draft.optionsJSON), now: fixture.input.enqueueAt)
        XCTAssertEqual(fixture.input.events.count, fixture.expected.snapshots.count)
        for (index, pair) in zip(fixture.input.events, fixture.expected.snapshots).enumerated() {
            let (event, expected) = pair
            let label = "\(fixture.name) event \(index): \(event.op)"
            let fence = JobFence(jobId: id, leaseToken: event.token ?? "unused")
            let accepted: Bool
            var requeuedCount: Int?
            var recoveredCount: Int?
            switch event.op {
            case "claim":
                accepted = try store.claimJob(now: event.at, leaseToken: XCTUnwrap(event.token), id: id) != nil
            case "fail":
                accepted = try store.failJob(fence: fence, error: XCTUnwrap(event.error), now: event.at)
            case "requeue":
                let count = try store.requeueRetryableJobs(now: event.at)
                requeuedCount = count
                accepted = count > 0
            case "retry":
                accepted = try store.retryJob(id: id, now: event.at)
            case "recover":
                let count = try store.recoverExpiredJobs(now: event.at)
                recoveredCount = count
                accepted = count > 0
            case "updateOptions":
                accepted = try store.updateQueuedJobOptions(id: id, optionsJSON: XCTUnwrap(event.optionsJSON))
            case "retarget":
                accepted = try store.retargetEmbedJob(fence: fence,
                    generationId: XCTUnwrap(event.generationId), now: event.at)
            case "complete":
                accepted = try store.completeJob(fence: fence, now: event.at, targetGenerationId: event.generationId)
            case "setSourceError":
                accepted = try store.dbQueue.write { db in
                    try db.execute(sql: "UPDATE sources SET status='error',error=? WHERE id=?",
                        arguments: [try XCTUnwrap(event.error), try XCTUnwrap(event.sourceId)])
                    return db.changesCount == 1
                }
            case "supersedeSource":
                let sourceId = try XCTUnwrap(event.sourceId)
                _ = try store.insertRevision(sourceId: sourceId,
                    draft: RevisionDraft(contentHash: XCTUnwrap(event.contentHash),
                        canonicalText: XCTUnwrap(event.canonicalText), textFormatVersion: 1, chunkerVersion: 2),
                    now: event.at)
                accepted = try store.dbQueue.write { db in
                    try db.execute(sql: "UPDATE sources SET status='error',error=? WHERE id=?",
                        arguments: [try XCTUnwrap(event.error), sourceId])
                    return db.changesCount == 1
                }
            case "supersedeJob":
                let successor = try store.enqueueJob(IngestJobDraft(kind: draft.kind, target: draft.target,
                    targetRevision: draft.targetRevision, optionsJSON: draft.optionsJSON), now: event.at)
                let token = try XCTUnwrap(event.token)
                _ = try XCTUnwrap(store.claimJob(now: event.at, leaseToken: token, id: successor))
                if let error = event.error {
                    XCTAssertTrue(try store.failJob(fence: JobFence(jobId: successor, leaseToken: token),
                        error: error, now: event.at), label)
                }
                accepted = true
            case "deleteNotebook":
                accepted = try store.dbQueue.write { db in
                    try db.execute(sql: "DELETE FROM notebooks WHERE id=?",
                        arguments: [try XCTUnwrap(event.notebookId)])
                    return db.changesCount == 1
                }
            default:
                XCTFail("Unknown shared handoff event: \(event.op)")
                return
            }

            let job = try XCTUnwrap(store.job(id: id))
            let actual = HandoffJobSnapshot(id: job.id, kind: job.draft.kind, target: job.draft.target,
                targetRevision: job.draft.targetRevision, optionsJSON: job.draft.optionsJSON,
                state: job.state, attempts: job.attempts, nextRetryAt: job.nextRetryAt,
                leaseUntil: job.leaseUntil, leaseToken: job.leaseToken, error: job.error)
            XCTAssertEqual(actual, expected.job, label)
            XCTAssertEqual(accepted, expected.accepted, label)
            XCTAssertEqual(requeuedCount, expected.requeuedCount, label)
            XCTAssertEqual(recoveredCount, expected.recoveredCount, label)
            try store.runOnDatabase { db in
                let row = try XCTUnwrap(Row.fetchOne(db,
                    sql: "SELECT id,status,error,current_revision,published_revision_id FROM sources WHERE id=?",
                    arguments: [expected.source.id]))
                let source = HandoffSourceSnapshot(id: row["id"], status: row["status"], error: row["error"],
                    currentRevision: row["current_revision"], publishedRevisionId: row["published_revision_id"])
                XCTAssertEqual(source, expected.source, label)
                XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty, label)
            }
        }
    }
}

private struct HandoffContract: Decodable {
    let contract: String
    let version: Int
    let setupSql: [String]
    let cases: [HandoffCase]
}

private struct HandoffCase: Decodable {
    let name: String
    let operation: String
    let setupSql: [String]?
    let input: HandoffInput
    let expected: HandoffExpected
}

private struct HandoffInput: Decodable {
    let enqueueAt: Int64
    let draft: HandoffDraft
    let events: [HandoffEvent]
}

private struct HandoffDraft: Decodable {
    let kind: String
    let target: String
    let targetRevision: Int64?
    let optionsJSON: String
}

private struct HandoffEvent: Decodable {
    let op: String
    let at: Int64
    let token: String?
    let error: String?
    let optionsJSON: String?
    let generationId: Int64?
    let sourceId: Int64?
    let notebookId: Int64?
    let contentHash: String?
    let canonicalText: String?
}

private struct HandoffExpected: Decodable {
    let snapshots: [HandoffSnapshot]
}

private struct HandoffSnapshot: Decodable {
    let accepted: Bool
    let requeuedCount: Int?
    let recoveredCount: Int?
    let job: HandoffJobSnapshot
    let source: HandoffSourceSnapshot
}

private struct HandoffJobSnapshot: Decodable, Equatable {
    let id: Int64
    let kind: String
    let target: String
    let targetRevision: Int64?
    let optionsJSON: String
    let state: String
    let attempts: Int
    let nextRetryAt: Int64?
    let leaseUntil: Int64?
    let leaseToken: String?
    let error: String?
}

private struct HandoffSourceSnapshot: Decodable, Equatable {
    let id: Int64
    let status: String
    let error: String?
    let currentRevision: Int64?
    let publishedRevisionId: Int64?
}

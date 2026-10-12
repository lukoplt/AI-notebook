import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

@MainActor
final class IngestJobHandoffTests: XCTestCase {
    func testFailureDueRetryAndClaimUpdateSourceAtomically() throws {
        let store = try seeded()
        let id = try store.enqueueJob(extract(), now: 0)
        _ = try XCTUnwrap(store.claimJob(now: 0, leaseToken: "first", id: id))
        XCTAssertTrue(try store.failJob(fence: JobFence(jobId: id, leaseToken: "first"), error: "extract failed", now: 10))
        XCTAssertEqual(try store.job(id: id)?.state, "failed")
        XCTAssertEqual(try store.job(id: id)?.nextRetryAt, 70)
        try assertSource(store, status: "error", error: "extract failed")
        XCTAssertEqual(try store.requeueRetryableJobs(now: 69), 0)
        try assertSource(store, status: "error", error: "extract failed")
        XCTAssertEqual(try store.requeueRetryableJobs(now: 70), 1)
        XCTAssertEqual(try store.job(id: id)?.state, "queued")
        XCTAssertEqual(try store.job(id: id)?.attempts, 1)
        XCTAssertEqual(try store.job(id: id)?.nextRetryAt, 70)
        try assertSource(store, status: "pending", error: nil)
        XCTAssertEqual(try store.requeueRetryableJobs(now: 70), 0)
        let claimed = try XCTUnwrap(store.claimJob(now: 70, leaseToken: "second", id: id))
        XCTAssertEqual(claimed.attempts, 2)
        XCTAssertNil(claimed.nextRetryAt)
        try assertSource(store, status: "chunking", error: nil)
    }

    func testRetryRollsBackJobWhenSourceUpdateFails() throws {
        let store = try seeded()
        let id = try store.enqueueJob(extract(), now: 0)
        _ = try store.claimJob(now: 0, leaseToken: "owner", id: id)
        _ = try store.failJob(fence: JobFence(jobId: id, leaseToken: "owner"), error: "failure", now: 10)
        let before = try store.job(id: id)
        try store.runOnDatabase { db in
            try db.execute(sql: "CREATE TRIGGER reject_pending BEFORE UPDATE OF status ON sources WHEN NEW.status='pending' BEGIN SELECT RAISE(ABORT,'rollback'); END")
        }
        XCTAssertThrowsError(try store.requeueRetryableJobs(now: 70))
        XCTAssertEqual(try store.job(id: id), before)
        try assertSource(store, status: "error", error: "failure")
    }

    func testStaleClaimAndRetryCancelWithoutClearingNewerFailure() throws {
        for staleAtRetry in [false, true] {
            let store = try seeded()
            let id = try store.enqueueJob(extract(), now: 0)
            if staleAtRetry {
                _ = try store.claimJob(now: 0, leaseToken: "owner", id: id)
                _ = try store.failJob(fence: JobFence(jobId: id, leaseToken: "owner"), error: "old failure", now: 10)
            }
            _ = try store.insertRevision(sourceId: 1, draft: RevisionDraft(contentHash: "new", canonicalText: "new", textFormatVersion: 1, chunkerVersion: 2), now: 20)
            try store.runOnDatabase { db in
                try db.execute(sql: "UPDATE sources SET status='error',error='new failure' WHERE id=1")
            }
            if staleAtRetry { XCTAssertEqual(try store.requeueRetryableJobs(now: 70), 0) }
            else { XCTAssertNil(try store.claimJob(now: 70, leaseToken: "stale", id: id)) }
            let cancelled = try XCTUnwrap(store.job(id: id))
            XCTAssertEqual(cancelled.state, "cancelled")
            XCTAssertEqual(cancelled.attempts, staleAtRetry ? 1 : 0)
            XCTAssertNil(cancelled.nextRetryAt)
            XCTAssertNil(cancelled.leaseToken)
            try assertSource(store, status: "error", error: "new failure")
        }
    }

    func testNullExpectedRevisionAndSingleRetryClearSourceError() throws {
        let store = try seeded()
        try store.runOnDatabase { db in try db.execute(sql: "UPDATE sources SET current_revision=NULL WHERE id=1") }
        let id = try store.enqueueJob(extract(revision: nil), now: 0)
        _ = try store.claimJob(now: 0, leaseToken: "owner", id: id)
        _ = try store.failJob(fence: JobFence(jobId: id, leaseToken: "owner"), error: "failure", now: 10)
        XCTAssertTrue(try store.retryJob(id: id, now: 70))
        try assertSource(store, status: "pending", error: nil)
        _ = try store.claimJob(now: 70, leaseToken: "next", id: id)
        try assertSource(store, status: "chunking", error: nil)
    }

    func testBulkRetryIgnoresTerminalFutureAndUnscheduledJobs() throws {
        let store = try seeded()
        try store.runOnDatabase { db in
            try db.execute(sql: """
                INSERT INTO ingest_jobs(kind,target,state,attempts,next_retry_at) VALUES
                    ('embed','notebook:1','failed',1,70),
                    ('embed','notebook:1','failed',4,70),
                    ('embed','notebook:1','failed',5,NULL),
                    ('embed','notebook:1','failed',1,NULL),
                    ('embed','notebook:1','failed',1,71),
                    ('embed','notebook:1','paused',1,70),
                    ('embed','notebook:1','done',1,NULL);
                """)
        }
        XCTAssertEqual(try store.requeueRetryableJobs(now: 70), 2)
        XCTAssertEqual(try (1...7).map { try store.job(id: Int64($0))?.state }, ["queued", "queued", "failed", "failed", "failed", "paused", "done"])
    }

    func testOptionsPersistAndFreezeAtFirstClaim() throws {
        let store = try seeded()
        let initial = #"{"verifyAll":false}"#
        let upgraded = #"{"verifyAll":true}"#
        let id = try store.enqueueJob(IngestJobDraft(kind: "scan", target: "folder:1", targetRevision: nil, optionsJSON: initial), now: 0)
        XCTAssertEqual(try store.job(id: id)?.draft.optionsJSON, initial)
        XCTAssertTrue(try store.updateQueuedJobOptions(id: id, optionsJSON: upgraded))
        try store.pauseJob(id: id)
        XCTAssertFalse(try store.updateQueuedJobOptions(id: id, optionsJSON: initial))
        try store.resumeJob(id: id, now: 0)
        let claimed = try XCTUnwrap(store.claimJob(now: 0, leaseToken: "owner", id: id))
        XCTAssertEqual(claimed.draft.optionsJSON, upgraded)
        XCTAssertFalse(try store.updateQueuedJobOptions(id: id, optionsJSON: initial))
        _ = try store.failJob(fence: JobFence(jobId: id, leaseToken: "owner"), error: "failure", now: 1)
        XCTAssertEqual(try store.requeueRetryableJobs(now: 61), 1)
        XCTAssertFalse(try store.updateQueuedJobOptions(id: id, optionsJSON: initial))
        XCTAssertEqual(try store.job(id: id)?.draft.optionsJSON, upgraded)
    }

    func testOptionsRejectNonObjectsWithoutChangingQueuedJob() throws {
        let store = try seeded()
        let id = try store.enqueueJob(IngestJobDraft(kind: "embed", target: "notebook:1", targetRevision: nil), now: 0)
        for invalid in ["", "[]", "null", "1", "{invalid}"] {
            XCTAssertThrowsError(try store.updateQueuedJobOptions(id: id, optionsJSON: invalid))
            XCTAssertThrowsError(try store.enqueueJob(IngestJobDraft(kind: "embed", target: "notebook:1", targetRevision: nil, optionsJSON: invalid), now: 0))
        }
        XCTAssertEqual(try store.job(id: id)?.draft.optionsJSON, "{}")
    }

    func testBootstrapRetargetIsFencedAndKeepsRunningLeaseAndOptions() throws {
        let store = try seeded()
        let options = #"{"selection":{"providerId":"local","model":"embed","dims":null},"copyExisting":true}"#
        let id = try store.enqueueJob(IngestJobDraft(kind: "embed", target: "notebook:1", targetRevision: nil, optionsJSON: options), now: 0)
        let before = try XCTUnwrap(store.claimJob(now: 0, leaseToken: "owner", id: id))
        XCTAssertFalse(try store.retargetEmbedJob(fence: JobFence(jobId: id, leaseToken: "stale"), generationId: 1, now: 1))
        XCTAssertFalse(try store.retargetEmbedJob(fence: JobFence(jobId: id, leaseToken: "owner"), generationId: 1, now: 300))
        XCTAssertEqual(try store.job(id: id), before)
        XCTAssertThrowsError(try store.retargetEmbedJob(fence: JobFence(jobId: id, leaseToken: "owner"), generationId: 2, now: 1))
        XCTAssertEqual(try store.job(id: id), before)
        XCTAssertTrue(try store.retargetEmbedJob(fence: JobFence(jobId: id, leaseToken: "owner"), generationId: 1, now: 1))
        let after = try XCTUnwrap(store.job(id: id))
        XCTAssertEqual(after.draft.target, "generation:1")
        XCTAssertEqual(after.draft.optionsJSON, options)
        XCTAssertEqual(after.state, "running")
        XCTAssertEqual(after.attempts, before.attempts)
        XCTAssertEqual(after.leaseToken, before.leaseToken)
        XCTAssertEqual(after.leaseUntil, before.leaseUntil)
        XCTAssertTrue(try store.completeJob(fence: JobFence(jobId: id, leaseToken: "owner"), now: 2))
    }

    func testBootstrapCompletionCanRetargetAtomicallyOrFinishEmptyNotebook() throws {
        let store = try seeded()
        for target in [Int64(1), nil] {
            let id = try store.enqueueJob(IngestJobDraft(kind: "embed", target: "notebook:1", targetRevision: nil), now: 0)
            _ = try store.claimJob(now: 0, leaseToken: "owner-\(id)", id: id)
            let fence = JobFence(jobId: id, leaseToken: "owner-\(id)")
            XCTAssertTrue(try store.completeJob(fence: fence, now: 1, targetGenerationId: target))
            let completed = try XCTUnwrap(store.job(id: id))
            XCTAssertEqual(completed.state, "done")
            XCTAssertEqual(completed.draft.target, target == nil ? "notebook:1" : "generation:1")
            XCTAssertNil(completed.leaseToken)
        }
    }

    func testNotebookTargetValidationAndOrphanCancellation() throws {
        let store = try seeded()
        for target in ["notebook:0", "notebook:01", "notebook:-1", "notebook:1x", "notebook:9223372036854775808"] {
            XCTAssertThrowsError(try store.enqueueJob(IngestJobDraft(kind: "embed", target: target, targetRevision: nil), now: 0))
        }
        XCTAssertThrowsError(try store.enqueueJob(IngestJobDraft(kind: "gc", target: "notebook:1", targetRevision: nil), now: 0))
        XCTAssertThrowsError(try store.enqueueJob(IngestJobDraft(kind: "embed", target: "notebook:99", targetRevision: nil), now: 0))
        XCTAssertThrowsError(try store.enqueueJob(IngestJobDraft(kind: "embed", target: "notebook:2", targetRevision: 11), now: 0))
        let id = try store.enqueueJob(IngestJobDraft(kind: "embed", target: "notebook:2", targetRevision: nil), now: 0)
        try store.runOnDatabase { db in try db.execute(sql: "DELETE FROM notebooks WHERE id=2") }
        XCTAssertNil(try store.claimJob(now: 0, leaseToken: "orphan", id: id))
        XCTAssertEqual(try store.job(id: id)?.state, "cancelled")
        XCTAssertEqual(try store.job(id: id)?.attempts, 0)
    }

    private func extract(revision: Int64? = 11) -> IngestJobDraft {
        IngestJobDraft(kind: "extract", target: "source:1", targetRevision: revision)
    }

    private func assertSource(_ store: NotebookStore, status: String, error: String?, file: StaticString = #filePath, line: UInt = #line) throws {
        try store.runOnDatabase { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT status,error,published_revision_id FROM sources WHERE id=1"))
            XCTAssertEqual(row["status"] as String, status, file: file, line: line)
            XCTAssertEqual(row["error"] as String?, error, file: file, line: line)
            XCTAssertEqual(row["published_revision_id"] as Int64?, 11, file: file, line: line)
        }
    }

    private func seeded() throws -> NotebookStore {
        let store = try V19TestStore.make()
        try store.runOnDatabase { db in
            try db.execute(sql: """
                INSERT INTO notebooks(id,name,created_at,updated_at) VALUES(1,'one','2026-10-09','2026-10-09'),(2,'two','2026-10-09','2026-10-09');
                INSERT INTO sources(id,notebook_id,type,title,status,ingested_at) VALUES(1,1,'text','source','ready','2026-10-09');
                INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES(11,1,1,'old','old',1,2,'2026-10-09');
                UPDATE sources SET current_revision=11,published_revision_id=11 WHERE id=1;
                INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,created_at)
                    VALUES(1,1,'/docs','{"volumeId":"vol","components":["docs"],"rootFileId":"root-1"}','docs','[]','[]','{}','2026-10-09');
                INSERT INTO index_generations(id,notebook_id,provider_id,endpoint_revision,model,dims,normalization,query_format_version,doc_format_version,chunker_version,state,created_at)
                    VALUES(1,1,'local','endpoint','model',2,'l2','1','1','2','building','2026-10-09'),
                          (2,2,'local','endpoint','model',2,'l2','1','1','2','building','2026-10-09');
                """)
        }
        return store
    }
}

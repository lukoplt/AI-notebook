import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

/// Deterministic lease clock: waiters resume only when the test advances time.
private final class ManualClock: IngestLeaseClock, @unchecked Sendable {
    private let gate = NSLock()
    private var value: Int64
    private var waiters: [(id: UUID, deadline: Int64, continuation: CheckedContinuation<Void, Error>)] = []
    init(_ value: Int64) { self.value = value }
    func now() -> Int64 { gate.lock(); defer { gate.unlock() }; return value }
    var pendingWaits: Int { gate.lock(); defer { gate.unlock() }; return waiters.count }
    func advance(to next: Int64) {
        gate.lock()
        value = next
        let ready = waiters.filter { $0.deadline <= next }
        waiters.removeAll { $0.deadline <= next }
        gate.unlock()
        for waiter in ready { waiter.continuation.resume() }
    }
    func wait(until deadline: Int64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.lock()
                if Task.isCancelled { gate.unlock(); continuation.resume(throwing: CancellationError()); return }
                if deadline <= value { gate.unlock(); continuation.resume(); return }
                waiters.append((id, deadline, continuation))
                gate.unlock()
            }
        } onCancel: {
            gate.lock()
            let index = waiters.firstIndex { $0.id == id }
            let waiter = index.map { waiters.remove(at: $0) }
            gate.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}

/// Collects queue/test events and lets a test await a specific one.
private final class Events: @unchecked Sendable {
    private let gate = NSLock()
    private var values: [String] = []
    private var waiters: [(String, CheckedContinuation<Void, Never>)] = []
    func record(_ value: String) {
        gate.lock()
        values.append(value)
        let ready = waiters.filter { $0.0 == value }
        waiters.removeAll { $0.0 == value }
        gate.unlock()
        for waiter in ready { waiter.1.resume() }
    }
    var all: [String] { gate.lock(); defer { gate.unlock() }; return values }
    func next(_ value: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.lock()
            if values.contains(value) { gate.unlock(); continuation.resume(); return }
            waiters.append((value, continuation))
            gate.unlock()
        }
    }
}

/// A one-shot gate a blocked worker awaits.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func release() {
        lock.lock(); open = true; let ready = waiters; waiters = []; lock.unlock()
        for waiter in ready { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if open { lock.unlock(); continuation.resume(); return }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

/// Blocking two-party rendezvous for the cross-connection claim race.
private final class Barrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var arrived = 0
    private let parties: Int
    init(_ parties: Int) { self.parties = parties }
    func arriveAndWait() {
        condition.lock()
        arrived += 1
        if arrived >= parties { condition.broadcast() }
        while arrived < parties { condition.wait() }
        condition.unlock()
    }
}

private final class Tokens: @unchecked Sendable {
    private let gate = NSLock()
    private var queue: [String]
    private(set) var issued: [String] = []
    init(_ values: [String]) { queue = values }
    func next() -> String {
        gate.lock(); defer { gate.unlock() }
        let value = queue.removeFirst()
        issued.append(value)
        return value
    }
}

private final class ProviderRecorder: @unchecked Sendable {
    private let gate = NSLock()
    private var batches: [String] = []
    private var queries: [String] = []
    func batch(_ id: String) { gate.lock(); batches.append(id); gate.unlock() }
    /// The question embedding path never consults the admission gate.
    func query(_ text: String) { gate.lock(); queries.append(text); gate.unlock() }
    var started: [String] { gate.lock(); defer { gate.unlock() }; return batches }
    var inputs: [String] { gate.lock(); defer { gate.unlock() }; return queries }
    var calls: Int { gate.lock(); defer { gate.unlock() }; return batches.count + queries.count }
}

private func int64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
private func json(_ value: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
}
private func null(_ value: Any?) -> Any { value ?? NSNull() }

/// Yields until `condition` holds; never sleeps.
@MainActor
private func settle(_ label: String = "", _ condition: () async -> Bool) async {
    for _ in 0..<200_000 {
        if await condition() { return }
        await Task.yield()
    }
    XCTFail("condition never settled \(label)")
}

@MainActor
final class IngestionQueueTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for url in directories { try? FileManager.default.removeItem(at: url) }
    }

    private func cases(_ operation: String) throws -> [[String: Any]] {
        let rows = try XCTUnwrap(SharedFixtures.json("contracts/ingestion-jobs-v1.json")["cases"] as? [[String: Any]])
        return rows.filter { $0["operation"] as? String == operation }
    }

    private func fileStore() throws -> (NotebookStore, StorePath) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IngestionQueueTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let path = StorePath(fileURL: directory.appendingPathComponent("db.sqlite"))
        return (try NotebookStore(path: path, configuredEmbeddingModelKey: nil), path)
    }

    // MARK: Schedule

    func testCoalesceHasMaximumDeadline() throws {
        var schedule = RescanSchedule()
        for t in stride(from: Int64(0), through: 4_900, by: 100) { schedule.signal(at: t) }
        XCTAssertEqual(schedule.dueAt, 5_000)
        schedule.started()
        schedule.signal(at: 5_100)
        schedule.finished(at: 5_200)
        XCTAssertEqual(schedule.dueAt, 5_600)

        var names = Set<String>()
        for row in try cases("schedule") {
            let name = row["name"] as! String
            XCTAssertTrue(names.insert(name).inserted)
            let input = row["input"] as! [String: Any]
            XCTAssertEqual(input["clockUnit"] as? String, "monotonic-milliseconds")
            var value = RescanSchedule()
            XCTAssertEqual(json(project(value)), json(input["seed"]!), name)
            for event in input["events"] as! [[String: Any]] {
                let at = int64(event["at"])!
                switch event["operation"] as! String {
                case "signal": value.signal(at: at)
                case "started": value.started()
                case "finished": value.finished(at: at)
                case "tick": XCTAssertFalse(value.isDue(at: at), "\(name): nothing is due at the tick")
                case let other: XCTFail("unknown schedule operation \(other)")
                }
                XCTAssertEqual(json(project(value)), json(event["expected"]!), "\(name) @\(at)")
            }
            XCTAssertEqual(json(project(value)), json(row["expected"]!), name)
        }
        XCTAssertEqual(names, ["debounce", "max-coalesce", "signal-during-scan"])
    }

    private func project(_ s: RescanSchedule) -> [String: Any] {
        ["dueAt": null(s.dueAt), "firstSignal": null(s.firstSignal), "lastSignal": null(s.lastSignal),
         "running": s.running, "startedScanCount": s.startedScanCount,
         "trailingFirstSignal": null(s.trailingFirstSignal), "trailingLastSignal": null(s.trailingLastSignal)]
    }

    // MARK: Jobs

    private func seedJobs(_ store: NotebookStore, _ input: [String: Any]) throws {
        try store.runOnDatabase { db in
            let date = Date(timeIntervalSince1970: 0)
            for id in input["notebookIds"] as! [NSNumber] {
                try db.execute(sql: "INSERT INTO notebooks(id,name,created_at,updated_at) VALUES(?,?,?,?)",
                               arguments: [id.int64Value, "nb\(id)", date, date])
            }
            for id in input["folderIds"] as! [NSNumber] {
                try db.execute(sql: """
                    INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,created_at)
                    VALUES(?,1,?,?,'Docs','["md"]','[]','{}',?)
                    """, arguments: [id.int64Value, "/docs\(id)",
                                      #"{"volumeId":"test","components":["docs\#(id)"],"rootFileId":"root-\#(id)"}"#, date])
            }
            for source in input["sources"] as! [[String: Any]] {
                let id = int64(source["id"])!
                try db.execute(sql: """
                    INSERT INTO sources(id,notebook_id,type,title,status,ingested_at,folder_id,rel_path,availability,eligible)
                    VALUES(?,?,'markdown','s',?,?,?,?,?,?)
                    """, arguments: [id, int64(source["notebookId"]), source["status"] as! String, date,
                                      int64(source["folderId"]), "s\(id).md", source["availability"] as! String,
                                      source["eligible"] as! Bool])
            }
            for revision in input["revisions"] as! [[String: Any]] {
                try db.execute(sql: """
                    INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES(?,?,1,'h',?,1,2,?)
                    """, arguments: [int64(revision["id"]), int64(revision["sourceId"]), revision["canonicalText"] as! String, date])
                for (ord, chunk) in (revision["chunks"] as! [[String: Any]]).enumerated() {
                    try db.execute(sql: """
                        INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count,char_start,char_end) VALUES(?,?,?,?,?,1,?,?)
                        """, arguments: [int64(chunk["id"]), int64(revision["sourceId"]), int64(revision["id"]), ord,
                                          chunk["text"] as! String, int64(chunk["start"]), int64(chunk["end"])])
                }
            }
            for source in input["sources"] as! [[String: Any]] {
                try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?",
                               arguments: [int64(source["currentRevision"]), int64(source["publishedRevisionId"]), int64(source["id"])])
            }
            for job in input["jobs"] as! [[String: Any]] {
                let options = String(decoding: try JSONSerialization.data(withJSONObject: job["options"] ?? [:]), as: UTF8.self)
                try db.execute(sql: """
                    INSERT INTO ingest_jobs(id,kind,target,target_revision,attempts,next_retry_at,state,lease_until,lease_token,error,options_json)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [int64(job["id"]), job["kind"] as! String, job["target"] as! String, int64(job["targetRevision"]),
                                      int64(job["attempts"]), int64(job["nextRetryAt"]), job["state"] as! String,
                                      int64(job["leaseUntil"]), job["leaseToken"] as? String, job["error"] as? String, options])
            }
        }
    }

    private func jobRows(_ store: NotebookStore, normalize: [String: String] = [:]) throws -> [[String: Any]] {
        try store.runOnDatabase { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ingest_jobs ORDER BY id").map { row in
                let options: String = row["options_json"]
                let token: String? = row["lease_token"]
                return ["id": row["id"] as Int64, "kind": row["kind"] as String, "target": row["target"] as String,
                        "targetRevision": null(row["target_revision"] as Int64?), "attempts": row["attempts"] as Int64,
                        "nextRetryAt": null(row["next_retry_at"] as Int64?), "state": row["state"] as String,
                        "leaseUntil": null(row["lease_until"] as Int64?),
                        "leaseToken": null(token.map { normalize[$0] ?? $0 }), "error": null(row["error"] as String?),
                        "options": try JSONSerialization.jsonObject(with: Data(options.utf8))]
            }
        }
    }

    private func sourceRows(_ store: NotebookStore) throws -> [[String: Any]] {
        try store.runOnDatabase { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sources ORDER BY id").map { row in
                let eligible: Bool = row["eligible"]
                return ["id": row["id"] as Int64, "notebookId": row["notebook_id"] as Int64,
                        "folderId": null(row["folder_id"] as Int64?), "status": row["status"] as String,
                        "availability": row["availability"] as String, "eligible": eligible,
                        "currentRevision": null(row["current_revision"] as Int64?),
                        "publishedRevisionId": null(row["published_revision_id"] as Int64?)]
            }
        }
    }

    private func published(_ store: NotebookStore) throws -> [Int64: Int64?] {
        try store.runOnDatabase { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id,published_revision_id FROM sources").map {
                ($0["id"] as Int64, $0["published_revision_id"] as Int64?)
            })
        }
    }

    /// Runs one ingestion-jobs trace through file-backed stores, the queue and fenced store calls.
    private func runJobCase(_ row: [String: Any]) async throws {
        let name = row["name"] as! String, input = row["input"] as! [String: Any]
        var (store, path) = try fileStore()
        try seedJobs(store, input)
        let normalize = input["tokenNormalization"] as? [String: String] ?? [:]
        for event in input["events"] as! [[String: Any]] {
            let operation = event["operation"] as! String, at = int64(event["at"])!
            let expected = event["expected"] as! [String: Any]
            let before = try published(store)
            var actual: [String: Any] = [:]
            switch operation {
            case "claim-race":
                let other = try NotebookStore(path: path, configuredEmbeddingModelKey: nil)
                let contenders = event["contenders"] as! [[String: Any]]
                XCTAssertEqual(event["barrier"] as? String, "before-atomic-claim")
                let queues = [store.dbQueue, other.dbQueue]
                let barrier = Barrier(contenders.count)
                let jobId = int64(event["jobId"])!
                var tasks: [Task<Bool, Error>] = []
                for (index, contender) in contenders.enumerated() {
                    let queue = queues[index % queues.count], token = contender["leaseToken"] as! String
                    tasks.append(Task.detached {
                        barrier.arriveAndWait()
                        return try queue.writeWithoutTransaction { db -> Bool in
                            var claimed = false
                            try db.inTransaction(.immediate) {
                                claimed = try RevisionJobSQL.claimJob(db, now: at, leaseToken: token, id: jobId) != nil
                                return .commit
                            }
                            return claimed
                        }
                    })
                }
                var outcomes: [Bool] = []
                for task in tasks { outcomes.append(try await task.value) }
                let jobs = try jobRows(store, normalize: normalize)
                actual = ["accepted": outcomes.contains(true), "acceptedCount": outcomes.filter { $0 }.count,
                          "rejectedCount": outcomes.filter { !$0 }.count,
                          "winnerTokenCount": jobs.filter { $0["leaseToken"] as? String == "winner" }.count]
            case "recover-expired":
                if event["process"] as? String == "replacement" {
                    store = try NotebookStore(path: path, configuredEmbeddingModelKey: nil)
                }
                actual["accepted"] = try store.recoverExpiredJobs(now: at) > 0
            case "claim":
                let token = event["leaseToken"] as! String, expectedId = int64(event["jobId"])
                let queue = JobQueue(store: store, clock: ManualClock(at), admission: IngestionAdmission(), token: { token })
                actual["accepted"] = try await queue.runOne(kind: "extract", reservedBytes: 1) { job, _ in
                    XCTAssertEqual(job.id, expectedId)
                }
            case "claim-many":
                let tokens = Tokens(event["tokenSequence"] as! [String])
                let queue = JobQueue(store: store, clock: ManualClock(at), admission: IngestionAdmission(), token: { tokens.next() })
                var claimed: [Int64] = []
                while try await queue.runOne(kind: "extract", reservedBytes: 1, execute: { _, _ in }) {
                    claimed.append(try XCTUnwrap(jobRows(store).last { $0["leaseToken"] as? String == tokens.issued.last }?["id"] as? Int64))
                }
                XCTAssertEqual(claimed, (event["jobIds"] as! [NSNumber]).map(\.int64Value), name)
                XCTAssertEqual(Set(tokens.issued).count, tokens.issued.count, "lease tokens are never reused")
                actual = ["accepted": !claimed.isEmpty, "issuedLeaseTokens": tokens.issued]
            case "renew":
                actual["accepted"] = try store.renewJob(fence: JobFence(jobId: int64(event["jobId"])!, leaseToken: event["leaseToken"] as! String), now: at)
            case "fail":
                actual["accepted"] = try store.failJob(fence: JobFence(jobId: int64(event["jobId"])!, leaseToken: event["leaseToken"] as! String),
                                                       error: event["error"] as! String, now: at)
            case "publish":
                let draft = event["revisionDraft"] as! [String: Any]
                let text = draft["canonicalText"] as! String
                let chunks = (draft["chunks"] as! [[String: Any]]).map {
                    RevisionChunkDraft(text: $0["text"] as! String, tokenCount: 1, pageHint: nil, charStart: Int(int64($0["start"])!),
                                       charEnd: Int(int64($0["end"])!), lang: nil, langInherited: false)
                }
                let job = try XCTUnwrap(store.job(id: int64(event["jobId"])!))
                XCTAssertEqual(job.draft.targetRevision, int64(event["requestedRevision"]))
                let revision = try store.commitExtraction(sourceId: Int64(job.draft.target.dropFirst("source:".count))!,
                    draft: RevisionDraft(contentHash: "new", canonicalText: text, textFormatVersion: 1, chunkerVersion: 2),
                    chunks: chunks, fence: JobFence(jobId: job.id, leaseToken: event["leaseToken"] as! String), now: at)
                actual["accepted"] = revision != nil
            case "user-retry":
                let created = try store.retryExhaustedJob(id: int64(event["jobId"])!, now: at)
                XCTAssertEqual(created, int64(event["newJobId"]), name)
                actual["accepted"] = created != nil
            default:
                XCTFail("unknown job operation \(operation)")
            }
            let after = try published(store)
            actual["publishedRevisionIds"] = after.keys.sorted().compactMap { id -> Int64? in
                guard let value = after[id] ?? nil, before[id] ?? nil != value else { return nil }
                return value
            }
            actual["jobs"] = try jobRows(store, normalize: normalize)
            actual["sources"] = try sourceRows(store)
            for key in expected.keys.sorted() {
                XCTAssertEqual(json(actual[key] ?? NSNull()), json(expected[key]!), "\(name) \(operation) \(key)")
            }
        }
    }

    /// Frozen job-transition cases with starts driven through JobQueue, plus every
    /// ingestion-jobs trace through the queue and fenced store kernels.
    func testEveryJobTransition() async throws {
        let frozen = try XCTUnwrap(SharedFixtures.json("contracts/job-transitions-v1.json")["cases"] as? [[String: Any]])
            .map { try RetryCapSupersession.apply($0, fixture: "job-transitions-v1.json") }
        XCTAssertEqual(frozen.count, 21)
        for fixture in frozen {
            let name = fixture["name"] as! String
            let input = fixture["input"] as! [String: Any], job = input["job"] as! [String: Any], event = input["event"] as! [String: Any]
            let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
            try store.runOnDatabase { db in
                let date = Date(timeIntervalSince1970: 0)
                try db.execute(sql: "INSERT INTO notebooks(id,name,created_at,updated_at) VALUES(1,'t',?,?)", arguments: [date, date])
                try db.execute(sql: "INSERT INTO sources(id,notebook_id,type,title,status,ingested_at) VALUES(1,1,'text','t','pending',?)", arguments: [date])
                try db.execute(sql: """
                    INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES(11,1,1,'r11','',1,2,?)
                    """, arguments: [date])
                try db.execute(sql: "UPDATE sources SET current_revision=11 WHERE id=1")
                try db.execute(sql: """
                    INSERT INTO ingest_jobs(id,kind,target,target_revision,state,attempts,next_retry_at,lease_until,lease_token)
                    VALUES(1,'extract','source:1',?,?,?,?,?,?)
                    """, arguments: [int64(job["targetRevision"]), job["state"] as! String, int64(job["attempts"]),
                                      int64(job["nextRetryAt"]), int64(job["leaseUntil"]), job["leaseToken"] as? String])
                if let requested = int64(event["requestedRevision"]), requested != int64(job["targetRevision"]) {
                    try db.execute(sql: """
                        INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                        VALUES(?,1,2,'r','',1,2,?)
                        """, arguments: [requested, date])
                    try db.execute(sql: "UPDATE sources SET current_revision=? WHERE id=1", arguments: [requested])
                }
            }
            let now = int64(event["now"])!, token = event["leaseToken"] as? String
            let fence = JobFence(jobId: 1, leaseToken: token ?? "unused")
            var accepted = false, didPublish = false
            switch event["kind"] as! String {
            case "start":
                let queue = JobQueue(store: store, clock: ManualClock(now), admission: IngestionAdmission(), token: { token! })
                accepted = try await queue.runOne(kind: "extract", reservedBytes: 1) { _, _ in }
            case "fail": accepted = try store.failJob(fence: fence, error: "fixture", now: now)
            case "retry": accepted = try store.retryJob(id: 1, now: now)
            case "expire": accepted = try store.recoverExpiredJobs(now: now) > 0
            case "renew": accepted = try store.renewJob(fence: fence, now: now)
            case "publish":
                didPublish = try store.publishRevision(sourceId: 1, revisionId: int64(job["targetRevision"])!, chunks: [], fence: fence, now: now)
                let state = try store.job(id: 1)?.state
                accepted = didPublish || state == "cancelled"
            case let other: XCTFail("unknown frozen event \(other)")
            }
            let expected = fixture["expected"] as! [String: Any], expectedJob = expected["job"] as! [String: Any]
            let actualJob = try XCTUnwrap(store.job(id: 1))
            XCTAssertEqual(json(["state": actualJob.state, "attempts": actualJob.attempts, "nextRetryAt": null(actualJob.nextRetryAt),
                                 "leaseUntil": null(actualJob.leaseUntil), "leaseToken": null(actualJob.leaseToken),
                                 "targetRevision": null(actualJob.draft.targetRevision)] as [String: Any]), json(expectedJob), name)
            XCTAssertEqual(accepted, expected["accepted"] as? Bool, name)
            XCTAssertEqual(didPublish, expected["published"] as? Bool, name)
        }
        var names = Set<String>()
        for row in try cases("jobs") {
            XCTAssertTrue(names.insert(row["name"] as! String).inserted)
            try await runJobCase(row)
        }
        XCTAssertEqual(names, ["two-claims", "restart-expiry", "renew-60", "stale-fail", "stale-publish", "token-unique", "exhausted-user-retry"])
    }

    func testTwoDatabaseClaimers() async throws {
        let row = try XCTUnwrap(cases("jobs").first { $0["name"] as? String == "two-claims" })
        for _ in 0..<5 { try await runJobCase(row) }
    }

    func testRenewalAndRestart() async throws {
        for name in ["renew-60", "restart-expiry"] {
            try await runJobCase(try XCTUnwrap(cases("jobs").first { $0["name"] as? String == name }))
        }
        // The queue renews at claim+60, +120 with the current clock, then joins renewal.
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "renew").id)
        let source = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: "t", uri: nil, rawPath: nil).id)
        let id = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(source)", targetRevision: nil), now: 0)
        let clock = ManualClock(0), events = Events(), gate = Gate()
        let queue = JobQueue(store: store, clock: clock, admission: IngestionAdmission(), token: { "lease-1" },
                             observe: { events.record($0) })
        let run = Task { try await queue.runOne(kind: "extract", reservedBytes: 1) { _, _ in
            events.record("started")
            await gate.wait()
        } }
        await events.next("started")
        XCTAssertEqual(try store.job(id: id)?.leaseUntil, 300)
        await settle("renewal wait") { clock.pendingWaits == 1 }
        clock.advance(to: 59)
        XCTAssertEqual(clock.pendingWaits, 1, "no renewal before 60 seconds")
        clock.advance(to: 60)
        await events.next("renewed:\(id)")
        XCTAssertEqual(try store.job(id: id)?.leaseUntil, 360)
        await settle("second renewal wait") { clock.pendingWaits == 1 }
        clock.advance(to: 125)
        await settle("second renewal") { events.all.filter { $0 == "renewed:\(id)" }.count == 2 }
        XCTAssertEqual(try store.job(id: id)?.leaseUntil, 425, "renewal uses the current clock")
        XCTAssertEqual(try store.job(id: id)?.attempts, 1)
        gate.release()
        let v1 = try await run.value
        XCTAssertTrue(v1)
        XCTAssertEqual(clock.pendingWaits, 0, "renewal joined on completion")
        XCTAssertEqual(try store.job(id: id)?.state, "running", "the queue never completes extraction generically")
        // Restart: the expired lease is recovered at the next scheduling tick and claimed with a fresh token.
        let restarted = JobQueue(store: store, clock: ManualClock(425), admission: IngestionAdmission(), token: { "lease-2" })
        let v2 = try await restarted.runOne(kind: "extract", reservedBytes: 1) { _, _ in XCTFail("not due yet") }
        XCTAssertFalse(v2)
        XCTAssertEqual(try store.job(id: id)?.state, "queued")
        let retryAt = try XCTUnwrap(store.job(id: id)?.nextRetryAt)
        let later = JobQueue(store: store, clock: ManualClock(retryAt), admission: IngestionAdmission(), token: { "lease-2" })
        let v3 = try await later.runOne(kind: "extract", reservedBytes: 1) { job, fence in
            XCTAssertEqual(job.attempts, 2)
            XCTAssertEqual(fence.leaseToken, "lease-2")
        }
        XCTAssertTrue(v3)
    }

    /// A candidate whose reservation (or claim) throws must not stall every later
    /// job of its kind: it is skipped for `preClaimDeferral` lease-clock seconds.
    func testThrowingCandidateDoesNotStallLaterJobs() async throws {
        struct Poison: Error {}
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "poison").id)
        let a = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: "a", uri: nil, rawPath: nil).id)
        let b = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: "b", uri: nil, rawPath: nil).id)
        let poisoned = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(a)", targetRevision: nil), now: 0)
        let healthy = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(b)", targetRevision: nil), now: 0)
        let clock = ManualClock(0), admission = IngestionAdmission()
        let queue = JobQueue(store: store, clock: clock, admission: admission, token: { UUID().uuidString })
        let reservation: @Sendable (IngestJob) async throws -> Int64 = { job in
            if job.id == poisoned { throw Poison() }
            return 1
        }
        do {
            _ = try await queue.runOne(kind: "extract", reservation: reservation) { _, _ in XCTFail("poisoned job ran") }
            XCTFail("the reservation error propagates")
        } catch is Poison {}
        let ran = Events()
        let v1 = try await queue.runOne(kind: "extract", reservation: reservation) { job, _ in ran.record("\(job.id)") }
        XCTAssertTrue(v1)
        XCTAssertEqual(ran.all, ["\(healthy)"], "the next due job runs instead of re-selecting the poisoned head")
        let v2 = try await queue.runOne(kind: "extract", reservation: reservation) { _, _ in XCTFail("still deferred") }
        XCTAssertFalse(v2)
        XCTAssertEqual(try store.job(id: poisoned)?.state, "queued")
        XCTAssertEqual(try store.job(id: poisoned)?.attempts, 0)
        let permits = await admission.snapshot().reservations
        XCTAssertTrue(permits.isEmpty, "no permit leaks")
        clock.advance(to: JobQueue.preClaimDeferral)
        do {
            _ = try await queue.runOne(kind: "extract", reservation: reservation) { _, _ in XCTFail("poisoned job ran") }
            XCTFail("retried after the deferral")
        } catch is Poison {}
    }

    /// Parity with Windows: an unparsable folder limits document reserves the
    /// defaults instead of throwing (a throwing reservation stalls the queue head).
    func testReservationFallsBackToDefaultLimits() throws {
        struct Identity: FolderPathIdentity {
            func resolve(rootPath: String) throws -> FolderIdentity {
                FolderIdentity(volumeId: "v", components: rootPath.split(separator: "/").map(String.init), rootFileId: "r")
            }
        }
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "limits").id)
        let folder = try store.createFolder(notebookId: notebook, draft: FolderDraft(rootPath: "/docs", displayName: "docs",
            includeExts: ["md"], ignoreGlobs: [], limitsJSON: "{}", encodingFallback: FolderRules.defaults.encodingFallback,
            watchEnabled: false), identity: Identity(), now: 0)
        let source = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: "a", uri: nil, rawPath: nil).id)
        try store.runOnDatabase { db in
            try db.execute(sql: "UPDATE folder_sources SET limits='{not json' WHERE id=?", arguments: [folder.id])
            try db.execute(sql: "UPDATE sources SET folder_id=?,rel_path='a.md',size_bytes=100 WHERE id=?", arguments: [folder.id, source])
        }
        let id = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(source)", targetRevision: nil), now: 0)
        let job = try XCTUnwrap(store.job(id: id))
        XCTAssertEqual(try store.extractionReservation(job: job),
                       IngestionAdmission.reservation(kind: .text, fileBytes: 100, limits: .defaults))
    }

    func testFiveAttemptsAndNewUserRetry() async throws {
        try await runJobCase(try XCTUnwrap(cases("jobs").first { $0["name"] as? String == "exhausted-user-retry" }))
        // Worker failures go through the queue's fenced failJob; the third is terminal (ingestion-retry-cap-v1).
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "five").id)
        let source = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: "t", uri: nil, rawPath: nil).id)
        let id = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(source)", targetRevision: nil), now: 0)
        var now: Int64 = 0, counter = 0
        for attempt in 1...ExtractionRetryBudget.extractMaxAttempts {
            let clock = ManualClock(now)
            counter += 1
            let token = "attempt-\(counter)"
            let queue = JobQueue(store: store, clock: clock, admission: IngestionAdmission(), token: { token })
            let v4 = try await queue.runOne(kind: "extract", reservedBytes: 1) { job, _ in
                XCTAssertEqual(job.attempts, attempt)
                throw IngestionError(code: "corruptArchive")
            }
            XCTAssertTrue(v4)
            let failed = try XCTUnwrap(store.job(id: id))
            XCTAssertEqual(failed.state, "failed")
            XCTAssertEqual(failed.error, "corruptArchive")
            XCTAssertEqual(try store.source(id: source)?.status, .error)
            if attempt < ExtractionRetryBudget.extractMaxAttempts {
                XCTAssertEqual(failed.nextRetryAt, now + (Int64(1) << attempt) * 30)
                now = failed.nextRetryAt!
            } else {
                XCTAssertNil(failed.nextRetryAt)
            }
        }
        let exhausted = JobQueue(store: store, clock: ManualClock(now + 100_000), admission: IngestionAdmission(), token: { "sixth" })
        let v5 = try await exhausted.runOne(kind: "extract", reservedBytes: 1) { _, _ in XCTFail("exhausted job restarted") }
        XCTAssertFalse(v5)
        let retry = try XCTUnwrap(store.retryExhaustedJob(id: id, now: now + 100_001))
        XCTAssertNotEqual(retry, id)
        XCTAssertEqual(try store.job(id: retry)?.attempts, 0)
        XCTAssertEqual(try store.job(id: id)?.attempts, ExtractionRetryBudget.extractMaxAttempts)
        XCTAssertEqual(try store.source(id: source)?.status, .pending)
        XCTAssertNil(try store.retryExhaustedJob(id: retry, now: now + 100_002), "only exhausted jobs take a user retry")
    }

    @MainActor
    func testFailuresRequeueAtDeadlineAndExhaustAfterThreeStarts() throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try store.createNotebook(name: "retries")
        let source = try store.createSource(notebookId: XCTUnwrap(notebook.id), type: .text,
            title: "kept", uri: nil, rawPath: nil)
        let sourceId = try XCTUnwrap(source.id)
        let published = try store.commitForegroundRevision(sourceId: sourceId,
            draft: RevisionDraft(contentHash: "kept-hash", canonicalText: "kept", textFormatVersion: 1, chunkerVersion: 2),
            chunks: [RevisionChunkDraft(text: "kept", tokenCount: 1, pageHint: nil,
                charStart: 0, charEnd: 4, lang: nil, langInherited: false)], now: 0, leaseToken: "seed")
        var fence = try store.beginExtraction(sourceId: sourceId, now: 100, leaseToken: "attempt-1")
        let jobId = fence.jobId
        var startedAt: Int64 = 100
        let last = ExtractionRetryBudget.extractMaxAttempts
        for attempt in 1...last {
            let running = try XCTUnwrap(store.job(id: jobId))
            XCTAssertEqual(running.state, "running")
            XCTAssertEqual(running.attempts, attempt)
            XCTAssertNil(running.nextRetryAt)
            let failedAt = startedAt + 1
            XCTAssertTrue(try store.failJob(fence: fence, error: "extract-failed", now: failedAt))
            let failed = try XCTUnwrap(store.job(id: jobId))
            XCTAssertEqual(failed.state, "failed")
            XCTAssertEqual(failed.attempts, attempt)
            XCTAssertNil(failed.leaseToken)
            XCTAssertNil(failed.leaseUntil)
            XCTAssertEqual(try store.source(id: sourceId)?.publishedRevisionId, published.id)
            XCTAssertEqual(try store.chunks(sourceId: sourceId).map(\.text), ["kept"])
            if attempt < last {
                let retryAt = failedAt + (Int64(1) << attempt) * 30
                XCTAssertEqual(failed.nextRetryAt, retryAt)
                XCTAssertEqual(try store.requeueRetryableJobs(now: retryAt - 1), 0)
                XCTAssertNil(try store.claimJob(now: retryAt - 1, leaseToken: "too-early-\(attempt)", id: jobId))
                XCTAssertEqual(try store.requeueRetryableJobs(now: retryAt), 1)
                let queued = try XCTUnwrap(store.job(id: jobId))
                XCTAssertEqual(queued.state, "queued")
                XCTAssertEqual(queued.attempts, attempt)
                XCTAssertEqual(queued.nextRetryAt, retryAt)
                let token = "attempt-\(attempt + 1)"
                let claimed = try XCTUnwrap(store.claimJob(now: retryAt, leaseToken: token, id: jobId))
                XCTAssertEqual(claimed.attempts, attempt + 1)
                fence = JobFence(jobId: jobId, leaseToken: token)
                startedAt = retryAt
            } else {
                XCTAssertNil(failed.nextRetryAt)
                XCTAssertEqual(try store.requeueRetryableJobs(now: failedAt + 10_000), 0)
                XCTAssertNil(try store.claimJob(now: failedAt + 10_000, leaseToken: "sixth", id: jobId))
                XCTAssertEqual(try store.job(id: jobId)?.attempts, last)
            }
        }
        let retryId = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(sourceId)",
            targetRevision: published.id), now: startedAt + 20_000)
        XCTAssertNotEqual(retryId, jobId)
        XCTAssertEqual(try store.job(id: retryId)?.attempts, 0)
        XCTAssertEqual(try store.job(id: jobId)?.state, "failed")
    }

    // MARK: Admission

    /// Interprets one admission trace with fixture token names mapped to issued UUIDs.
    private func runAdmissionCase(_ row: [String: Any]) async throws {
        let name = row["name"] as! String, input = row["input"] as! [String: Any]
        let admission = IngestionAdmission(maxExtractions: Int(int64(input["maxExtractions"])!), memoryBytes: int64(input["memoryBytes"])!)
        let provider = ProviderRecorder()
        var tokens: [String: UUID] = [:], names: [UUID: String] = [:], requestOf: [UUID: String] = [:]
        var acquires: [UUID: Task<Void, Error>] = [:]
        var batches: [(id: String, token: UUID, task: Task<Void, Error>)] = []
        var cancelled: [String] = []
        func project() async -> [String: Any] {
            let s = await admission.snapshot()
            return ["reservations": s.reservations.map { ["bytes": $0.bytes, "token": names[$0.token]!] as [String: Any] },
                    "waiters": s.waiters.map { ["bytes": $0.bytes, "requestId": requestOf[$0.token]!, "token": names[$0.token]!] as [String: Any] },
                    "chatTokens": s.chatTokens.map { names[$0]! },
                    "backgroundWaiters": batches.filter { s.backgroundWaiters.contains($0.token) }.map(\.id),
                    "startedBackgroundBatches": provider.started, "providerCallCount": provider.calls,
                    "queryInputs": provider.inputs, "cancelledWaiters": cancelled, "memoryPressure": s.memoryPressure]
        }
        let v6 = await project()
        // The seed lists only the admission fields; every listed one must match.
        let seed = input["seed"] as! [String: Any]
        XCTAssertEqual(json(v6.filter { seed[$0.key] != nil }), json(seed), "\(name) seed")
        for event in input["events"] as! [[String: Any]] {
            let operation = event["operation"] as! String
            switch operation {
            case "acquire":
                let id = UUID(), token = event["token"] as! String
                tokens[token] = id; names[id] = token; requestOf[id] = event["requestId"] as? String
                let bytes = int64(event["bytes"])!
                acquires[id] = Task { try await admission.acquireExtraction(bytes: bytes, token: id) }
                await settle(name) { let s = await admission.snapshot(); return (s.reservations + s.waiters).contains { $0.token == id } }
            case "release":
                await admission.releaseExtraction(try XCTUnwrap(tokens[event["token"] as! String]))
            case "cancel-waiter":
                let request = event["requestId"] as! String
                let id = try XCTUnwrap(requestOf.first { $0.value == request }?.key)
                acquires[id]!.cancel()
                let result = await acquires[id]!.result
                if case .failure(let error) = result, error is CancellationError { cancelled.append(request) }
                else { XCTFail("\(name): cancelled waiter was granted") }
                acquires[id] = nil
            case "memory-pressure":
                await admission.setMemoryPressure(event["blocked"] as! Bool)
            case "begin-chat":
                let id = UUID(), token = event["token"] as! String
                tokens[token] = id; names[id] = token
                await admission.beginChat(token: id)
            case "end-chat":
                await admission.endChat(try XCTUnwrap(tokens[event["token"] as! String]))
            case "background-batch":
                let id = UUID(), batch = event["batchId"] as! String
                let task = Task {
                    try await admission.waitForBackgroundBatch(token: id)
                    provider.batch(batch)
                }
                batches.append((batch, id, task))
                await settle(name) { await admission.snapshot().backgroundWaiters.contains(id) || provider.started.contains(batch) }
            case "query-embedding":
                provider.query(event["text"] as! String)
            default:
                XCTFail("unknown admission operation \(operation)")
            }
            // Settle granted waiters and released background batches.
            let snapshot = await admission.snapshot()
            for (id, task) in acquires where snapshot.reservations.contains(where: { $0.token == id }) {
                try await task.value
                acquires[id] = nil
            }
            for batch in batches where !snapshot.backgroundWaiters.contains(batch.token) {
                try await batch.task.value
            }
            let v7 = await project()
            XCTAssertEqual(json(v7), json(event["expected"]!), "\(name) \(operation)")
        }
        let v8 = await project()
        XCTAssertEqual(json(v8), json(row["expected"]!), name)
        for task in acquires.values { task.cancel() }
        for batch in batches { batch.task.cancel() }
    }

    func testMemoryAndConcurrency() async throws {
        let rows = try cases("admission").filter {
            ["concurrency-two", "memory-one", "cancel-releases", "cancel-waiter", "oversize-runs-alone",
             "memory-pressure-clears"].contains($0["name"] as! String)
        }
        XCTAssertEqual(rows.count, 6)
        for row in rows { try await runAdmissionCase(row) }

        let limits = IngestionLimits.defaults
        let textBase: Int64 = 4_000 + 40_000_000 + 1_280_000
        XCTAssertEqual(IngestionAdmission.reservation(kind: .text, fileBytes: 1_000, limits: limits), textBase)
        XCTAssertEqual(IngestionAdmission.reservation(kind: .docx, fileBytes: 1_000, limits: limits), textBase + 209_715_200)
        let pdfMax: Int64 = 209_715_200 + 40_000_000 + 1_280_000 + 209_715_200
        XCTAssertEqual(IngestionAdmission.reservation(kind: .pdf, fileBytes: .max, limits: limits), pdfMax)

        // Through the queue: the third extraction does not start until a permit is released.
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "admission").id)
        var created: [Int64] = []
        for index in 0..<3 {
            let source = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: "s\(index)", uri: nil, rawPath: nil).id)
            created.append(try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(source)", targetRevision: nil), now: 0))
        }
        let ids = created
        let admission = IngestionAdmission()
        let events = Events(), gates = [Gate(), Gate(), Gate()]
        var counter = 0
        let tokenSource = Tokens((0..<3).map { "t\($0)" })
        let queue = JobQueue(store: store, clock: ManualClock(0), admission: admission, token: { tokenSource.next() })
        var runs: [Task<Bool, Error>] = []
        for _ in 0..<3 {
            counter += 1
            runs.append(Task { try await queue.runOne(kind: "extract", reservedBytes: 10) { job, _ in
                events.record("started:\(job.id)")
                await gates[Int(job.id - ids[0])].wait()
            } })
        }
        await events.next("started:\(ids[0])")
        await events.next("started:\(ids[1])")
        await settle("third waits") { await admission.snapshot().waiters.count == 1 }
        XCTAssertFalse(events.all.contains("started:\(ids[2])"), "the third extraction did not start")
        XCTAssertEqual(try store.job(id: ids[2])?.state, "queued", "no claim waits for a permit")
        gates[0].release()
        await events.next("started:\(ids[2])")
        gates[1].release()
        gates[2].release()
        for run in runs { let ok = try await run.value; XCTAssertTrue(ok) }
        let v9 = await admission.snapshot().reservations
        XCTAssertEqual(v9, [])
        XCTAssertEqual(counter, 3)
    }

    func testChatTokensAndCancellation() async throws {
        let rows = try cases("admission").filter { ["chat-two-tokens", "chat-query-unblocked"].contains($0["name"] as! String) }
        XCTAssertEqual(rows.count, 2)
        for row in rows { try await runAdmissionCase(row) }
        XCTAssertEqual(try cases("admission").count, 8)

        // A waiting background batch is cancellable and leaves no waiter behind.
        let admission = IngestionAdmission()
        let chat = await admission.beginChat()
        let waiting = Task { try await admission.waitForBackgroundBatch() }
        await settle("batch waits") { await admission.snapshot().backgroundWaiters.count == 1 }
        waiting.cancel()
        let result = await waiting.result
        guard case .failure(let error) = result, error is CancellationError else { return XCTFail("expected cancellation") }
        let v10 = await admission.snapshot().backgroundWaiters
        XCTAssertEqual(v10, [])
        await admission.endChat(chat)
        await admission.endChat(chat) // idempotent
        try await admission.waitForBackgroundBatch() // no chat: immediate
        // A cancelled acquire waiter never leaks a reservation.
        let tight = IngestionAdmission(maxExtractions: 1)
        let held = try await tight.acquireExtraction(bytes: 1)
        let blocked = Task { try await tight.acquireExtraction(bytes: 1) }
        await settle("acquire waits") { await tight.snapshot().waiters.count == 1 }
        blocked.cancel()
        _ = await blocked.result
        await tight.releaseExtraction(held)
        await tight.releaseExtraction(held)
        let v11 = await tight.snapshot().reservations
        XCTAssertEqual(v11, [])
        let v12 = await tight.snapshot().waiters
        XCTAssertEqual(v12, [])
    }

    func testNoResourceLeakOnLostLease() async throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "lost").id)
        let source = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: "t", uri: nil, rawPath: nil).id)
        let id = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(source)", targetRevision: nil), now: 0)
        let clock = ManualClock(0), events = Events(), admission = IngestionAdmission()
        let queue = JobQueue(store: store, clock: clock, admission: admission, token: { "owner" }, observe: { events.record($0) })
        let run = Task { try await queue.runOne(kind: "extract", reservedBytes: 100) { _, _ in
            events.record("started")
            // Cooperative work: only cancellation ends it.
            try await clock.wait(until: .max)
        } }
        await events.next("started")
        let v13 = await admission.snapshot().reservations.count
        XCTAssertEqual(v13, 1)
        // A replacement process steals the job after a simulated expiry.
        try store.runOnDatabase { try $0.execute(sql: "UPDATE ingest_jobs SET lease_token='thief',lease_until=900 WHERE id=?", arguments: [id]) }
        await settle("renewal wait") { clock.pendingWaits == 2 }
        clock.advance(to: 60)
        await events.next("renewalFailed:\(id)")
        await events.next("cancelled:\(id)")
        let v14 = try await run.value
        XCTAssertTrue(v14)
        let v15 = await admission.snapshot().reservations
        XCTAssertEqual(v15, [], "lost lease releases the permit")
        let stolen = try XCTUnwrap(store.job(id: id))
        XCTAssertEqual(stolen.leaseToken, "thief", "the replacement owner is untouched")
        XCTAssertEqual(stolen.state, "running")
        XCTAssertFalse(events.all.contains { $0.hasPrefix("failed:") || $0.hasPrefix("staleFailure:") })

        // A stale failure has no effect on the replacement.
        let second = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(source)", targetRevision: nil), now: 60)
        let failing = JobQueue(store: store, clock: ManualClock(60), admission: admission, token: { "stale" }, observe: { events.record($0) })
        let v16 = try await failing.runOne(kind: "extract", reservedBytes: 100) { _, _ in
            try await MainActor.run {
                try store.runOnDatabase { try $0.execute(sql: "UPDATE ingest_jobs SET lease_token='replacement' WHERE id=?", arguments: [second]) }
            }
            throw IngestionError(code: "corruptArchive")
        }
        XCTAssertTrue(v16)
        await events.next("staleFailure:\(second)")
        XCTAssertEqual(try store.job(id: second)?.state, "running")
        XCTAssertEqual(try store.job(id: second)?.leaseToken, "replacement")
        let v17 = await admission.snapshot().reservations
        XCTAssertEqual(v17, [])

        // User cancellation of a running extraction is fenced, releases resources, and does not
        // leave the source refresh pending forever (carry-over from WP3).
        try store.runOnDatabase { db in
            try db.execute(sql: "UPDATE ingest_jobs SET state='cancelled',lease_token=NULL,lease_until=NULL WHERE id IN (?,?)", arguments: [id, second])
        }
        let third = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(source)", targetRevision: nil), now: 70)
        let userClock = ManualClock(70)
        let cancellable = JobQueue(store: store, clock: userClock, admission: admission, token: { "user" }, observe: { events.record($0) })
        let running = Task { try await cancellable.runOne(kind: "extract", reservedBytes: 100) { _, _ in
            events.record("user-started")
            try await userClock.wait(until: .max)
        } }
        await events.next("user-started")
        XCTAssertEqual(try store.source(id: source)?.status, .chunking)
        try await cancellable.cancel(jobId: third)
        let v18 = try await running.value
        XCTAssertTrue(v18)
        XCTAssertEqual(try store.job(id: third)?.state, "cancelled")
        XCTAssertEqual(try store.source(id: source)?.status, .error)
        XCTAssertEqual(try store.source(id: source)?.error, "cancelled")
        XCTAssertEqual(try store.coverage(notebookId: notebook, scope: .all).refreshPending, 0)
        let v19 = await admission.snapshot().reservations
        XCTAssertEqual(v19, [])
        // A queued job cancelled before claim is handled the same way; stop joins everything.
        let fourth = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(source)", targetRevision: nil), now: 80)
        try store.runOnDatabase { try $0.execute(sql: "UPDATE sources SET status='pending',error=NULL WHERE id=?", arguments: [source]) }
        try await cancellable.cancel(jobId: fourth)
        XCTAssertEqual(try store.job(id: fourth)?.state, "cancelled")
        XCTAssertEqual(try store.source(id: source)?.status, .error)
        await cancellable.stop()
        let v20 = try await cancellable.runOne(kind: "extract", reservedBytes: 1) { _, _ in XCTFail("stopped queue ran") }
        XCTAssertFalse(v20)
    }
}

import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private struct PipelineIdentity: FolderPathIdentity {
    func resolve(rootPath: String) throws -> FolderIdentity {
        FolderIdentity(volumeId: "test", components: ["docs"], rootFileId: "root-1")
    }
}

private struct InjectedFailure: Error {}

private final class FileState: @unchecked Sendable {
    private let gate = NSLock()
    private var current: (bytes: Data, stamp: FileStamp, sha256: String)
    private var snapshots = 0
    init(bytes: Data, stamp: FileStamp, sha256: String) { current = (bytes, stamp, sha256) }
    func replace(bytes: Data, stamp: FileStamp, sha256: String) { gate.lock(); current = (bytes, stamp, sha256); gate.unlock() }
    var value: (bytes: Data, stamp: FileStamp, sha256: String) { gate.lock(); defer { gate.unlock() }; return current }
    func countSnapshot() { gate.lock(); snapshots += 1; gate.unlock() }
    var snapshotCount: Int { gate.lock(); defer { gate.unlock() }; return snapshots }
}

/// One scripted file. The snapshot is a private temporary copy, as in the native adapter.
private struct PipelineFS: FolderFileSystem {
    let file: FileState
    func resolve(rootPath: String) throws -> FolderIdentity { try PipelineIdentity().resolve(rootPath: rootPath) }
    func caseSensitive(root: FolderSource) throws -> Bool { true }
    func list(root: FolderSource, directory: String) throws -> [FolderEntry] { XCTFail("no listing"); return [] }
    func stat(root: FolderSource, relativePath: String) throws -> FileStamp { file.value.stamp }
    func hash(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderRead {
        let value = file.value
        return FolderRead(bytes: Data(), stamp: value.stamp, sha256: value.sha256)
    }
    func snapshot(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderFileSnapshot {
        file.countSnapshot()
        let value = file.value
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-" + UUID().uuidString + "-" +
            (relativePath.split(separator: "/").last.map(String.init) ?? "file"))
        try value.bytes.write(to: url)
        return FolderFileSnapshot(url: url, stamp: value.stamp, hash: value.sha256)
    }
}

private final class FixedClock: IngestLeaseClock, @unchecked Sendable {
    private let gate = NSLock()
    private var value: Int64
    init(_ value: Int64) { self.value = value }
    func set(_ next: Int64) { gate.lock(); value = next; gate.unlock() }
    func now() -> Int64 { gate.lock(); defer { gate.unlock() }; return value }
    func wait(until: Int64) async throws { throw CancellationError() }
}

private final class Counter: @unchecked Sendable {
    private let gate = NSLock()
    private var count = 0
    private var token: NSObjectProtocol?
    func attach(_ store: NotebookStore) {
        let observer = NotificationCenter.default.addObserver(forName: .folderIngestionDidChange, object: store, queue: nil) { [weak self] _ in
            self?.increment()
        }
        gate.lock(); token = observer; count = 0; gate.unlock()
    }
    func detach() { gate.lock(); let t = token; token = nil; gate.unlock(); if let t { NotificationCenter.default.removeObserver(t) } }
    private func increment() { gate.lock(); count += 1; gate.unlock() }
    var value: Int { gate.lock(); defer { gate.unlock() }; return count }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrived = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    func release() {
        lock.lock(); open = true; let ready = waiters; waiters = []; lock.unlock()
        for waiter in ready { waiter.resume() }
    }
    private func arrive() -> [CheckedContinuation<Void, Never>] {
        lock.lock(); defer { lock.unlock() }
        arrived = true
        let notify = arrivals
        arrivals = []
        return notify
    }
    func wait() async {
        for waiter in arrive() { waiter.resume() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if open { lock.unlock(); continuation.resume(); return }
            waiters.append(continuation)
            lock.unlock()
        }
    }
    func reached() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if arrived { lock.unlock(); continuation.resume(); return }
            arrivals.append(continuation)
            lock.unlock()
        }
    }
}

private func int64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
private func json(_ value: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
}
private func null(_ value: Any?) -> Any { value ?? NSNull() }
private func compact(_ value: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
}
private func parsed(_ text: String?) -> Any {
    guard let text else { return NSNull() }
    return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? NSNull()
}
private func pageRange(_ pages: [(page: Int64, start: Int64, end: Int64)], _ start: Int64?, _ end: Int64?) -> (Any, Any) {
    guard let start, let end else { return (NSNull(), NSNull()) }
    let overlapping = pages.filter { $0.start < $0.end && $0.start < end && $0.end > start }.map(\.page)
    guard let first = overlapping.min(), let last = overlapping.max() else { return (NSNull(), NSNull()) }
    return (first, last)
}
private func document(_ value: [String: Any]) -> CanonicalDocument {
    CanonicalDocument(text: value["text"] as! String, title: value["title"] as? String, kind: value["kind"] as! String,
        pages: (value["pages"] as! [[String: Any]]).map {
            PageBoundary(page: Int(int64($0["page"])!), start: Int(int64($0["start"])!), end: Int(int64($0["end"])!))
        }, sheetNames: value["sheetNames"] as! [String], encoding: value["encoding"] as? String)
}
private func selection(_ value: Any?) -> EmbeddingSelection? {
    guard let v = value as? [String: Any] else { return nil }
    return EmbeddingSelection(providerId: v["providerId"] as! String, endpointRevision: v["endpointRevision"] as! String,
        model: v["model"] as! String, modelDigest: v["modelDigest"] as? String, dims: int64(v["dims"]).map(Int.init),
        normalization: v["normalization"] as! String, queryFormatVersion: v["queryFormatVersion"] as! String,
        docFormatVersion: v["docFormatVersion"] as! String, chunkerVersion: v["chunkerVersion"] as! String)
}

@MainActor
final class FolderPublicationTests: XCTestCase {
    private let counter = Counter()
    private var temporary: [URL] = []

    override func tearDown() async throws {
        counter.detach()
    }

    private func cases(_ operation: String) throws -> [[String: Any]] {
        let rows = try XCTUnwrap(SharedFixtures.json("contracts/ingestion-pipeline-v1.json")["cases"] as? [[String: Any]])
        return rows.filter { $0["operation"] as? String == operation }
    }

    // MARK: Seeding and projection

    private func seed(_ store: NotebookStore, _ input: [String: Any]) throws {
        let state = input["seed"] as! [String: Any], folder = input["folder"] as! [String: Any]
        let source = state["source"] as! [String: Any]
        try store.runOnDatabase { db in
            let date = Date(timeIntervalSince1970: 0)
            try db.execute(sql: "INSERT INTO notebooks(id,name,created_at,updated_at) VALUES(?,'pipeline',?,?)",
                           arguments: [int64(input["notebookId"]), date, date])
            let identity = compact(["volumeId": folder["volumeId"]!, "components": folder["components"]!, "rootFileId": folder["rootFileId"]!])
            try db.execute(sql: """
                INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,
                    encoding_fallback,scan_state,scan_generation,created_at) VALUES(?,?,?,?,'Docs',?,?,'{}','cp1250',?,?,?)
                """, arguments: [int64(folder["id"]), int64(folder["notebookId"]), folder["rootPath"] as! String, identity,
                                  compact(FolderRules.defaults.includeExts), compact(FolderRules.defaults.ignoreGlobs),
                                  folder["scanState"] as! String, int64(folder["scanGeneration"]), date])
            let descriptor = source["descriptor"].flatMap { $0 is NSNull ? nil : compact($0) }
            let coverage = source["langCoverage"].flatMap { $0 is NSNull ? nil : compact($0) }
            try db.execute(sql: """
                INSERT INTO sources(id,notebook_id,type,title,status,error,ingested_at,folder_id,rel_path,mtime,size_bytes,
                    availability,eligible,content_hash,encoding,lang,lang_coverage,descriptor) VALUES(?,?,'text','old',?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: [int64(source["id"]), int64(source["notebookId"]), source["status"] as! String, source["error"] as? String,
                                  date, int64(source["folderId"]), source["relPath"] as! String, int64(source["mtimeNs"]),
                                  int64(source["sizeBytes"]), source["availability"] as! String, source["eligible"] as! Bool,
                                  source["contentHash"] as? String, source["encoding"] as? String, source["lang"] as? String,
                                  coverage, descriptor])
            for revision in state["revisions"] as! [[String: Any]] {
                try db.execute(sql: """
                    INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES(?,?,?,?,?,?,?,?)
                    """, arguments: [int64(revision["id"]), int64(revision["sourceId"]), int64(revision["revision"]),
                                      revision["contentHash"] as! String, revision["canonicalText"] as! String,
                                      int64(revision["textFormatVersion"]), int64(revision["chunkerVersion"]), date])
            }
            for chunk in state["chunks"] as! [[String: Any]] {
                try db.execute(sql: """
                    INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count,char_start,char_end,lang,lang_inherited)
                    VALUES(?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [int64(chunk["id"]), int64(chunk["sourceId"]), int64(chunk["revisionId"]), int64(chunk["ordinal"]),
                                      chunk["text"] as! String, int64(chunk["tokens"]), int64(chunk["start"]), int64(chunk["end"]),
                                      chunk["lang"] as? String, chunk["langInherited"] as! Bool])
            }
            for page in state["revisionPages"] as! [[String: Any]] {
                try db.execute(sql: "INSERT INTO revision_pages(revision_id,page,char_start,char_end) VALUES(?,?,?,?)",
                               arguments: [int64(page["revisionId"]), int64(page["page"]), int64(page["start"]), int64(page["end"])])
            }
            try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?",
                           arguments: [int64(source["currentRevision"]), int64(source["publishedRevisionId"]), int64(source["id"])])
            for job in state["jobs"] as! [[String: Any]] {
                try db.execute(sql: """
                    INSERT INTO ingest_jobs(id,kind,target,target_revision,attempts,next_retry_at,state,lease_until,lease_token,error,options_json)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [int64(job["id"]), job["kind"] as! String, job["target"] as! String, int64(job["targetRevision"]),
                                      int64(job["attempts"]), int64(job["nextRetryAt"]), job["state"] as! String, int64(job["leaseUntil"]),
                                      job["leaseToken"] as? String, job["error"] as? String, compact(job["options"] ?? [:])])
            }
            XCTAssertTrue((state["generations"] as! [Any]).isEmpty && (state["manifests"] as! [Any]).isEmpty)
            // Fixture generation IDs are allocated after 5000.
            try db.execute(sql: "DELETE FROM sqlite_sequence WHERE name='index_generations'")
            try db.execute(sql: "INSERT INTO sqlite_sequence(name,seq) VALUES('index_generations',5000)")
        }
    }

    private func projection(_ store: NotebookStore) throws -> [String: Any] {
        try store.runOnDatabase { db in
            let pages = try Row.fetchAll(db, sql: "SELECT * FROM revision_pages ORDER BY revision_id,page")
            func pagesOf(_ revision: Int64?) -> [(page: Int64, start: Int64, end: Int64)] {
                pages.filter { ($0["revision_id"] as Int64) == revision }.map { ($0["page"], $0["char_start"], $0["char_end"]) }
            }
            let chunks = try Row.fetchAll(db, sql: "SELECT * FROM source_chunks ORDER BY id").map { row -> [String: Any] in
                let start: Int64? = row["char_start"], end: Int64? = row["char_end"], revision: Int64? = row["revision_id"]
                let range = pageRange(pagesOf(revision), start, end)
                let inherited: Bool = row["lang_inherited"]
                return ["id": row["id"] as Int64, "sourceId": row["source_id"] as Int64, "revisionId": null(revision),
                        "ordinal": row["ord"] as Int64, "text": row["text"] as String, "tokens": row["token_count"] as Int64,
                        "start": null(start), "end": null(end), "lang": null(row["lang"] as String?), "langInherited": inherited,
                        "pageFrom": range.0, "pageTo": range.1]
            }
            let generations = try Row.fetchAll(db, sql: "SELECT * FROM index_generations ORDER BY id").map { row -> [String: Any] in
                ["id": row["id"] as Int64, "notebookId": row["notebook_id"] as Int64, "state": row["state"] as String,
                 "identity": ["providerId": row["provider_id"] as String, "endpointRevision": row["endpoint_revision"] as String,
                              "model": row["model"] as String, "modelDigest": null(row["model_digest"] as String?),
                              "dims": row["dims"] as Int64, "normalization": row["normalization"] as String,
                              "queryFormatVersion": row["query_format_version"] as String,
                              "docFormatVersion": row["doc_format_version"] as String,
                              "chunkerVersion": row["chunker_version"] as String] as [String: Any]]
            }
            let manifests = try Row.fetchAll(db, sql: "SELECT * FROM index_generation_manifest ORDER BY generation_id,source_id").map {
                ["generationId": $0["generation_id"] as Int64, "sourceId": $0["source_id"] as Int64,
                 "revisionId": $0["revision_id"] as Int64, "state": $0["state"] as String, "reason": null($0["reason"] as String?)] as [String: Any]
            }
            let jobs = try Row.fetchAll(db, sql: "SELECT * FROM ingest_jobs ORDER BY id").map {
                ["id": $0["id"] as Int64, "kind": $0["kind"] as String, "target": $0["target"] as String,
                 "targetRevision": null($0["target_revision"] as Int64?), "attempts": $0["attempts"] as Int64,
                 "nextRetryAt": null($0["next_retry_at"] as Int64?), "state": $0["state"] as String,
                 "leaseUntil": null($0["lease_until"] as Int64?), "leaseToken": null($0["lease_token"] as String?),
                 "error": null($0["error"] as String?), "options": parsed($0["options_json"] as String)] as [String: Any]
            }
            let revisions = try Row.fetchAll(db, sql: "SELECT * FROM source_revisions ORDER BY id").map {
                ["id": $0["id"] as Int64, "sourceId": $0["source_id"] as Int64, "revision": $0["revision"] as Int64,
                 "contentHash": $0["content_hash"] as String, "canonicalText": $0["canonical_text"] as String,
                 "textFormatVersion": $0["text_format_version"] as Int64, "chunkerVersion": $0["chunker_version"] as Int64] as [String: Any]
            }
            let row = try Row.fetchOne(db, sql: "SELECT * FROM sources WHERE id=101")!
            let coverage = parsed(row["lang_coverage"] as String?)
            let eligible: Bool = row["eligible"]
            let source: [String: Any] = [
                "id": row["id"] as Int64, "notebookId": row["notebook_id"] as Int64, "folderId": null(row["folder_id"] as Int64?),
                "relPath": null(row["rel_path"] as String?), "status": row["status"] as String, "error": null(row["error"] as String?),
                "availability": row["availability"] as String, "eligible": eligible,
                "currentRevision": null(row["current_revision"] as Int64?), "publishedRevisionId": null(row["published_revision_id"] as Int64?),
                "contentHash": null(row["content_hash"] as String?), "mtimeNs": null(row["mtime"] as Int64?),
                "sizeBytes": null(row["size_bytes"] as Int64?), "encoding": null(row["encoding"] as String?),
                "lang": null(row["lang"] as String?), "langCoverage": coverage,
                "langCoverageBp": (coverage as? [String: Any])?["langCoverageBp"] ?? NSNull(),
                "descriptor": parsed(row["descriptor"] as String?)]
            return ["chunks": chunks, "generations": generations, "manifests": manifests, "jobs": jobs, "revisions": revisions,
                    "revisionPages": pages.map { ["revisionId": $0["revision_id"] as Int64, "page": $0["page"] as Int64,
                                                  "start": $0["char_start"] as Int64, "end": $0["char_end"] as Int64] as [String: Any] },
                    "source": source, "notificationCount": counter.value]
        }
    }

    private func prepared(_ p: PreparedExtraction) -> [String: Any] {
        let pages = p.document.pages.map { (page: Int64($0.page), start: Int64($0.start), end: Int64($0.end)) }
        let chunks = zip(p.chunks, p.chunkDetections).map { chunk, detection -> [String: Any] in
            let range = pageRange(pages, chunk.charStart.map(Int64.init), chunk.charEnd.map(Int64.init))
            return ["text": chunk.text, "start": null(chunk.charStart), "end": null(chunk.charEnd), "tokens": chunk.tokenCount,
                    "lang": null(chunk.lang), "langInherited": chunk.langInherited, "pageFrom": range.0, "pageTo": range.1,
                    "detection": detection.map { ["label": $0.label, "reason": $0.reason] as [String: Any] } ?? NSNull()]
        }
        let coverage = parsed(p.metadata.coverageJSON)
        return ["canonicalText": p.draft.canonicalText, "chunkerVersion": p.draft.chunkerVersion, "contentHash": p.draft.contentHash,
                "textFormatVersion": p.draft.textFormatVersion, "chunks": chunks,
                "pages": p.document.pages.map { ["page": $0.page, "start": $0.start, "end": $0.end] as [String: Any] },
                "documentDetection": p.documentDetection.map { d -> [String: Any] in
                    ["label": d.label, "reason": d.reason, "langCoverageBp": d.langCoverageBp, "sampledLetters": d.sampledLetters,
                     "sharesBp": d.sharesBp, "unknownShareBp": d.unknownShareBp] } ?? NSNull(),
                "metadata": ["descriptor": parsed(p.metadata.descriptorJSON), "encoding": null(p.metadata.encoding),
                             "lang": null(p.metadata.lang), "langCoverage": coverage,
                             "langCoverageBp": (coverage as? [String: Any])?["langCoverageBp"] ?? NSNull()] as [String: Any]]
    }

    private func runPipeline(_ row: [String: Any]) async throws {
        let name = row["name"] as! String, input = row["input"] as! [String: Any]
        XCTAssertEqual(input["chunker"] as? [String: Int], ["window": 2048, "overlap": 256], name)
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        try seed(store, input)
        counter.detach()
        counter.attach(store)
        let snapshotValue = input["snapshot"] as! [String: Any]
        let bytes = Data((snapshotValue["bytes"] as! [NSNumber]).map(\.uint8Value))
        let file = FileState(bytes: bytes, stamp: FileStamp(identity: "file-1", mtimeNs: 0, sizeBytes: 0), sha256: "")
        let fixtureStamp = (snapshotValue["stamp"] as! [String: Any])
        file.replace(bytes: bytes, stamp: FileStamp(identity: fixtureStamp["identity"] as! String,
            mtimeNs: int64(fixtureStamp["mtimeNs"])!, sizeBytes: int64(fixtureStamp["sizeBytes"])!),
            sha256: snapshotValue["sha256"] as! String)
        let tables = try UnicodeTables.bundled()
        let detector = input["detector"] as? String == "available"
            ? try LanguageDetector(testModelData: JSONSerialization.data(withJSONObject: input["model"]!, options: [.sortedKeys]) + Data([10]), tables: tables)
            : LanguageDetector.unavailable
        let extractor = input["extractor"] as! [String: Any]
        XCTAssertEqual(extractor["kind"] as? String, "injected")
        let canonical = document(extractor["document"] as! [String: Any])
        let embedding = selection(input["embeddingSelection"])
        let clock = FixedClock(0)
        let worker = FolderExtractionWorker(store: store, fileSystem: PipelineFS(file: file), detector: detector, clock: clock,
            embeddingSelection: { _ in embedding }, extract: { _, _, _ in canonical })
        let request = try XCTUnwrap(store.extractionRequest(sourceId: int64(input["sourceId"])!))
        let folder = try store.folderSource(id: int64(input["folderId"])!)
        let fixtureRequest = input["request"] as! [String: Any]
        XCTAssertEqual(try store.job(id: 3001)?.draft.targetRevision, int64(fixtureRequest["expectedCurrentRevision"]), name)
        var snapshot: FolderFileSnapshot?
        var preparedValue: PreparedExtraction?
        defer { snapshot?.close() }
        for event in input["events"] as! [[String: Any]] {
            let operation = event["operation"] as! String, at = int64(event["at"])!
            clock.set(at)
            var result: Any = NSNull()
            switch operation {
            case "snapshot":
                snapshot = try worker.snapshot(request: request, folder: folder)
                result = ["sha256": snapshot!.hash, "stamp": ["identity": snapshot!.stamp.identity,
                          "mtimeNs": snapshot!.stamp.mtimeNs, "sizeBytes": snapshot!.stamp.sizeBytes]]
            case "extract":
                preparedValue = try await worker.prepare(request: request, snapshot: try XCTUnwrap(snapshot))
                result = prepared(preparedValue!)
            case "change-original":
                let value = event["file"] as! [String: Any], stamp = value["stamp"] as! [String: Any]
                file.replace(bytes: Data((value["bytes"] as! [NSNumber]).map(\.uint8Value)),
                             stamp: FileStamp(identity: stamp["identity"] as! String, mtimeNs: int64(stamp["mtimeNs"])!,
                                              sizeBytes: int64(stamp["sizeBytes"])!), sha256: value["sha256"] as! String)
            case "observe":
                XCTAssertEqual(event["transaction"] as? String, "committed-scan-observation")
                let stamp = event["observation"] as! [String: Any]
                let observed = FileStamp(identity: stamp["identity"] as! String, mtimeNs: int64(stamp["mtimeNs"])!,
                                         sizeBytes: int64(stamp["sizeBytes"])!)
                let created = try store.runOnDatabase { db -> Int64? in
                    let queued = try FolderIngestionSQL.observe(db, folder: FolderIngestionSQL.folder(db, id: folder.id),
                        generation: int64(event["scanGeneration"])!, observation: FolderObservation(relPath: request.relPath,
                        stamp: observed, kind: "eligible", skipReason: nil, contentHash: nil), now: at)
                    guard queued != nil else { return nil }
                    return try Int64.fetchOne(db, sql: "SELECT max(id) FROM ingest_jobs WHERE kind='extract'")
                }
                store.notifyFolderIngestionChanged(notebookId: folder.notebookId)
                XCTAssertEqual(try store.job(id: int64(event["cancelJobId"])!)?.state, "cancelled")
                result = ["extractJobId": null(created)]
            case "expire":
                result = ["recovered": try store.recoverExpiredJobs(now: at)]
            case "claim":
                let claimed = try store.claimJob(now: at, leaseToken: event["leaseToken"] as! String, id: int64(event["jobId"])!)
                result = ["claimedJobId": null(claimed?.id)]
            case "publish":
                let fence = event["fence"] as! [String: Any]
                let fault = event["fault"] as? String
                do {
                    let outcome = try await worker.finish(request: request, folder: folder, snapshot: try XCTUnwrap(snapshot),
                        prepared: try XCTUnwrap(preparedValue), selection: embedding,
                        fence: JobFence(jobId: int64(fence["jobId"])!, leaseToken: fence["leaseToken"] as! String),
                        fault: { point in if point == fault { throw InjectedFailure() } })
                    switch outcome {
                    case .published(let id): result = ["accepted": true, "error": NSNull(), "revisionId": id]
                    case .changedDuringExtraction: result = ["accepted": false, "error": "changedDuringExtraction", "revisionId": NSNull()]
                    case .superseded: result = ["accepted": false, "error": NSNull(), "revisionId": NSNull()]
                    }
                } catch is InjectedFailure {
                    result = ["accepted": false, "error": "injectedFailure", "revisionId": NSNull()]
                }
            default:
                XCTFail("unknown pipeline operation \(operation)")
            }
            let expected = event["expected"] as! [String: Any]
            XCTAssertEqual(json(result), json(expected["result"]!), "\(name) \(operation) result")
            XCTAssertEqual(json(try projection(store)), json(expected["state"]!), "\(name) \(operation) state")
        }
        let final = row["expected"] as! [String: Any]
        XCTAssertEqual(json(try projection(store)), json(final["state"]!), "\(name) final")
        XCTAssertEqual(file.snapshotCount, 1, "\(name): the original is copied once")
    }

    // MARK: Tests

    func testDescriptorUsesMetadataWithoutSummary() throws {
        let doc = CanonicalDocument(text: "# Body\nSecret prose", title: "Metadata", kind: "markdown",
            pages: [], sheetNames: [], encoding: "utf-8")
        let descriptor = SourceDescriptor.make(document: doc, filename: "fallback.md", sizeBytes: 32, lang: "cs")
        XCTAssertEqual(descriptor.title, "Metadata")
        XCTAssertEqual(descriptor.lang, "cs")
        let data = try JSONEncoder().encode(descriptor)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set(["version", "title", "type", "pageCount", "sheetCount", "sizeBytes", "lang"]))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Secret prose"))

        let row = try XCTUnwrap(cases("descriptor").first)
        let input = row["input"] as! [String: Any]
        let made = SourceDescriptor.make(document: document(input["document"] as! [String: Any]), filename: input["filename"] as! String,
                                         sizeBytes: int64(input["sizeBytes"])!, lang: input["lang"] as? String)
        XCTAssertEqual(json(parsed(try made.json())), json(row["expected"]!))
        // Title fallbacks: first Markdown heading, then filename; unknown language stays an explicit null.
        let heading = SourceDescriptor.make(document: CanonicalDocument(text: "intro\n# Heading\n", title: " ", kind: "markdown",
            pages: [], sheetNames: [], encoding: nil), filename: "x.md", sizeBytes: 1, lang: nil)
        XCTAssertEqual(heading.title, "Heading")
        XCTAssertTrue(try heading.json().contains(#""lang":null"#))
        XCTAssertEqual(SourceDescriptor.make(document: CanonicalDocument(text: "t", title: nil, kind: "text", pages: [],
            sheetNames: [], encoding: nil), filename: "notes.v2.txt", sizeBytes: 1, lang: "und").title, "notes.v2")
    }

    func testAllPipelineFixtures() async throws {
        let rows = try cases("pipeline")
        var names = Set<String>()
        for row in rows {
            XCTAssertTrue(names.insert(row["name"] as! String).inserted)
            try await runPipeline(row)
        }
        XCTAssertEqual(names.count, 15)
    }

    func testMetadataAndEmbeddingRollback() async throws {
        let row = try XCTUnwrap(cases("pipeline").first { $0["name"] as? String == "metadata-and-embed-atomic" })
        try await runPipeline(row)
        // An earlier fault (after metadata, before the embed job) rolls back the same way.
        let input = row["input"] as! [String: Any]
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        try seed(store, input)
        counter.detach()
        counter.attach(store)
        let before = json(try projection(store))
        let request = try XCTUnwrap(store.extractionRequest(sourceId: 101))
        let draft = RevisionDraft(contentHash: "x", canonicalText: "abc", textFormatVersion: 1, chunkerVersion: 2)
        let metadata = PublicationMetadata(encoding: "utf-8", lang: nil, coverageJSON: nil,
            descriptorJSON: try SourceDescriptor(title: "t", type: "text", pageCount: 1, sheetCount: 0, sizeBytes: 3, lang: nil).json(),
            pages: [PageBoundary(page: 1, start: 0, end: 3)])
        XCTAssertThrowsError(try store.publishFolderExtraction(request: request, draft: draft,
            chunks: ScalarChunker.chunk("abc"), metadata: metadata, embeddingSelection: selection(input["embeddingSelection"]),
            fence: JobFence(jobId: 3001, leaseToken: "owner-a"), now: 12, fault: { if $0 == "after-metadata" { throw InjectedFailure() } }))
        XCTAssertEqual(json(try projection(store)), before, "no partial chunks, descriptor, page map or job")
        // An invalid page map is rejected before anything is written.
        XCTAssertThrowsError(try store.publishFolderExtraction(request: request, draft: draft, chunks: ScalarChunker.chunk("abc"),
            metadata: PublicationMetadata(encoding: nil, lang: nil, coverageJSON: nil, descriptorJSON: metadata.descriptorJSON,
                                          pages: [PageBoundary(page: 1, start: 0, end: 9)]),
            embeddingSelection: nil, fence: JobFence(jobId: 3001, leaseToken: "owner-a"), now: 12)) {
            XCTAssertEqual($0 as? StorageV19Error, .invalidSpan)
        }
        XCTAssertEqual(json(try projection(store)), before)
        // Unknown dimensions: one notebook-target bootstrap job with persisted, nonsecret options.
        let unknown = EmbeddingSelection(providerId: "p", endpointRevision: "e", model: "m", modelDigest: nil, dims: nil,
            normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")
        XCTAssertNotNil(try store.publishFolderExtraction(request: request, draft: draft, chunks: ScalarChunker.chunk("abc"),
            metadata: metadata, embeddingSelection: unknown, fence: JobFence(jobId: 3001, leaseToken: "owner-a"), now: 12))
        let jobs = try store.runOnDatabase { try Row.fetchAll($0, sql: "SELECT target,options_json FROM ingest_jobs WHERE kind='embed'") }
        XCTAssertEqual(jobs.map { $0["target"] as String }, ["notebook:1"])
        XCTAssertEqual(json(parsed(jobs[0]["options_json"] as String)), json(["copyExisting": true, "selection": [
            "providerId": "p", "endpointRevision": "e", "model": "m", "modelDigest": NSNull(), "dims": NSNull(),
            "normalization": "l2", "queryFormatVersion": "1", "docFormatVersion": "1", "chunkerVersion": "2"]] as [String: Any]))
        XCTAssertEqual(try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM index_generations")! }, 0,
                       "dimensions are never inferred from a model name")
        XCTAssertEqual(counter.value, 1, "exactly one notification after the commit")
    }

    func testOriginalChangesDuringExtraction() async throws {
        let row = try XCTUnwrap(cases("pipeline").first { $0["name"] as? String == "stat-changed" })
        let input = row["input"] as! [String: Any]
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        try seed(store, input)
        let snapshotValue = input["snapshot"] as! [String: Any]
        let file = FileState(bytes: Data((snapshotValue["bytes"] as! [NSNumber]).map(\.uint8Value)),
                             stamp: FileStamp(identity: "file-1", mtimeNs: 10, sizeBytes: 9), sha256: snapshotValue["sha256"] as! String)
        let gate = Gate()
        let canonical = document((input["extractor"] as! [String: Any])["document"] as! [String: Any])
        let worker = FolderExtractionWorker(store: store, fileSystem: PipelineFS(file: file), detector: .unavailable,
            clock: FixedClock(13), embeddingSelection: { _ in nil }, extract: { url, kind, _ in
                XCTAssertEqual(kind, .text)
                XCTAssertTrue(url.lastPathComponent.hasSuffix("a.txt"), "extracts the private snapshot copy")
                await gate.wait()
                return canonical
            })
        let job = try XCTUnwrap(store.job(id: 3001))
        let run = Task { try await worker.run(job: job, fence: JobFence(jobId: 3001, leaseToken: "owner-a")) }
        await gate.reached()
        // Same size, different bytes: only the post-extraction streaming hash notices.
        file.replace(bytes: Data("B".utf8), stamp: FileStamp(identity: "file-1", mtimeNs: 10, sizeBytes: 9), sha256: "different")
        gate.release()
        let outcome = try await run.value
        XCTAssertEqual(outcome, .changedDuringExtraction)
        XCTAssertEqual(try store.job(id: 3001)?.state, "cancelled")
        XCTAssertEqual(try store.job(id: 3002)?.state, "queued")
        XCTAssertEqual(try store.job(id: 3002)?.draft.targetRevision, 1001)
        XCTAssertEqual(try store.source(id: 101)?.publishedRevisionId, 1001)
        XCTAssertEqual(try store.chunks(sourceId: 101).map(\.text), ["old"])
        XCTAssertEqual(try store.source(id: 101)?.status, .pending)
        // An expired owner may not create duplicate work after replacement.
        XCTAssertFalse(try store.requestFreshExtraction(sourceId: 101, fence: JobFence(jobId: 3001, leaseToken: "owner-a"), now: 14))
        XCTAssertNil(try store.job(id: 3003))
    }

    func testStaleTokenChangesNothing() async throws {
        try testReclaimedJobRejectsOldCommitWithoutInsertingRows()
        for name in ["expired-owner", "replaced-owner", "new-observation-before-commit"] {
            try await runPipeline(try XCTUnwrap(cases("pipeline").first { $0["name"] as? String == name }))
        }
        // A missing or ineligible source cancels the owned job without extracting.
        let input = try XCTUnwrap(cases("pipeline").first { $0["name"] as? String == "publish-short" })["input"] as! [String: Any]
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        try seed(store, input)
        try store.runOnDatabase { try $0.execute(sql: "UPDATE sources SET eligible=0 WHERE id=101") }
        let file = FileState(bytes: Data(), stamp: FileStamp(identity: "f", mtimeNs: 10, sizeBytes: 9), sha256: "x")
        let worker = FolderExtractionWorker(store: store, fileSystem: PipelineFS(file: file), detector: .unavailable,
            clock: FixedClock(12), embeddingSelection: { _ in nil }, extract: { _, _, _ in XCTFail("no extraction"); throw InjectedFailure() })
        let outcome = try await worker.run(job: try XCTUnwrap(store.job(id: 3001)), fence: JobFence(jobId: 3001, leaseToken: "owner-a"))
        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(try store.job(id: 3001)?.state, "cancelled")
        XCTAssertEqual(file.snapshotCount, 0)
    }

    @MainActor
    func testReclaimedJobRejectsOldCommitWithoutInsertingRows() throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try store.createNotebook(name: "fencing")
        let source = try store.createSource(notebookId: XCTUnwrap(notebook.id), type: .text,
            title: "document", uri: nil, rawPath: nil)
        let sourceId = try XCTUnwrap(source.id)
        let original = try store.commitForegroundRevision(sourceId: sourceId,
            draft: RevisionDraft(contentHash: "old-hash", canonicalText: "old", textFormatVersion: 1, chunkerVersion: 2),
            chunks: [RevisionChunkDraft(text: "old", tokenCount: 1, pageHint: nil,
                charStart: 0, charEnd: 3, lang: nil, langInherited: false)], now: 0, leaseToken: "seed")
        let stale = try store.beginExtraction(sourceId: sourceId, now: 10, leaseToken: "old-owner")
        XCTAssertEqual(try store.recoverExpiredJobs(now: 310), 1)
        let recovered = try XCTUnwrap(store.job(id: stale.jobId))
        XCTAssertEqual(recovered.state, "queued")
        XCTAssertEqual(recovered.nextRetryAt, 370)
        let replacement = try XCTUnwrap(store.claimJob(now: 370, leaseToken: "new-owner", id: stale.jobId))
        XCTAssertEqual(replacement.attempts, 2)
        let current = JobFence(jobId: stale.jobId, leaseToken: "new-owner")
        let next = RevisionDraft(contentHash: "new-hash", canonicalText: "new", textFormatVersion: 1, chunkerVersion: 2)
        let chunks = [RevisionChunkDraft(text: "new", tokenCount: 1, pageHint: nil,
            charStart: 0, charEnd: 3, lang: nil, langInherited: false)]
        XCTAssertNil(try store.commitExtraction(sourceId: sourceId, draft: next, chunks: chunks, fence: stale, now: 371))
        XCTAssertFalse(try store.failJob(fence: stale, error: "late-failure", now: 371))
        let kept = try XCTUnwrap(store.source(id: sourceId))
        XCTAssertEqual(kept.currentRevision, original.id)
        XCTAssertEqual(kept.publishedRevisionId, original.id)
        XCTAssertEqual(try store.chunks(sourceId: sourceId).map(\.text), ["old"])
        XCTAssertEqual(try store.job(id: stale.jobId)?.state, "running")
        XCTAssertEqual(try store.job(id: stale.jobId)?.leaseToken, "new-owner")
        try store.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM source_revisions WHERE source_id=?", arguments: [sourceId]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM source_chunks WHERE source_id=?", arguments: [sourceId]), 1)
        }
        let published = try XCTUnwrap(store.commitExtraction(sourceId: sourceId, draft: next,
            chunks: chunks, fence: current, now: 372))
        XCTAssertEqual(try store.source(id: sourceId)?.publishedRevisionId, published.id)
        XCTAssertEqual(try store.chunks(sourceId: sourceId).map(\.text), ["new"])
        XCTAssertNil(try store.commitExtraction(sourceId: sourceId, draft: next, chunks: chunks, fence: stale, now: 373))
        XCTAssertEqual(try store.revision(id: original.id)?.draft.canonicalText, "old")
        XCTAssertEqual(try store.job(id: stale.jobId)?.state, "done")
        try store.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM source_revisions WHERE source_id=?", arguments: [sourceId]), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM source_chunks WHERE source_id=?", arguments: [sourceId]), 2)
        }
    }

    func testDocumentAndChunkDetection() async throws {
        var names = Set<String>()
        for row in try cases("chunk-language") {
            XCTAssertTrue(names.insert(row["name"] as! String).inserted)
            let input = row["input"] as! [String: Any]
            let language = ChunkLanguage.resolve(label: input["label"] as? String, reason: input["reason"] as? String,
                                                 documentLabel: input["documentLabel"] as? String)
            XCTAssertEqual(json(["lang": null(language.lang), "langInherited": language.langInherited] as [String: Any]),
                           json(row["expected"]!), row["name"] as! String)
        }
        XCTAssertEqual(names.count, 5)
        for name in ["publish-short", "detector-unavailable", "inherit-short", "low-confidence-und", "background-never-inherits",
                     "mixed-document", "und-document"] {
            try await runPipeline(try XCTUnwrap(cases("pipeline").first { $0["name"] as? String == name }))
        }
    }

    func testRevisionPageMapSurvivesRefresh() async throws {
        let row = try XCTUnwrap(cases("pipeline").first { $0["name"] as? String == "revision-page-map-survives-refresh" })
        try await runPipeline(row)
        // The immutable map is read by revision ID, ordered by page, and rejects updates.
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        try seed(store, row["input"] as! [String: Any])
        XCTAssertEqual(try store.revisionPages(revisionId: 1001), [PageBoundary(page: 1, start: 0, end: 3)])
        XCTAssertThrowsError(try store.runOnDatabase { try $0.execute(sql: "UPDATE revision_pages SET char_end=2") })
    }

    func testEmptyRevision() async throws {
        let row = try XCTUnwrap(cases("pipeline").first { $0["name"] as? String == "empty-revision" })
        try await runPipeline(row)
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let input = row["input"] as! [String: Any]
        try seed(store, input)
        let snapshotValue = input["snapshot"] as! [String: Any]
        let file = FileState(bytes: Data(), stamp: FileStamp(identity: "file-1", mtimeNs: 10, sizeBytes: 0), sha256: snapshotValue["sha256"] as! String)
        let canonical = document((input["extractor"] as! [String: Any])["document"] as! [String: Any])
        let worker = FolderExtractionWorker(store: store, fileSystem: PipelineFS(file: file), detector: .unavailable,
            clock: FixedClock(12), embeddingSelection: { _ in nil }, extract: { _, _, _ in canonical })
        let outcome = try await worker.run(job: try XCTUnwrap(store.job(id: 3001)), fence: JobFence(jobId: 3001, leaseToken: "owner-a"))
        XCTAssertEqual(outcome, .published(1002))
        XCTAssertEqual(try store.chunks(sourceId: 101), [])
        let coverage = try store.coverage(notebookId: 1, scope: .all)
        XCTAssertEqual(coverage.searchable, 1)
        XCTAssertEqual(coverage.current, 1)
    }
}

import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private final class Box<Value>: @unchecked Sendable {
    private let gate = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { gate.lock(); defer { gate.unlock() }; return stored }
        set { gate.lock(); stored = newValue; gate.unlock() }
    }
}

private final class GenClock: IngestLeaseClock, @unchecked Sendable {
    private let gate = NSLock()
    private var current: Int64
    private var waiters: [(Int64, CheckedContinuation<Void, Error>)] = []
    init(_ value: Int64) { current = value }
    func now() -> Int64 { gate.lock(); defer { gate.unlock() }; return current }
    func set(_ value: Int64) {
        gate.lock()
        current = value
        let ready = waiters.filter { $0.0 <= value }
        waiters.removeAll { $0.0 <= value }
        gate.unlock()
        for waiter in ready { waiter.1.resume() }
    }
    var pending: Int { gate.lock(); defer { gate.unlock() }; return waiters.count }
    func wait(until deadline: Int64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                gate.lock()
                if Task.isCancelled { gate.unlock(); c.resume(throwing: CancellationError()); return }
                if deadline <= current { gate.unlock(); c.resume(); return }
                waiters.append((deadline, c))
                gate.unlock()
            }
        } onCancel: {
            gate.lock(); let all = waiters; waiters = []; gate.unlock()
            for waiter in all { waiter.1.resume(throwing: CancellationError()) }
        }
    }
}

/// Records background calls; returns scripted vectors and can block before answering.
private final class FakeEmbedder: EmbeddingProducing, @unchecked Sendable {
    private let gate = NSLock()
    private var calls: [[String]] = []
    private var responses: [[[Float]]]
    private var failure: Error?
    init(responses: [[[Float]]], failure: Error? = nil) { self.responses = responses; self.failure = failure }
    var inputs: [[String]] { gate.lock(); defer { gate.unlock() }; return calls }
    private func next(_ inputs: [String]) -> (Error?, [[Float]]) {
        gate.lock(); defer { gate.unlock() }
        calls.append(inputs)
        return (failure, responses.isEmpty ? inputs.map { _ in [1, 0] } : responses.removeFirst())
    }
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        let (failure, response) = next(inputs)
        if let failure { throw failure }
        return response
    }
}

private struct StaticIdentity: FolderPathIdentity {
    let identity: FolderIdentity
    func resolve(rootPath: String) throws -> FolderIdentity { identity }
}

private struct EmptyRootFS: FolderFileSystem {
    func resolve(rootPath: String) throws -> FolderIdentity { FolderIdentity(volumeId: "test", components: ["docs"], rootFileId: "root-1") }
    func caseSensitive(root: FolderSource) throws -> Bool { true }
    func list(root: FolderSource, directory: String) throws -> [FolderEntry] { [] }
    func stat(root: FolderSource, relativePath: String) throws -> FileStamp { FileStamp(identity: "root", mtimeNs: 0, sizeBytes: 0) }
    func hash(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderRead { throw IngestionError(code: "outsideRoot") }
    func snapshot(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderFileSnapshot { throw IngestionError(code: "outsideRoot") }
}

/// The first call blocks until released; every call is recorded.
private final class BlockingEmbedder: EmbeddingProducing, @unchecked Sendable {
    private let gate = NSLock()
    private var calls: [[String]] = []
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private func record(_ inputs: [String]) -> Bool {
        gate.lock(); defer { gate.unlock() }
        calls.append(inputs)
        let ready = arrivals; arrivals = []
        for waiter in ready { waiter.resume() }
        return calls.count == 1 && !released
    }
    var count: Int { gate.lock(); defer { gate.unlock() }; return calls.count }
    func release() {
        gate.lock(); released = true; let ready = waiters; waiters = []; gate.unlock()
        for waiter in ready { waiter.resume() }
    }
    func firstCall() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            gate.lock()
            if !calls.isEmpty { gate.unlock(); c.resume(); return }
            arrivals.append(c)
            gate.unlock()
        }
    }
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        if record(inputs) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                gate.lock()
                if released { gate.unlock(); c.resume(); return }
                waiters.append(c)
                gate.unlock()
            }
        }
        return inputs.indices.map { $0 % 2 == 0 ? [1, 0] : [0, 1] }
    }
}

@MainActor
private func settle(_ label: String, _ condition: () async throws -> Bool) async rethrows {
    for _ in 0..<200_000 {
        if try await condition() { return }
        await Task.yield()
    }
    XCTFail("never settled: \(label)")
}

private func int64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
private func json(_ value: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
}
private func null(_ value: Any?) -> Any { value ?? NSNull() }
private func parsed(_ text: String) -> Any { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? NSNull() }
private func selection(_ value: Any?) -> EmbeddingSelection? {
    guard let v = value as? [String: Any] else { return nil }
    return EmbeddingSelection(providerId: v["providerId"] as! String, endpointRevision: v["endpointRevision"] as! String,
        model: v["model"] as! String, modelDigest: v["modelDigest"] as? String, dims: int64(v["dims"]).map(Int.init),
        normalization: v["normalization"] as! String, queryFormatVersion: v["queryFormatVersion"] as! String,
        docFormatVersion: v["docFormatVersion"] as! String, chunkerVersion: v["chunkerVersion"] as! String)
}
private func selectionJSON(_ s: EmbeddingSelection?) -> Any {
    guard let s else { return NSNull() }
    return ["providerId": s.providerId, "endpointRevision": s.endpointRevision, "model": s.model, "modelDigest": null(s.modelDigest),
            "dims": null(s.dims), "normalization": s.normalization, "queryFormatVersion": s.queryFormatVersion,
            "docFormatVersion": s.docFormatVersion, "chunkerVersion": s.chunkerVersion] as [String: Any]
}
private func identityJSON(_ i: GenerationIdentity) -> [String: Any] {
    ["providerId": i.providerId, "endpointRevision": i.endpointRevision, "model": i.model, "modelDigest": null(i.modelDigest),
     "dims": i.dims, "normalization": i.normalization, "queryFormatVersion": i.queryFormatVersion,
     "docFormatVersion": i.docFormatVersion, "chunkerVersion": i.chunkerVersion]
}

@MainActor
final class FolderGenerationTests: XCTestCase {
    private let identity = GenerationIdentity(providerId: "local", endpointRevision: "1", model: "m", modelDigest: nil,
        dims: 2, normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")

    override func tearDown() async throws {
        MockURLProtocol.handler = nil
    }

    private func cases(_ operation: String) throws -> [[String: Any]] {
        let rows = try XCTUnwrap(SharedFixtures.json("contracts/ingestion-generations-v1.json")["cases"] as? [[String: Any]])
        return rows.filter { $0["operation"] as? String == operation }
    }

    // MARK: Plan regressions

    func testReindexDoesNotActivateEmptyBuild() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "index")
        let id = try store.requestReindex(notebookId: nb.id!, identity: identity, now: 0)
        XCTAssertEqual(try store.generation(id: id)?.state, "building")
        XCTAssertNil(try store.activeGeneration(notebookId: nb.id!))
        XCTAssertEqual(try store.generationProgress(notebookId: nb.id!).generationId, id)
    }

    func testReindexLeavesActiveRevisionAndVectorsAvailable() throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let nb = try store.createNotebook(name: "active")
        let source = try store.createSource(notebookId: nb.id!, type: .text, title: "doc", uri: nil, rawPath: nil)
        let revision = try store.commitForegroundRevision(sourceId: source.id!, draft: RevisionDraft(
            contentHash: "h", canonicalText: "kept", textFormatVersion: 1, chunkerVersion: 2),
            chunks: ScalarChunker.chunk("kept"), now: 0, leaseToken: "seed")
        let active = try store.createGeneration(notebookId: nb.id!, identity: identity, now: 0)
        try store.setManifest(generationId: active.id, entries: [ManifestEntry(sourceId: source.id!, revisionId: revision.id, state: "pending", reason: nil)])
        let chunk = try XCTUnwrap(store.chunks(sourceId: source.id!).first)
        try store.storeGenerationEmbedding(generationId: active.id, chunkId: chunk.id!, vector: EmbeddingVector(values: [1, 0]))
        try store.setManifest(generationId: active.id, entries: [ManifestEntry(sourceId: source.id!, revisionId: revision.id, state: "done", reason: nil)])
        try store.activateGeneration(id: active.id, now: 1)
        let build = try store.requestReindex(notebookId: nb.id!, identity: identity, now: 2)
        XCTAssertNotEqual(build, active.id)
        XCTAssertEqual(try store.activeGeneration(notebookId: nb.id!)?.id, active.id)
        XCTAssertEqual(try store.manifest(generationId: active.id).first?.revisionId, revision.id)
        XCTAssertEqual(try store.chunks(sourceId: source.id!).map(\.text), ["kept"])
        try store.discardBuildingGeneration(id: build, now: 3)
        XCTAssertEqual(try store.activeGeneration(notebookId: nb.id!)?.id, active.id)
        XCTAssertEqual(try store.source(id: source.id!)?.publishedRevisionId, revision.id)
    }

    // MARK: Generation trace harness

    private func seedGeneration(_ store: NotebookStore, _ input: [String: Any]) throws {
        let seed = input["seed"] as! [String: Any]
        try store.runOnDatabase { db in
            let date = Date(timeIntervalSince1970: 0)
            for id in input["notebookIds"] as! [NSNumber] {
                try db.execute(sql: "INSERT INTO notebooks(id,name,created_at,updated_at) VALUES(?,?,?,?)", arguments: [id.int64Value, "nb", date, date])
            }
            for id in input["folderIds"] as! [NSNumber] {
                try db.execute(sql: """
                    INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,created_at)
                    VALUES(?,1,'/docs','{"volumeId":"test","components":["docs"],"rootFileId":"root-1"}','Docs','["md"]','[]','{}',?)
                    """, arguments: [id.int64Value, date])
            }
            for source in seed["sources"] as! [[String: Any]] {
                let id = int64(source["id"])!
                try db.execute(sql: """
                    INSERT INTO sources(id,notebook_id,type,title,status,ingested_at,folder_id,rel_path,availability,eligible)
                    VALUES(?,?,'text','s',?,?,?,?,?,?)
                    """, arguments: [id, int64(source["notebookId"]), source["status"] as! String, date, int64(source["folderId"]),
                                      int64(source["folderId"]) == nil ? nil : "s\(id).md", source["availability"] as! String,
                                      source["eligible"] as! Bool])
            }
            var ordinals: [Int64: Int] = [:]
            for revision in seed["revisions"] as! [[String: Any]] {
                let source = int64(revision["sourceId"])!
                ordinals[source, default: 0] += 1
                try db.execute(sql: """
                    INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES(?,?,?,'h',?,?,?,?)
                    """, arguments: [int64(revision["id"]), source, ordinals[source]!, revision["canonicalText"] as! String,
                                      int64(revision["textFormatVersion"]), int64(revision["chunkerVersion"]), date])
                for (ord, chunk) in (revision["chunks"] as! [[String: Any]]).enumerated() {
                    try db.execute(sql: """
                        INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count,char_start,char_end) VALUES(?,?,?,?,?,?,?,?)
                        """, arguments: [int64(chunk["id"]), source, int64(revision["id"]), ord, chunk["text"] as! String,
                                          int64(chunk["tokenCount"]), int64(chunk["start"]), int64(chunk["end"])])
                }
            }
            for source in seed["sources"] as! [[String: Any]] {
                try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?",
                               arguments: [int64(source["currentRevision"]), int64(source["publishedRevisionId"]), int64(source["id"])])
            }
            for generation in seed["generations"] as! [[String: Any]] {
                let i = generation["identity"] as! [String: Any], id = int64(generation["id"])!
                try db.execute(sql: """
                    INSERT INTO index_generations(id,notebook_id,provider_id,endpoint_revision,model,model_digest,dims,normalization,
                        query_format_version,doc_format_version,chunker_version,state,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [id, int64(generation["notebookId"]), i["providerId"] as! String, i["endpointRevision"] as! String,
                                      i["model"] as! String, i["modelDigest"] as? String, int64(i["dims"]), i["normalization"] as! String,
                                      i["queryFormatVersion"] as! String, i["docFormatVersion"] as! String, i["chunkerVersion"] as! String,
                                      generation["state"] as! String, date])
                for entry in generation["manifest"] as! [[String: Any]] {
                    try db.execute(sql: "INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state,reason) VALUES(?,?,?,?,?)",
                                   arguments: [id, int64(entry["sourceId"]), int64(entry["revisionId"]), entry["state"] as! String, entry["reason"] as? String])
                }
                for vector in generation["vectors"] as! [[String: Any]] {
                    let values = (vector["values"] as! [NSNumber]).map(\.floatValue)
                    try db.execute(sql: "INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES(?,?,?)",
                                   arguments: [int64(vector["chunkId"]), id, EmbeddingVector(values: values).asData()])
                }
            }
            for job in seed["jobs"] as! [[String: Any]] {
                try db.execute(sql: """
                    INSERT INTO ingest_jobs(id,kind,target,target_revision,attempts,next_retry_at,state,lease_until,lease_token,error,options_json)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [int64(job["id"]), job["kind"] as! String, job["target"] as! String, int64(job["targetRevision"]),
                                      int64(job["attempts"]), int64(job["nextRetryAt"]), job["state"] as! String, int64(job["leaseUntil"]),
                                      job["leaseToken"] as? String, job["error"] as? String,
                                      String(decoding: try JSONSerialization.data(withJSONObject: job["options"] ?? [:], options: [.sortedKeys]), as: UTF8.self)])
            }
            // Fixture IDs: new generations start at 20 and new jobs at 301.
            let maxGeneration = try Int64.fetchOne(db, sql: "SELECT coalesce(max(id),0) FROM index_generations")!
            let maxJob = try Int64.fetchOne(db, sql: "SELECT coalesce(max(id),0) FROM ingest_jobs")!
            try db.execute(sql: "DELETE FROM sqlite_sequence WHERE name IN ('index_generations','ingest_jobs')")
            try db.execute(sql: "INSERT INTO sqlite_sequence(name,seq) VALUES('index_generations',?),('ingest_jobs',?)",
                           arguments: [max(19, maxGeneration), max(300, maxJob)])
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT id FROM index_generations WHERE state='active'"), int64(seed["activeGenerationId"]))
        }
    }

    private struct TraceState {
        var inFlight: [[String: Any]] = []
        var requests: [[String: Any]] = []
        var providerCalls = 0
        var queryCalls = 0
        var retrieval: Any = NSNull()
        var pins: [String: QueryPin] = [:]
        var pinOrder: [String] = []
        var chatTokens: [String: UUID] = [:]
        var chatOrder: [String] = []
        var revisionOrder: [Int64] = []
    }

    private func generationProjection(_ store: NotebookStore, _ state: TraceState, selected: EmbeddingSelection?) throws -> [String: Any] {
        try store.runOnDatabase { db in
            let generations = try Row.fetchAll(db, sql: "SELECT id FROM index_generations ORDER BY id").map { row -> [String: Any] in
                let id: Int64 = row["id"]
                let generation = try GenerationSQL.generation(db, id: id)!
                let manifest = try Row.fetchAll(db, sql: "SELECT * FROM index_generation_manifest WHERE generation_id=? ORDER BY source_id", arguments: [id]).map {
                    ["sourceId": $0["source_id"] as Int64, "revisionId": $0["revision_id"] as Int64, "state": $0["state"] as String,
                     "reason": null($0["reason"] as String?)] as [String: Any]
                }
                let vectors = try Row.fetchAll(db, sql: """
                    SELECT e.chunk_id,c.revision_id,e.embedding FROM chunk_embeddings e JOIN source_chunks c ON c.id=e.chunk_id
                    WHERE e.generation_id=? ORDER BY e.chunk_id
                    """, arguments: [id]).map { row -> [String: Any] in
                    let values = try EmbeddingVector(data: row["embedding"]).values.map(Double.init)
                    return ["chunkId": row["chunk_id"] as Int64, "revisionId": row["revision_id"] as Int64, "values": values]
                }
                return ["id": id, "notebookId": generation.notebookId, "state": generation.state,
                        "identity": identityJSON(generation.identity), "manifest": manifest, "vectors": vectors]
            }
            let jobs = try Row.fetchAll(db, sql: "SELECT * FROM ingest_jobs ORDER BY id").map {
                ["id": $0["id"] as Int64, "kind": $0["kind"] as String, "target": $0["target"] as String,
                 "targetRevision": null($0["target_revision"] as Int64?), "attempts": $0["attempts"] as Int64,
                 "nextRetryAt": null($0["next_retry_at"] as Int64?), "state": $0["state"] as String,
                 "leaseUntil": null($0["lease_until"] as Int64?), "leaseToken": null($0["lease_token"] as String?),
                 "error": null($0["error"] as String?), "options": parsed($0["options_json"] as String)] as [String: Any]
            }
            // Fixture order: seeded revisions as listed, then new ones by ID.
            let rank = { (id: Int64) -> (Int, Int64) in (state.revisionOrder.firstIndex(of: id) ?? Int.max, id) }
            let revisionRows = try Row.fetchAll(db, sql: "SELECT * FROM source_revisions").sorted {
                rank($0["id"] as Int64) < rank($1["id"] as Int64)
            }
            let revisions = try revisionRows.map { row -> [String: Any] in
                let id: Int64 = row["id"]
                let chunks = try Row.fetchAll(db, sql: "SELECT * FROM source_chunks WHERE revision_id=? ORDER BY ord", arguments: [id]).map {
                    ["id": $0["id"] as Int64, "text": $0["text"] as String, "start": null($0["char_start"] as Int64?),
                     "end": null($0["char_end"] as Int64?), "tokenCount": $0["token_count"] as Int64] as [String: Any]
                }
                return ["id": id, "sourceId": row["source_id"] as Int64, "canonicalText": row["canonical_text"] as String,
                        "chunkerVersion": row["chunker_version"] as Int64, "textFormatVersion": row["text_format_version"] as Int64,
                        "chunks": chunks]
            }
            let sources = try Row.fetchAll(db, sql: "SELECT * FROM sources ORDER BY id").map { row -> [String: Any] in
                let eligible: Bool = row["eligible"]
                return ["id": row["id"] as Int64, "notebookId": row["notebook_id"] as Int64, "folderId": null(row["folder_id"] as Int64?),
                        "status": row["status"] as String, "availability": row["availability"] as String, "eligible": eligible,
                        "currentRevision": null(row["current_revision"] as Int64?),
                        "publishedRevisionId": null(row["published_revision_id"] as Int64?)]
            }
            let active = try Int64.fetchOne(db, sql: "SELECT id FROM index_generations WHERE state='active'")
            let pins = state.pinOrder.compactMap { token -> [String: Any]? in
                guard let pin = state.pins[token] else { return nil }
                return ["token": token, "generationId": null(pin.generationId),
                        "sourceRevisions": pin.vectorRevisions.keys.sorted().map { ["sourceId": $0, "revisionId": pin.vectorRevisions[$0]!] }]
            }
            return ["activeGenerationId": null(active), "chatTokens": state.chatOrder, "generations": generations,
                    "inFlightBatches": state.inFlight, "jobs": jobs, "pins": pins, "providerCallCount": state.providerCalls,
                    "providerRequests": state.requests, "queryProviderCallCount": state.queryCalls, "retrieval": state.retrieval,
                    "revisions": revisions, "selectedSelection": selectionJSON(selected), "sources": sources]
        }
    }

    private func runGeneration(_ row: [String: Any]) async throws {
        let name = row["name"] as! String, input = row["input"] as! [String: Any]
        XCTAssertTrue([1, Int64(FolderIndexCoordinator.batchSize)].contains(int64(input["batchSize"])!), name)
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        try seedGeneration(store, input)
        let seed = input["seed"] as! [String: Any]
        let selected = Box(selection(seed["selectedSelection"]))
        let admission = IngestionAdmission()
        let clock = GenClock(0)
        let coordinator = FolderIndexCoordinator(store: store, admission: admission, clock: clock,
            session: { _ in nil }, selectedSelection: { _ in selected.value }, batchSize: Int(int64(input["batchSize"])!))
        var state = TraceState()
        state.revisionOrder = (seed["revisions"] as! [[String: Any]]).map { int64($0["id"])! }
        state.inFlight = seed["inFlightBatches"] as! [[String: Any]]
        state.requests = seed["providerRequests"] as! [[String: Any]]
        state.providerCalls = Int(int64(seed["providerCallCount"])!)
        state.queryCalls = Int(int64(seed["queryProviderCallCount"])!)
        XCTAssertTrue((seed["pins"] as! [Any]).isEmpty && (seed["chatTokens"] as! [Any]).isEmpty, name)
        let url = try ProviderAPIRoot.build(type: .ollama, baseURL: "http://localhost:11434", endpoint: .embeddings).absoluteString
        func request(_ batchId: String, _ kind: String, _ chunkIds: [Int64], _ revisionIds: [Int64], _ inputs: [String],
                     _ selection: EmbeddingSelection) -> [String: Any] {
            XCTAssertEqual(selection.endpointRevision, EmbeddingEndpointRevision.make(type: .ollama, normalizedRoot: "http://localhost:11434"), name)
            return ["batchId": batchId, "chunkIds": chunkIds, "endpointRevision": selection.endpointRevision, "inputs": inputs,
                    "kind": kind, "model": selection.model, "providerId": selection.providerId, "revisionIds": revisionIds, "url": url]
        }
        func jobSelection(_ jobId: Int64) throws -> (EmbeddingSelection, Bool, IngestJob) {
            let job = try XCTUnwrap(store.job(id: jobId))
            let (selection, copy) = try EmbeddingSelection.fromOptions(job.draft.optionsJSON)
            return (selection, copy, job)
        }
        for event in input["events"] as! [[String: Any]] {
            let operation = event["operation"] as! String, at = int64(event["at"])!
            clock.set(at)
            let fence = (int64(event["jobId"]), event["leaseToken"] as? String)
            switch operation {
            case "request-build":
                let id = try store.requestEmbeddingBuild(notebookId: int64(event["notebookId"])!, selection: try XCTUnwrap(selection(event["selection"])),
                                                         copyExisting: event["copyExisting"] as! Bool, now: at)
                XCTAssertEqual(id, int64(event["jobId"]), name)
                if let generationId = int64(event["generationId"]) {
                    XCTAssertEqual(try store.job(id: id)?.draft.target, "generation:\(generationId)", name)
                }
            case "claim":
                XCTAssertNotNil(try store.claimJob(now: at, leaseToken: fence.1!, id: fence.0!), name)
            case "begin-batch":
                guard await admission.snapshot().chatTokens.isEmpty else { break } // the batch waits for chat
                let (selection, _, job) = try jobSelection(fence.0!)
                let generationId = job.draft.target.hasPrefix("generation:") ? Int64(job.draft.target.dropFirst("generation:".count)) : nil
                let batch = try await coordinator.capture(notebookId: 1, generationId: generationId)
                XCTAssertEqual(batch?.chunkIds, (event["chunkIds"] as! [NSNumber]).map(\.int64Value), name)
                XCTAssertEqual(batch?.revisionIds, (event["revisionIds"] as! [NSNumber]).map(\.int64Value), name)
                let value = request(event["batchId"] as! String, "background", batch!.chunkIds, batch!.revisionIds, batch!.inputs, selection)
                state.requests.append(value)
                state.inFlight.append(value)
                state.providerCalls += 1
            case "commit-batch":
                let batchId = event["batchId"] as! String
                let flight = try XCTUnwrap(state.inFlight.first { $0["batchId"] as? String == batchId }, name)
                state.inFlight.removeAll { $0["batchId"] as? String == batchId }
                let (durable, copy, job) = try jobSelection(fence.0!)
                let generationId = job.draft.target.hasPrefix("generation:") ? Int64(job.draft.target.dropFirst("generation:".count)) : nil
                let chunkIds = (flight["chunkIds"] as! [NSNumber]).map(\.int64Value), revisions = (flight["revisionIds"] as! [NSNumber]).map(\.int64Value)
                let texts = flight["inputs"] as! [String]
                let batch = CapturedEmbeddingBatch(notebookId: 1, generationId: generationId, items: chunkIds.indices.map {
                    EmbeddingBatchItem(chunkId: chunkIds[$0], sourceId: 0, revisionId: revisions[$0], text: texts[$0])
                })
                let vectors = (event["vectors"] as! [[Any]]).map { $0.map { ($0 as? NSNumber)?.floatValue ?? .nan } }
                let session = FolderEmbeddingSession(selection: durable, embedder: FakeEmbedder(responses: []))
                let outcome = try await coordinator.commit(batch, vectors: vectors, session: session, copyExisting: copy,
                                                           fence: JobFence(jobId: fence.0!, leaseToken: fence.1!))
                if let expectedGeneration = int64(event["generationId"]), case .bootstrapped(let created) = outcome {
                    XCTAssertEqual(created, expectedGeneration, name)
                }
            case "activate":
                let generation = try XCTUnwrap(store.generation(id: int64(event["generationId"])!))
                let current = try XCTUnwrap(selected.value)
                let identity = GenerationIdentity(providerId: current.providerId, endpointRevision: current.endpointRevision,
                    model: current.model, modelDigest: current.modelDigest, dims: current.dims ?? generation.identity.dims,
                    normalization: current.normalization, queryFormatVersion: current.queryFormatVersion,
                    docFormatVersion: current.docFormatVersion, chunkerVersion: current.chunkerVersion)
                _ = try store.activateBuiltGeneration(id: generation.id, selectedIdentity: identity,
                                                      fence: JobFence(jobId: fence.0!, leaseToken: fence.1!), now: at)
            case "publish-revision":
                let revision = event["revision"] as! [String: Any], sourceId = int64(event["sourceId"])!
                let chunks = revision["chunks"] as! [[String: Any]]
                let extract = try store.enqueueJob(IngestJobDraft(kind: "extract", target: "source:\(sourceId)",
                    targetRevision: int64(event["expectedCurrentRevision"])), now: at)
                XCTAssertEqual(extract, int64(event["extractJobId"]), name)
                XCTAssertNotNil(try store.claimJob(now: at, leaseToken: event["leaseToken"] as! String, id: extract))
                let current = try XCTUnwrap(selected.value)
                try store.runOnDatabase { db in
                    // Fixture revision/chunk IDs.
                    try db.execute(sql: "UPDATE sqlite_sequence SET seq=? WHERE name='source_revisions'", arguments: [int64(revision["id"])! - 1])
                    try db.execute(sql: "UPDATE sqlite_sequence SET seq=? WHERE name='source_chunks'", arguments: [int64(chunks[0]["id"])! - 1])
                    let published = try RevisionJobSQL.commitExtraction(db, sourceId: sourceId, draft: RevisionDraft(contentHash: "h2",
                        canonicalText: revision["canonicalText"] as! String, textFormatVersion: 1, chunkerVersion: 2),
                        chunks: chunks.map { RevisionChunkDraft(text: $0["text"] as! String, tokenCount: Int(int64($0["tokenCount"])!),
                            pageHint: nil, charStart: Int(int64($0["start"])!), charEnd: Int(int64($0["end"])!), lang: nil, langInherited: false) },
                        fence: JobFence(jobId: extract, leaseToken: event["leaseToken"] as! String), now: at)
                    XCTAssertEqual(published?.id, int64(revision["id"]))
                    _ = try IngestionGenerationSQL.enqueueBuild(db, notebookId: 1, selection: current, copyExisting: true, now: at)
                }
            case "recover-expired":
                _ = try store.recoverExpiredJobs(now: at)
            case "renew":
                XCTAssertTrue(try store.renewJob(fence: JobFence(jobId: fence.0!, leaseToken: fence.1!), now: at), name)
            case "begin-chat":
                let token = UUID()
                state.chatTokens[event["token"] as! String] = token
                state.chatOrder.append(event["token"] as! String)
                await admission.beginChat(token: token)
            case "end-chat":
                await admission.endChat(state.chatTokens[event["token"] as! String]!)
                state.chatOrder.removeAll { $0 == event["token"] as? String }
            case "query-embedding":
                // The question path calls the provider directly, never the background gate.
                let current = try XCTUnwrap(selected.value)
                state.requests.append(request(event["batchId"] as! String, "query", [], [], [event["text"] as! String], current))
                state.providerCalls += 1
                state.queryCalls += 1
            case "provider-failure":
                state.inFlight.removeAll { $0["batchId"] as? String == event["batchId"] as? String }
                XCTAssertTrue(try store.failEmbeddingJob(fence: JobFence(jobId: fence.0!, leaseToken: fence.1!),
                                                         error: event["error"] as! String, now: at), name)
            case "discard":
                try await coordinator.discard(generationId: int64(event["generationId"])!)
            case "change-selection":
                selected.value = selection(event["selection"])
            case "invalidate-selection":
                XCTAssertTrue(try store.invalidateEmbeddingSelection(fence: JobFence(jobId: fence.0!, leaseToken: fence.1!), now: at), name)
            case "retrieve":
                XCTAssertEqual(json(event["scope"]!), json(["kind": "all"]))
                state.retrieval = try retrieval(store, notebookId: int64(event["notebookId"])!)
            case "set-eligibility":
                try store.runOnDatabase { try $0.execute(sql: "UPDATE sources SET eligible=? WHERE id=?",
                                                         arguments: [event["eligible"] as! Bool, int64(event["sourceId"])]) }
            case "pin":
                let active = try XCTUnwrap(store.activeGeneration(notebookId: 1))
                let pin = try store.pinQuery(notebookId: 1, modelKey: active.identity.modelKey)
                XCTAssertEqual(pin.generationId, int64(event["generationId"]), name)
                state.pins[event["token"] as! String] = pin
                state.pinOrder.append(event["token"] as! String)
            case "unpin":
                let token = event["token"] as! String
                store.releaseQuery(try XCTUnwrap(state.pins[token]))
                state.pins[token] = nil
                state.pinOrder.removeAll { $0 == token }
            case "gc":
                _ = try store.garbageCollect(notebookId: 1)
            case "finish-empty":
                let batch = try await coordinator.capture(notebookId: 1, generationId: nil)
                XCTAssertNil(batch, name)
                XCTAssertTrue(try store.completeEmptyBootstrap(fence: JobFence(jobId: fence.0!, leaseToken: fence.1!), now: at), name)
            default:
                XCTFail("unknown generation operation \(operation)")
            }
            let expected = event["expected"] as! [String: Any]
            XCTAssertEqual(json(try generationProjection(store, state, selected: selected.value)), json(expected), "\(name) \(operation) @\(at)")
        }
        for (_, pin) in state.pins { store.releaseQuery(pin) }
    }

    /// Contract §1 projection: lexical = eligible published chunks; vectors via a real pin.
    private func retrieval(_ store: NotebookStore, notebookId: Int64) throws -> [String: Any] {
        let lexical = try store.runOnDatabase { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id,s.id AS source_id,s.published_revision_id FROM sources s JOIN source_chunks c ON c.revision_id=s.published_revision_id
                WHERE s.notebook_id=? AND s.availability='present' AND s.eligible=1 ORDER BY c.id
                """, arguments: [notebookId])
        }
        var pairs: [Int64: Int64] = [:]
        for row in lexical { pairs[row["source_id"]] = row["published_revision_id"] }
        var vectorIds: [Int64] = []
        if let active = try store.activeGeneration(notebookId: notebookId) {
            let pin = try store.pinQuery(notebookId: notebookId, modelKey: active.identity.modelKey)
            vectorIds = try store.pinnedEmbeddings(pin).map(\.chunkId)
            store.releaseQuery(pin)
        }
        return ["lexicalChunkIds": lexical.map { $0["id"] as Int64 },
                "sourceRevisionPairs": pairs.keys.sorted().map { ["sourceId": $0, "revisionId": pairs[$0]!] },
                "vectorChunkIds": vectorIds]
    }

    private func runReconcile(_ row: [String: Any]) async throws {
        let name = row["name"] as! String, input = row["input"] as! [String: Any]
        let seed = input["seed"] as! [String: Any]
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        try store.runOnDatabase { db in
            let date = Date(timeIntervalSince1970: 0)
            for id in seed["notebookIds"] as! [NSNumber] {
                try db.execute(sql: "INSERT INTO notebooks(id,name,created_at,updated_at) VALUES(?,?,?,?)", arguments: [id.int64Value, "nb", date, date])
            }
            for folder in seed["folders"] as! [[String: Any]] {
                let id = int64(folder["id"])!
                try db.execute(sql: """
                    INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,
                        watch_enabled,scan_state,scan_generation,last_full_scan_at,created_at) VALUES(?,?,?,?,'Docs','["md"]','[]','{}',?,?,?,?,?)
                    """, arguments: [id, int64(folder["notebookId"]), "/docs\(id)",
                                      #"{"volumeId":"test","components":["docs\#(id)"],"rootFileId":"root-\#(id)"}"#,
                                      folder["watchEnabled"] as! Bool, folder["scanState"] as! String, int64(folder["scanGeneration"]),
                                      int64(folder["lastFullScanAt"]), date])
            }
            try db.execute(sql: "INSERT INTO sqlite_sequence(name,seq) VALUES('ingest_jobs',?)", arguments: [int64(input["nextJobId"])! - 1])
        }
        let clock = GenClock(0)
        let reconciler = FolderReconciler(store: store, clock: clock, requestScan: { folderId, verifyAll in
            _ = try await MainActor.run { try store.requestFolderScan(folderId: folderId, verifyAll: verifyAll, now: clock.now()) }
        })
        func projection() async throws -> [String: Any] {
            let next = await reconciler.nextReconcileAt, running = await reconciler.running
            return try store.runOnDatabase { db in
                let folders = try Row.fetchAll(db, sql: "SELECT * FROM folder_sources ORDER BY id").map { row -> [String: Any] in
                    let watch: Bool = row["watch_enabled"]
                    return ["id": row["id"] as Int64, "notebookId": row["notebook_id"] as Int64, "watchEnabled": watch,
                            "scanState": row["scan_state"] as String, "scanGeneration": row["scan_generation"] as Int64,
                            "lastFullScanAt": null(row["last_full_scan_at"] as Int64?)]
                }
                let jobs = try Row.fetchAll(db, sql: "SELECT * FROM ingest_jobs ORDER BY id").map {
                    ["id": $0["id"] as Int64, "kind": $0["kind"] as String, "target": $0["target"] as String,
                     "targetRevision": null($0["target_revision"] as Int64?), "attempts": $0["attempts"] as Int64,
                     "nextRetryAt": null($0["next_retry_at"] as Int64?), "state": $0["state"] as String,
                     "leaseUntil": null($0["lease_until"] as Int64?), "leaseToken": null($0["lease_token"] as String?),
                     "error": null($0["error"] as String?), "options": parsed($0["options_json"] as String)] as [String: Any]
                }
                let notebooks = try Int64.fetchAll(db, sql: "SELECT id FROM notebooks ORDER BY id")
                return ["folders": folders, "jobs": jobs, "nextReconcileAt": null(next), "notebookIds": notebooks,
                        "providerCallCount": 0, "running": running, "sources": []]
            }
        }
        let initial = try await projection()
        XCTAssertEqual(json(initial), json(seed), "\(name) seed")
        for event in input["events"] as! [[String: Any]] {
            let operation = event["operation"] as! String, at = int64(event["at"])!
            clock.set(at)
            switch operation {
            case "start": try await reconciler.start()
            case "tick": try await reconciler.tick(now: at)
            case "complete-scan":
                XCTAssertTrue((event["entries"] as! [Any]).isEmpty)
                let id = int64(event["jobId"])!, token = event["leaseToken"] as! String
                XCTAssertNotNil(try store.claimJob(now: at, leaseToken: token, id: id))
                try await FolderScanner(store: store, fileSystem: EmptyRootFS(), tables: UnicodeTables.bundled(), clock: clock)
                    .scan(folderId: int64(event["folderId"])!, verifyAll: try store.scanOptions(jobId: id),
                          fence: JobFence(jobId: id, leaseToken: token), now: at, cancelled: { false })
            case "manual-scan":
                let id = try store.requestFolderScan(folderId: int64(event["folderId"])!, verifyAll: event["verifyAll"] as! Bool, now: at)
                XCTAssertEqual(id, int64(event["jobId"]), name)
            default: XCTFail("unknown reconcile operation \(operation)")
            }
            let value = try await projection()
            XCTAssertEqual(json(value), json(event["expected"]!), "\(name) \(operation) @\(at)")
        }
        await reconciler.stop()
    }

    private func runSession(_ row: [String: Any]) async throws {
        let name = row["name"] as! String, input = row["input"] as! [String: Any]
        let c = input["config"] as! [String: Any]
        var config = ProviderConfig(id: c["id"] as! String, type: ProviderType.fromStorage(c["type"] as! String), name: "Remote",
                                    baseURL: c["baseURL"] as! String, enabled: c["enabled"] as! Bool,
                                    privacyAcknowledged: c["privacyAcknowledged"] as! Bool)
        let apiKey = input["apiKey"] as? String
        var captured: FolderEmbeddingSession?
        var state: [String: Any] = input["seed"] as! [String: Any]
        let requests = Box<[[String: Any]]>([])
        let mockSession = makeMockSession()
        func capture(key: String?) throws -> FolderEmbeddingSession {
            try FolderEmbeddingSession(config: config, model: input["model"] as! String, apiKey: key,
                modelDigest: input["modelDigest"] as? String, queryFormatVersion: input["queryFormatVersion"] as! String,
                docFormatVersion: input["docFormatVersion"] as! String, session: mockSession)
        }
        for event in input["events"] as! [[String: Any]] {
            let operation = event["operation"] as! String
            switch operation {
            case "capture":
                do {
                    captured = try capture(key: apiKey)
                    state["selection"] = selectionJSON(captured!.selection)
                    XCTAssertFalse(String(describing: captured!).contains(apiKey ?? "\u{0}"), name)
                } catch {
                    state["error"] = (error as? IngestionError)?.code ?? "\(error)"
                }
            case "mutate-config":
                config.baseURL = event["baseURL"] as! String
                state["selection"] = selectionJSON(captured!.selection)
            case "rotate-key":
                let rotated = try capture(key: event["apiKey"] as? String)
                XCTAssertEqual(rotated.selection, captured!.selection, "\(name): key rotation keeps the vector space")
            case "embed":
                let vectors = event["responseVectors"] as! [[NSNumber]]
                MockURLProtocol.handler = { request in
                    let body = try JSONSerialization.jsonObject(with: request.bodyData ?? Data()) as! [String: Any]
                    requests.value.append(["url": request.url!.absoluteString, "model": body["model"] as! String,
                                           "inputs": body["input"] as! [String],
                                           "authorization": request.value(forHTTPHeaderField: "Authorization") ?? NSNull()])
                    let data = try JSONSerialization.data(withJSONObject: ["data": vectors.map { ["embedding": $0] }])
                    return (httpResponse(request.url!, status: 200), data)
                }
                let response = try await captured!.embed(inputs: event["inputs"] as! [String])
                let dims = try validatedDimensions(response, count: (event["inputs"] as! [String]).count)
                state["identity"] = identityJSON(try captured!.identity(dims: dims))
                state["requests"] = requests.value
            case "serialize":
                let options = try captured!.selection.optionsJSON(copyExisting: event["copyExisting"] as! Bool)
                XCTAssertFalse(options.contains(apiKey ?? "\u{0}"), "\(name): no secret in durable options")
                state["durableOptions"] = parsed(options)
            default: XCTFail("unknown session operation \(operation)")
            }
            XCTAssertEqual(json(state), json(event["expected"]!), "\(name) \(operation)")
        }
        XCTAssertEqual(json(state), json(row["expected"]!), name)
    }

    // MARK: Behavioural tests

    private func twoSourceStore() throws -> NotebookStore {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        try seedGeneration(store, try XCTUnwrap(cases("generation").first { $0["name"] as? String == "lexical-only" })["input"] as! [String: Any])
        return store
    }

    private var ollamaSelection: EmbeddingSelection {
        EmbeddingSelection(providerId: "local", endpointRevision: EmbeddingEndpointRevision.make(type: .ollama, normalizedRoot: "http://localhost:11434"),
            model: "embed-a", modelDigest: nil, dims: 2, normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")
    }

    func testStaleBatchAndActivationFence() async throws {
        let store = try twoSourceStore()
        let jobId = try store.requestEmbeddingBuild(notebookId: 1, selection: ollamaSelection, copyExisting: false, now: 0)
        let generationId = try XCTUnwrap(Int64(try XCTUnwrap(store.job(id: jobId)).draft.target.dropFirst("generation:".count)))
        XCTAssertNotNil(try store.claimJob(now: 1, leaseToken: "owner", id: jobId))
        let fence = JobFence(jobId: jobId, leaseToken: "owner"), stale = JobFence(jobId: jobId, leaseToken: "old")
        let identity = try XCTUnwrap(store.generation(id: generationId)).identity
        XCTAssertFalse(try store.commitEmbeddingBatch(generationId: generationId, chunkIds: [111], revisionIds: [11], vectors: [[1, 0]], fence: stale, now: 2))
        XCTAssertFalse(try store.activateBuiltGeneration(id: generationId, selectedIdentity: identity, fence: fence, now: 2),
                       "pending rows block activation")
        XCTAssertTrue(try store.commitEmbeddingBatch(generationId: generationId, chunkIds: [111, 211], revisionIds: [11, 21],
                                                     vectors: [[1, 0], [0, 1]], fence: fence, now: 3))
        XCTAssertFalse(try store.activateBuiltGeneration(id: generationId, selectedIdentity: identity, fence: stale, now: 4))
        XCTAssertFalse(try store.activateBuiltGeneration(id: generationId, selectedIdentity: identity, fence: fence, now: 301), "expired lease")
        XCTAssertNil(try store.activeGeneration(notebookId: 1))
        XCTAssertTrue(try store.activateBuiltGeneration(id: generationId, selectedIdentity: identity, fence: fence, now: 4))
        XCTAssertEqual(try store.activeGeneration(notebookId: 1)?.id, generationId)
        XCTAssertEqual(try store.job(id: jobId)?.state, "done")
        // A changed selection never activates: the build fails, the active generation stays.
        let second = try store.requestEmbeddingBuild(notebookId: 1, selection: ollamaSelection, copyExisting: false, now: 5)
        let secondGeneration = try XCTUnwrap(Int64(try XCTUnwrap(store.job(id: second)).draft.target.dropFirst("generation:".count)))
        XCTAssertNotNil(try store.claimJob(now: 5, leaseToken: "second", id: second))
        let other = GenerationIdentity(providerId: "other", endpointRevision: identity.endpointRevision, model: identity.model,
            modelDigest: nil, dims: 2, normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")
        XCTAssertFalse(try store.activateBuiltGeneration(id: secondGeneration, selectedIdentity: other,
                                                         fence: JobFence(jobId: second, leaseToken: "second"), now: 6))
        XCTAssertEqual(try store.generation(id: secondGeneration)?.state, "failed")
        XCTAssertEqual(try store.job(id: second)?.error, "embeddingSelectionChanged")
        XCTAssertEqual(try store.activeGeneration(notebookId: 1)?.id, generationId)
        XCTAssertTrue(try store.generationProgress(notebookId: 1).failed)
    }

    func testChatPausesOnlyNextBatch() async throws {
        let store = try twoSourceStore()
        let selection = ollamaSelection
        let jobId = try store.requestEmbeddingBuild(notebookId: 1, selection: selection, copyExisting: false, now: 0)
        let job = try XCTUnwrap(store.claimJob(now: 1, leaseToken: "owner", id: jobId))
        let admission = IngestionAdmission(), embedder = BlockingEmbedder()
        let coordinator = FolderIndexCoordinator(store: store, admission: admission, clock: GenClock(2),
            session: { _ in FolderEmbeddingSession(selection: selection, embedder: embedder) },
            selectedSelection: { _ in selection }, batchSize: 1)
        let run = Task { try await coordinator.execute(job: job, fence: JobFence(jobId: jobId, leaseToken: "owner")) }
        await embedder.firstCall()
        // Chat begins while the first batch is already with the provider: it may finish.
        let chat = await admission.beginChat()
        embedder.release()
        try await settle("second batch waits") {
            let progress = try await coordinator.progress(notebookId: 1)
            return progress.pausedForChat && progress.done == 1
        }
        XCTAssertEqual(embedder.count, 1, "no new background batch starts during chat")
        XCTAssertEqual(try store.job(id: jobId)?.state, "running", "a chat wait never pauses the durable job")
        // A question embedding is never gated.
        let question = FolderEmbeddingSession(selection: selection, embedder: FakeEmbedder(responses: [[[1, 0]]]))
        let vector = try await question.embed(inputs: ["question"])
        XCTAssertEqual(vector, [[1, 0]])
        await admission.endChat(chat)
        try await run.value
        XCTAssertEqual(embedder.count, 2)
        XCTAssertNotNil(try store.activeGeneration(notebookId: 1))
        XCTAssertEqual(try store.job(id: jobId)?.state, "done")
        let progress = try await coordinator.progress(notebookId: 1)
        XCTAssertFalse(progress.pausedForChat)
        XCTAssertTrue(progress.hasActive)
    }

    func testRestartAndPeriodicReconcile() async throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "r").id)
        let watched = try store.createFolder(notebookId: notebook, draft: FolderDraft(rootPath: "/a", displayName: "A", includeExts: ["md"],
            ignoreGlobs: [], limitsJSON: "{}", encodingFallback: "cp1250", watchEnabled: true), identity: EmptyRootFS(), now: 0)
        let manual = try store.createFolder(notebookId: try XCTUnwrap(store.createNotebook(name: "s").id), draft: FolderDraft(rootPath: "/b",
            displayName: "B", includeExts: ["md"], ignoreGlobs: [], limitsJSON: "{}", encodingFallback: "cp1250", watchEnabled: false),
            identity: StaticIdentity(identity: FolderIdentity(volumeId: "v", components: ["b"], rootFileId: "b")), now: 0)
        // A crashed scan: scanning row, expired lease.
        let orphan = try store.requestFolderScan(folderId: watched.id, verifyAll: false, now: 0)
        _ = try store.claimJob(now: 0, leaseToken: "crashed", id: orphan)
        _ = try store.beginFolderScan(folderId: watched.id, fence: JobFence(jobId: orphan, leaseToken: "crashed"), now: 0)
        let clock = GenClock(400)
        let reconciler = FolderReconciler(store: store, clock: clock, requestScan: { id, verify in
            _ = try await MainActor.run { try store.requestFolderScan(folderId: id, verifyAll: verify, now: clock.now()) }
        })
        try await reconciler.start()
        XCTAssertEqual(try store.folderSource(id: watched.id).scanState, "partial", "orphan scan repaired without missing-marking")
        XCTAssertNil(try store.folderSource(id: watched.id).lastFullScanAt, "startup scheduling is not a full scan")
        let queued = try store.runOnDatabase { try String.fetchAll($0, sql: "SELECT target FROM ingest_jobs WHERE state='queued' ORDER BY id") }
        XCTAssertEqual(queued, ["folder:\(watched.id)"], "recovered job coalesces the startup scan; disabled folders never auto-scan")
        XCTAssertEqual(try store.job(id: orphan)?.state, "queued")
        let next = await reconciler.nextReconcileAt
        XCTAssertEqual(next, 2200)
        try await settle("timer waiting") { clock.pending == 1 }
        // The queued job runs and finishes; the clock-driven pass queues the next scan.
        _ = try store.claimJob(now: 2199, leaseToken: "scan", id: orphan)
        _ = try store.runOnDatabase { try $0.execute(sql: "UPDATE ingest_jobs SET state='done',lease_token=NULL,lease_until=NULL WHERE id=?", arguments: [orphan]) }
        clock.set(2200)
        try await settle("periodic pass") {
            try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM ingest_jobs WHERE state='queued'")! } == 1
        }
        // The pass queues the scan before it reschedules; wait for both under parallel load.
        try await settle("rescheduled") { await reconciler.nextReconcileAt == 4000 }
        let rescheduled = await reconciler.nextReconcileAt
        XCTAssertEqual(rescheduled, 4000)
        _ = try store.requestFolderScan(folderId: manual.id, verifyAll: true, now: 2201)
        XCTAssertTrue(try store.scanOptions(jobId: try XCTUnwrap(store.runOnDatabase {
            try Int64.fetchOne($0, sql: "SELECT id FROM ingest_jobs WHERE target=?", arguments: ["folder:\(manual.id)"]) })))
        await reconciler.stop()
        let running = await reconciler.running
        XCTAssertFalse(running)
    }

    func testDiscardAndPrivacyFailure() async throws {
        let cloud = ProviderConfig(id: "cloud", type: .openaiCompatible, name: "Cloud", baseURL: "https://e.example/v1", privacyAcknowledged: false)
        XCTAssertThrowsError(try FolderEmbeddingSession(config: cloud, model: "m", apiKey: "k", modelDigest: nil,
                                                        queryFormatVersion: "1", docFormatVersion: "1")) {
            XCTAssertEqual($0 as? ProviderError, .consentRequired)
        }
        var disabled = cloud
        disabled.enabled = false
        disabled.privacyAcknowledged = true
        XCTAssertThrowsError(try FolderEmbeddingSession(config: disabled, model: "m", apiKey: nil, modelDigest: nil,
                                                        queryFormatVersion: "1", docFormatVersion: "1")) {
            XCTAssertEqual(($0 as? IngestionError)?.code, "providerDisabled")
        }
        XCTAssertThrowsError(try FolderEmbeddingSession(config: ProviderConfig.builtInOllama(), model: " ", apiKey: nil, modelDigest: nil,
                                                        queryFormatVersion: "1", docFormatVersion: "1"))
        let store = try twoSourceStore()
        let coordinator = FolderIndexCoordinator(store: store, admission: IngestionAdmission(), clock: GenClock(0),
            session: { _ in nil }, selectedSelection: { _ in nil })
        // No session (provider removed or consent revoked): the job is invalidated, nothing else changes.
        let build = try store.requestEmbeddingBuild(notebookId: 1, selection: ollamaSelection, copyExisting: false, now: 0)
        let claimed = try XCTUnwrap(store.claimJob(now: 0, leaseToken: "t", id: build))
        try await coordinator.execute(job: claimed, fence: JobFence(jobId: build, leaseToken: "t"))
        XCTAssertEqual(try store.job(id: build)?.error, "embeddingSelectionChanged")
        // Discard by job: bootstrap cancelled; generation job retires only its building generation.
        var unknown = ollamaSelection
        unknown = EmbeddingSelection(providerId: unknown.providerId, endpointRevision: unknown.endpointRevision, model: unknown.model,
            modelDigest: nil, dims: nil, normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")
        let bootstrap = try store.requestEmbeddingBuild(notebookId: 1, selection: unknown, copyExisting: false, now: 1)
        XCTAssertTrue(try store.generationProgress(notebookId: 1).preparing)
        try await coordinator.discardJob(jobId: bootstrap)
        XCTAssertEqual(try store.job(id: bootstrap)?.state, "cancelled")
        let generationJob = try store.requestEmbeddingBuild(notebookId: 1, selection: ollamaSelection, copyExisting: false, now: 2)
        let generationId = try XCTUnwrap(Int64(try XCTUnwrap(store.job(id: generationJob)).draft.target.dropFirst("generation:".count)))
        try await coordinator.discardJob(jobId: generationJob)
        XCTAssertEqual(try store.generation(id: generationId)?.state, "retired")
        XCTAssertEqual(try store.job(id: generationJob)?.state, "cancelled")
    }

    func testVerifyAllSurvivesRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = StorePath(fileURL: directory.appendingPathComponent("db.sqlite"))
        var store = try NotebookStore(path: path, configuredEmbeddingModelKey: nil)
        let notebook = try XCTUnwrap(store.createNotebook(name: "v").id)
        let folder = try store.createFolder(notebookId: notebook, draft: FolderDraft(rootPath: "/a", displayName: "A", includeExts: ["md"],
            ignoreGlobs: [], limitsJSON: "{}", encodingFallback: "cp1250", watchEnabled: true), identity: EmptyRootFS(), now: 0)
        let first = try store.requestFolderScan(folderId: folder.id, verifyAll: false, now: 0)
        XCTAssertEqual(try store.requestFolderScan(folderId: folder.id, verifyAll: true, now: 1), first, "unclaimed job upgraded in place")
        XCTAssertEqual(try store.requestFolderScan(folderId: folder.id, verifyAll: false, now: 2), first, "never downgraded")
        store = try NotebookStore(path: path, configuredEmbeddingModelKey: nil)
        XCTAssertTrue(try store.scanOptions(jobId: first))
        _ = try store.claimJob(now: 3, leaseToken: "run", id: first)
        let successor = try store.requestFolderScan(folderId: folder.id, verifyAll: true, now: 4)
        XCTAssertNotEqual(successor, first, "a running scan gets one queued successor")
        XCTAssertEqual(try store.requestFolderScan(folderId: folder.id, verifyAll: true, now: 5), successor)
        XCTAssertTrue(try store.scanOptions(jobId: successor))
    }

    func testPinnedOldRevisionSurvives() async throws {
        try await runGeneration(try XCTUnwrap(cases("generation").first { $0["name"] as? String == "pin-keeps-old-vectors" }))
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        try seedGeneration(store, try XCTUnwrap(cases("generation").first { $0["name"] as? String == "pin-keeps-old-vectors" })["input"] as! [String: Any])
        let old = try XCTUnwrap(store.activeGeneration(notebookId: 1))
        let pin = try store.pinQuery(notebookId: 1, modelKey: old.identity.modelKey)
        XCTAssertTrue(try store.activateBuiltGeneration(id: 20, selectedIdentity: old.identity, fence: JobFence(jobId: 301, leaseToken: "build-a"), now: 5))
        _ = try store.garbageCollect(notebookId: 1)
        XCTAssertEqual(try store.pinnedEmbeddings(pin).map(\.chunkId), [111, 211], "a running query keeps its pinned generation")
        store.releaseQuery(pin)
        _ = try store.garbageCollect(notebookId: 1)
        XCTAssertNil(try store.generation(id: old.id))
        XCTAssertEqual(try store.activeGeneration(notebookId: 1)?.id, 20)
    }

    func testAllGenerationFixtures() async throws {
        var names = Set<String>()
        for row in try cases("generation") {
            XCTAssertTrue(names.insert(row["name"] as! String).inserted)
            try await runGeneration(row)
        }
        XCTAssertEqual(names.count, 29)
        for row in try cases("reconcile") { try await runReconcile(row) }
        for row in try cases("embedding-session") { try await runSession(row) }
        XCTAssertEqual(try cases("reconcile").count + cases("embedding-session").count, 7)
    }
}

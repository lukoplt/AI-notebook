import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private actor RecrawlText: TextExtractor {
    var value = "first"
    func change(_ value: String) { self.value = value }
    func extract(from url: URL, kind: SourceType) async throws -> ExtractedText {
        ExtractedText(title: "web", text: value)
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let gate = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { gate.lock(); defer { gate.unlock() }; return stored }
        set { gate.lock(); stored = newValue; gate.unlock() }
    }
}

/// Records handles and callbacks; never touches the filesystem.
private final class TestWatchFactory: FolderWatchFactory, @unchecked Sendable {
    final class Handle: FolderWatchHandle, @unchecked Sendable {
        let folderId: Int64
        let starts = Locked(0), stops = Locked(0)
        init(folderId: Int64) { self.folderId = folderId }
        func start() throws { starts.value += 1 }
        func stop() { stops.value += 1 }
    }
    let handles = Locked<[Handle]>([])
    let callbacks = Locked<[Int64: @Sendable (String) -> Void]>([:])
    func make(folder: FolderSource, onEvent: @escaping @Sendable (String) -> Void) throws -> any FolderWatchHandle {
        let handle = Handle(folderId: folder.id)
        handles.value.append(handle)
        callbacks.value[folder.id] = onEvent
        return handle
    }
}

/// Every root lists empty; the walk completes and scans finish idle.
private struct EmptyFS: FolderFileSystem {
    func resolve(rootPath: String) throws -> FolderIdentity {
        FolderIdentity(volumeId: "test", components: rootPath.split(separator: "/").map(String.init), rootFileId: rootPath)
    }
    func caseSensitive(root: FolderSource) throws -> Bool { true }
    func list(root: FolderSource, directory: String) throws -> [FolderEntry] { [] }
    func stat(root: FolderSource, relativePath: String) throws -> FileStamp { FileStamp(identity: "root", mtimeNs: 0, sizeBytes: 0) }
    func hash(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderRead { throw IngestionError(code: "outsideRoot") }
    func snapshot(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderFileSnapshot { throw IngestionError(code: "outsideRoot") }
}

private final class FixedLeaseClock: IngestLeaseClock, @unchecked Sendable {
    let current = Locked<Int64>(0)
    func now() -> Int64 { current.value }
    func wait(until: Int64) async throws { throw CancellationError() }
}

private final class FailingChat: ChatStreaming, @unchecked Sendable {
    let block: Bool
    init(block: Bool) { self.block = block }
    func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let block = self.block
        return AsyncThrowingStream { continuation in
            Task {
                if block {
                    try? await Task.sleep(for: .seconds(30))
                    continuation.finish(throwing: CancellationError())
                } else {
                    continuation.finish(throwing: ProviderError.auth("denied"))
                }
            }
        }
    }
    func stream(model: String, messages: [ChatTurn], options: ChatRequestOptions) -> AsyncThrowingStream<String, Error> {
        stream(model: model, messages: messages)
    }
}

private final class CountingEmbedder: EmbeddingProducing, @unchecked Sendable {
    let calls = Locked(0)
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        calls.value += 1
        return inputs.map { _ in [1, 0] }
    }
}

private func int64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
private func json(_ value: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
}

@MainActor
private func settle(_ label: String, _ condition: () async throws -> Bool) async rethrows {
    for _ in 0..<200_000 {
        if try await condition() { return }
        await Task.yield()
    }
    XCTFail("never settled: \(label)")
}

@MainActor
final class FolderIntegrationTests: XCTestCase {
    func testRecrawlPreservesIdentityAndPublishesNewText() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "E2")
        let web = RecrawlText()
        let service = IngestionService(store: store, web: web)
        let original = try await service.ingestURL(URL(string: "https://example.invalid/doc")!, into: nb.id!)
        let oldRevision = try XCTUnwrap(store.source(id: original.id!)?.publishedRevisionId)
        await web.change("second")
        let refreshed = try await LiveSourceSync(store: store, ingestion: service).recrawl(sourceId: original.id!)
        XCTAssertEqual(refreshed.id, original.id)
        XCTAssertEqual(refreshed.uri, original.uri)
        XCTAssertEqual(try store.sources(notebookId: nb.id!).count, 1)
        XCTAssertEqual(try store.chunks(sourceId: original.id!).map(\.text), ["second"])
        XCTAssertNotEqual(refreshed.publishedRevisionId, oldRevision)
        XCTAssertNotNil(refreshed.lastSyncedAt)
        XCTAssertEqual(try store.revision(id: oldRevision)?.draft.canonicalText, "first")
        XCTAssertEqual(refreshed.contentHash, try store.revision(id: try XCTUnwrap(refreshed.publishedRevisionId))?.draft.contentHash,
                       "the sync timestamp records the published SHA-256")
    }

    func testChangedAndOverflowEventsRequireHash() throws {
        XCTAssertTrue(FolderWatchEventPolicy.forceHash(kind: "changed"))
        XCTAssertTrue(FolderWatchEventPolicy.forceHash(kind: "overflow"))
        XCTAssertTrue(FolderWatchEventPolicy.forceHash(kind: "renamed"))
        XCTAssertFalse(FolderWatchEventPolicy.forceHash(kind: "created"))
        let rows = try XCTUnwrap(SharedFixtures.json("contracts/ingestion-ui-v1.json")["cases"] as? [[String: Any]])
            .filter { $0["operation"] as? String == "watch" }
        XCTAssertEqual(rows.count, 5)
        for row in rows {
            let kind = (row["input"] as! [String: Any])["kind"] as! String
            XCTAssertEqual(FolderWatchEventPolicy.forceHash(kind: kind), (row["expected"] as! [String: Any])["forceHash"] as? Bool, kind)
        }
    }

    // MARK: Runtime fixtures

    private struct Harness {
        let store: NotebookStore
        let runtime: FolderIngestionRuntime
        let watches: TestWatchFactory
        let starts: Locked<[Int64]>
        let clock: FixedLeaseClock
        let milliseconds: Locked<Int64>
    }

    private func harness(_ input: [String: Any]) throws -> Harness {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let seed = input["seed"] as! [String: Any]
        try store.runOnDatabase { db in
            let date = Date(timeIntervalSince1970: 0)
            for id in seed["notebooks"] as! [NSNumber] {
                try db.execute(sql: "INSERT INTO notebooks(id,name,created_at,updated_at) VALUES(?,?,?,?)", arguments: [id.int64Value, "nb", date, date])
            }
            for folder in seed["folders"] as! [[String: Any]] {
                let root = folder["rootPath"] as! String
                let identity = try EmptyFS().resolve(rootPath: root)
                try db.execute(sql: """
                    INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,watch_enabled,created_at)
                    VALUES(?,?,?,?,'F','["md","txt"]','[]','{}',?,?)
                    """, arguments: [int64(folder["id"]), int64(folder["notebookId"]), root,
                                      String(decoding: try JSONEncoder().encode(identity), as: UTF8.self), folder["watchEnabled"] as! Bool, date])
            }
            XCTAssertTrue((seed["jobs"] as! [Any]).isEmpty && (seed["sources"] as! [Any]).isEmpty)
            try db.execute(sql: "INSERT INTO sqlite_sequence(name,seq) VALUES('ingest_jobs',200),('sources',100),('source_revisions',10)")
        }
        let watches = TestWatchFactory(), starts = Locked<[Int64]>([]), clock = FixedLeaseClock(), ms = Locked<Int64>(0)
        let runtime = try FolderIngestionRuntime.make(store: store, admission: IngestionAdmission(), session: { _ in nil },
            clock: clock, watches: watches, fileSystem: EmptyFS(), dispatch: false, milliseconds: { ms.value },
            observe: { event in if event.hasPrefix("start:"), let id = Int64(event.dropFirst(6)) { starts.value.append(id) } })
        return Harness(store: store, runtime: runtime, watches: watches, starts: starts, clock: clock, milliseconds: ms)
    }

    private func projection(_ h: Harness) async throws -> [String: Any] {
        let watched = await h.runtime.watchedFolderIds
        return try h.store.runOnDatabase { db in
            let jobs = try Row.fetchAll(db, sql: "SELECT * FROM ingest_jobs WHERE kind='scan' ORDER BY id").map { row -> [String: Any] in
                let options: String = row["options_json"], target: String = row["target"]
                return ["id": row["id"] as Int64, "kind": row["kind"] as String, "state": row["state"] as String,
                        "folderId": Int64(target.dropFirst("folder:".count))!,
                        "verifyAll": try NotebookStore.verifyAllOption(options)]
            }
            let sources = try Row.fetchAll(db, sql: "SELECT * FROM sources ORDER BY id").map { row -> [String: Any] in
                let id: Int64 = row["id"], published: Int64? = row["published_revision_id"], type: String = row["type"]
                return ["id": id, "notebookId": row["notebook_id"] as Int64, "publishedRevisionId": published as Any,
                        "canonicalText": try String.fetchOne(db, sql: "SELECT canonical_text FROM source_revisions WHERE id=?", arguments: [published]) as Any,
                        "retainedRevisionIds": try Int64.fetchAll(db, sql: "SELECT id FROM source_revisions WHERE source_id=? ORDER BY id", arguments: [id]),
                        "type": type == "web" ? "url" : type, "uri": (row["uri"] as String?) as Any]
            }
            return ["diskDeleteCalls": 0, "folderIds": try Int64.fetchAll(db, sql: "SELECT id FROM folder_sources ORDER BY id"),
                    "jobs": jobs, "providerCallCount": 0,
                    "queuedJobIds": jobs.filter { $0["state"] as? String == "queued" }.map { $0["id"] as! Int64 },
                    "scanStarts": h.starts.value, "sources": sources, "watchedFolderIds": watched]
        }
    }

    private func runRuntimeCase(_ row: [String: Any]) async throws {
        let name = row["name"] as! String, input = row["input"] as! [String: Any]
        XCTAssertEqual(input["projectJobKinds"] as? [String], ["scan"])
        XCTAssertTrue(input["embeddingSelection"] is NSNull)
        let h = try harness(input)
        var tokens: [String: (Int64, UUID)] = [:]
        let web = RecrawlText()
        let service = IngestionService(store: h.store, web: web)
        for event in input["events"] as! [[String: Any]] {
            let operation = event["operation"] as! String, at = int64(event["at"])!
            h.clock.current.value = at
            h.milliseconds.value = at
            switch operation {
            case "start":
                try await h.runtime.start()
                for (folder, token) in (event["watchTokens"] as? [String: String]) ?? [:] {
                    let id = Int64(folder)!
                    let issued = await h.runtime.token(folderId: id)
                    tokens[token] = (id, try XCTUnwrap(issued, name))
                }
            case "stop": await h.runtime.stop()
            case "watch": try await h.runtime.setWatching(folderId: int64(event["folderId"])!, enabled: event["enabled"] as! Bool)
            case "remove": try await h.runtime.removeFolder(folderId: int64(event["folderId"])!)
            case "signal":
                let (folderId, token) = try XCTUnwrap(tokens[event["watchToken"] as! String])
                XCTAssertEqual(folderId, int64(event["folderId"]))
                await h.runtime.receive(folderId: folderId, token: token,
                                        kind: event["forceHash"] as! Bool ? "changed" : "created", at: at)
            case "tick": try await h.runtime.tick(at: at)
            case "start-scan":
                let id = int64(event["jobId"])!
                XCTAssertNotNil(try h.store.claimJob(now: at, leaseToken: "scan-\(id)", id: id))
                h.starts.value.append(id)
                await h.runtime.noteScanStarted(folderId: int64(event["folderId"])!)
            case "finish-scan":
                let id = int64(event["jobId"])!, folderId = int64(event["folderId"])!
                try await FolderScanner(store: h.store, fileSystem: EmptyFS(), tables: UnicodeTables.bundled(), clock: h.clock)
                    .scan(folderId: folderId, verifyAll: false, fence: JobFence(jobId: id, leaseToken: "scan-\(id)"), now: at, cancelled: { false })
                await h.runtime.noteScanFinished(folderId: folderId, at: at)
            case "drain":
                let before = h.starts.value.count
                let ran = try await h.runtime.drainOnce()
                XCTAssertEqual(ran, !(event["jobId"] is NSNull), name)
                if let id = int64(event["jobId"]) { XCTAssertEqual(h.starts.value.dropFirst(before).first, id, name) }
            case "ingest-source":
                let source: Source
                if event["kind"] as? String == "url" {
                    await web.change(event["text"] as! String)
                    source = try await service.ingestURL(URL(string: event["uri"] as! String)!, into: int64(event["notebookId"])!)
                } else {
                    source = try await service.ingestRawText(title: "t", text: event["text"] as! String, into: int64(event["notebookId"])!)
                }
                XCTAssertEqual(source.id, int64(event["sourceId"]), name)
            case "refresh-source":
                _ = try h.store.commitForegroundRevision(sourceId: int64(event["sourceId"])!, draft: RevisionDraft(contentHash: "h2",
                    canonicalText: event["text"] as! String, textFormatVersion: 1, chunkerVersion: 2),
                    chunks: ScalarChunker.chunk(event["text"] as! String), now: at, leaseToken: event["leaseToken"] as! String)
            case "refresh-url":
                await web.change(event["text"] as! String)
                _ = try await LiveSourceSync(store: h.store, ingestion: service).recrawl(sourceId: int64(event["sourceId"])!)
            default:
                XCTFail("unknown runtime operation \(operation)")
            }
            let value = try await projection(h)
            XCTAssertEqual(json(value), json(event["expected"]!), "\(name) \(operation) @\(at)")
        }
        let final = try await projection(h)
        XCTAssertEqual(json(final), json(row["expected"]!), name)
        await h.runtime.stop()
    }

    private func runtimeCases() throws -> [[String: Any]] {
        try XCTUnwrap(SharedFixtures.json("contracts/ingestion-ui-v1.json")["cases"] as? [[String: Any]])
            .filter { $0["operation"] as? String == "runtime" }
    }

    func testStartRestoresAllNotebooks() async throws {
        let rows = try runtimeCases()
        XCTAssertEqual(rows.count, 5)
        var names = Set<String>()
        for row in rows {
            XCTAssertTrue(names.insert(row["name"] as! String).inserted)
            try await runRuntimeCase(row)
        }
        // Start is idempotent and does not create a second watch per folder.
        let h = try harness(rows[0]["input"] as! [String: Any])
        try await h.runtime.start()
        try await h.runtime.start()
        XCTAssertEqual(h.watches.handles.value.map(\.folderId), [1, 2])
        XCTAssertEqual(h.watches.handles.value.map { $0.starts.value }, [1, 1])
        await h.runtime.stop()
        XCTAssertEqual(h.watches.handles.value.map { $0.stops.value }, [1, 1])
    }

    func testDisableAndRemoveInvalidateCallbacks() async throws {
        let rows = try runtimeCases()
        try await runRuntimeCase(try XCTUnwrap(rows.first { $0["name"] as? String == "runtime-callback-after-remove" }))
        // Through the real native-callback closure: a stopped watch's late callback schedules nothing.
        let h = try harness(rows[0]["input"] as! [String: Any])
        try await h.runtime.start()
        let callback = try XCTUnwrap(h.watches.callbacks.value[1])
        try await h.runtime.setWatching(folderId: 1, enabled: false)
        XCTAssertEqual(try h.store.folderSource(id: 1).draft.watchEnabled, false)
        callback("changed")
        for _ in 0..<1000 { await Task.yield() }
        try await h.runtime.tick(at: 100_000)
        XCTAssertEqual(try h.store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM ingest_jobs WHERE target='folder:1'")! }, 1,
                       "only the startup scan exists")
        // A live callback reaches the debounced schedule.
        let live = try XCTUnwrap(h.watches.callbacks.value[2])
        h.milliseconds.value = 10
        live("changed")
        try await settle("signal received") {
            try await h.runtime.tick(at: 510)
            return try h.store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM ingest_jobs WHERE target='folder:2' AND options_json LIKE '%true%'")! } == 1
        }
        // Manual scans stay possible while watching is disabled; removal never deletes files.
        let manual = try await h.runtime.scanNow(folderId: 1, verifyAll: true)
        XCTAssertTrue(try h.store.scanOptions(jobId: manual))
        try await h.runtime.removeFolder(folderId: 1)
        XCTAssertEqual(try h.store.job(id: manual)?.state, "cancelled")
        await h.runtime.stop()
    }

    func testOneTrailingScan() async throws {
        let rows = try runtimeCases()
        try await runRuntimeCase(try XCTUnwrap(rows.first { $0["name"] as? String == "runtime-one-trailing-scan" }))
    }

    func testChatErrorAndCancellationReleaseAdmission() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "chat")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")
        let admission = IngestionAdmission()
        let retriever = Retriever(store: store, client: CountingEmbedder(), model: "m")
        let failing = ChatEngine(store: store, retriever: retriever, chat: FailingChat(block: false), chatModel: "m",
                                 retryAttempts: 0, admission: admission)
        do {
            _ = try await failing.send(sessionId: session.id!, notebookId: nb.id!, userText: "q") { _ in }
            XCTFail("expected provider failure")
        } catch {}
        var snapshot = await admission.snapshot()
        XCTAssertEqual(snapshot.chatTokens, [], "error releases the chat token")
        let blocking = ChatEngine(store: store, retriever: retriever, chat: FailingChat(block: true), chatModel: "m",
                                  retryAttempts: 0, admission: admission)
        let task = Task { try await blocking.send(sessionId: session.id!, notebookId: nb.id!, userText: "q2") { _ in } }
        try await settle("chat admitted") { await admission.snapshot().chatTokens.count == 1 }
        task.cancel()
        _ = await task.result
        snapshot = await admission.snapshot()
        XCTAssertEqual(snapshot.chatTokens, [], "cancellation releases the chat token")
        _ = try? await failing.regenerate(sessionId: session.id!, notebookId: nb.id!) { _ in }
        snapshot = await admission.snapshot()
        XCTAssertEqual(snapshot.chatTokens, [], "regenerate uses the same bracket")
    }

    func testLooseOfficeUsesCanonicalExtractor() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "loose")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loose-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workbook.xlsx")
        try SharedFixtures.data("ingestion/workbook.xlsx").write(to: file)
        let kicks = Locked(0)
        let service = IngestionService(store: store, onChunksWritten: { kicks.value += 1 }, detector: .unavailable)
        let source = try await service.ingestFile(file, into: nb.id!)
        let office = try XCTUnwrap(SharedFixtures.json("contracts/ingestion-office-v1.json")["cases"] as? [[String: Any]])
            .first { $0["name"] as? String == "workbook-order" }
            .map { try SpreadsheetSupersession.apply($0, fixture: "ingestion-office-v1.json") }
        let expected = try XCTUnwrap((office?["expected"] as? [String: Any])?["text"] as? String)
        let published = try XCTUnwrap(store.source(id: source.id!)?.publishedRevisionId)
        let revision = try XCTUnwrap(store.revision(id: published))
        XCTAssertEqual(revision.draft.canonicalText, expected, "workbook order, never sharedStrings-only")
        XCTAssertEqual(revision.draft.chunkerVersion, 2)
        XCTAssertNotNil(try store.chunks(sourceId: source.id!).first?.charStart)
        let descriptor = try store.runOnDatabase { try String.fetchOne($0, sql: "SELECT descriptor FROM sources WHERE id=?", arguments: [source.id!]) }
        XCTAssertTrue(try XCTUnwrap(descriptor).contains(#""type":"xlsx""#))
        XCTAssertEqual(kicks.value, 1)
        // An injected legacy extractor keeps its own behaviour.
        let legacy = IngestionService(store: store, office: StubOffice())
        let old = try await legacy.ingestFile(file, into: nb.id!)
        XCTAssertEqual(try store.chunks(sourceId: old.id!).map(\.text), ["legacy"])
    }

    func testLegacyKickDoesNotDoubleEmbed() async throws {
        let store = try NotebookStore(path: .inMemory)
        let embedder = CountingEmbedder()
        let woke = Locked(0)
        _ = Embedder(store: store, client: embedder, model: "m")
        let worker = EmbeddingWorker(wake: { woke.value += 1 })
        await worker.kick()
        await worker.waitUntilIdle()
        XCTAssertEqual(woke.value, 1)
        XCTAssertEqual(embedder.calls.value, 0, "production kick wakes the runtime only")
        // The legacy embedder honours the shared chat gate when supplied.
        let nb = try store.createNotebook(name: "legacy")
        let service = IngestionService(store: store, plain: PlainTextExtractor())
        _ = try await service.ingestRawText(title: "t", text: "hello world", into: nb.id!)
        let admission = IngestionAdmission()
        let chat = await admission.beginChat()
        let gated = Embedder(store: store, client: embedder, model: "m", admission: admission)
        let run = Task { try await gated.embedAllPending() }
        for _ in 0..<1000 { await Task.yield() }
        XCTAssertEqual(embedder.calls.value, 0, "no background batch during chat")
        await admission.endChat(chat)
        _ = try await run.value
        XCTAssertEqual(embedder.calls.value, 1)
    }
}

private struct StubOffice: TextExtractor {
    func extract(from url: URL, kind: SourceType) async throws -> ExtractedText { ExtractedText(title: "x", text: "legacy") }
}

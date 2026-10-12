import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

/// One simulated local embedding server (Ollama): requests are served one at a
/// time, each costing `baseMs + perInputMs × inputs`. Background batches and the
/// chat question share it, as they share the real Ollama process.
private actor SimulatedEmbeddingServer {
    let dims: Int
    let baseNs: UInt64
    let perInputNs: UInt64
    private var busyUntil: UInt64 = 0
    private(set) var queryWaitsMs: [Double] = []

    init(dims: Int, baseMs: Int, perInputMs: Int) {
        self.dims = dims
        baseNs = UInt64(baseMs) * 1_000_000
        perInputNs = UInt64(perInputMs) * 1_000_000
    }

    static func vector(_ text: String, dims: Int) -> [Float] {
        let seed = text.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        return (0..<dims).map { Float((Int(seed >> UInt32($0 % 24)) & 0xff) + 1) }
    }

    /// Reserves the next slot; returns how long the caller must wait and work.
    private func reserve(inputs: Int, query: Bool) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let start = max(now, busyUntil)
        busyUntil = start + baseNs + perInputNs * UInt64(inputs)
        if query { queryWaitsMs.append(Double(start - now) / 1e6) }
        return busyUntil - now
    }

    nonisolated func embed(_ inputs: [String], query: Bool) async throws -> [[Float]] {
        let delay = await reserve(inputs: inputs.count, query: query)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return inputs.map { Self.vector($0, dims: dims) }
    }
}

private final class BackgroundEmbedder: EmbeddingProducing, @unchecked Sendable {
    let server: SimulatedEmbeddingServer
    init(server: SimulatedEmbeddingServer) { self.server = server }
    func embed(model: String, inputs: [String]) async throws -> [[Float]] { try await server.embed(inputs, query: false) }
}

private final class InstantEmbedder: EmbeddingProducing, @unchecked Sendable {
    let dims: Int
    init(dims: Int) { self.dims = dims }
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        inputs.map { SimulatedEmbeddingServer.vector($0, dims: dims) }
    }
}

private final class QueryEmbedder: EmbeddingProducing, EmbeddingSessionPreparing, @unchecked Sendable {
    let server: SimulatedEmbeddingServer
    init(server: SimulatedEmbeddingServer) { self.server = server }
    func embed(model: String, inputs: [String]) async throws -> [[Float]] { try await server.embed(inputs, query: true) }
    func prepareEmbedding(identity: GenerationIdentity) async throws -> ProviderEmbeddingSession {
        ProviderEmbeddingSession(client: self, model: identity.model, storageKey: identity.providerId + ":" + identity.model,
                                 endpointRevision: identity.endpointRevision)
    }
}

private struct WallClock: IngestLeaseClock {
    func now() -> Int64 { Int64(Date().timeIntervalSince1970) }
    func wait(until: Int64) async throws {
        let seconds = max(0, until - now())
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }
}

/// Collects samples behind a lock (written from background tasks).
private final class Samples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var all: [Double] { lock.withLock { values } }
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))
    return sorted[index]
}

/// Opt-in end-to-end benchmark (AINOTEBOOK_CHAT_SCAN_BENCH=1) of a chat turn while
/// a folder check runs: a file-backed store with FILES already indexed files ×
/// CHUNKS chunks and an active vector index, the real runtime (scan, two
/// extraction loops, embed loop) over a real directory, a status-strip emulation
/// and a simulated serial embedding server shared by background batches and the
/// question. Reports chat-turn latency (capture, prepare = retrieval + context
/// pack, send), turn errors, main-thread stalls and the largest -wal size.
@MainActor
final class ChatDuringScanBenchmarkTests: XCTestCase {
    private func setting(_ name: String, _ fallback: Int) -> Int {
        Int(ProcessInfo.processInfo.environment["AINOTEBOOK_CHAT_SCAN_BENCH_\(name)"] ?? "") ?? fallback
    }

    private static let words = ["dokument", "smlouva", "faktura", "report", "analysis", "vertrag", "projekt", "zmluva",
                                "budget", "plan", "nabidka", "objednavka"]

    private static func text(_ prefix: String, length: Int) -> String {
        var text = prefix + " "
        var w = prefix.utf8.reduce(0) { $0 &+ Int($1) }
        while text.utf8.count < length { text += words[w % words.count] + " "; w &+= 7 }
        return text
    }

    func testChatTurnDuringFolderCheck() async throws {
        guard ProcessInfo.processInfo.environment["AINOTEBOOK_CHAT_SCAN_BENCH"] == "1" else {
            throw XCTSkip("set AINOTEBOOK_CHAT_SCAN_BENCH=1 to run the chat-during-scan benchmark")
        }
        let files = setting("FILES", 8_000), chunks = setting("CHUNKS", 16), textLength = setting("TEXT", 600)
        let dims = setting("DIMS", 256), newFiles = setting("NEW", 60), newKB = setting("NEW_KB", 150)
        let turnsIdle = setting("IDLE_TURNS", 10), loadSeconds = setting("LOAD_SECONDS", 60)
        let baseMs = setting("EMBED_BASE_MS", 20), perInputMs = setting("EMBED_PER_INPUT_MS", 4)
        let rescanEvery = setting("RESCAN_SECONDS", 5)

        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AINOTEBOOK_CHAT_SCAN_BENCH_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("chat-scan-bench-\(UUID().uuidString)", isDirectory: true)
        let folderURL = root.appendingPathComponent("Folder", isDirectory: true)
        let dbURL = root.appendingPathComponent("db.sqlite")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Real files: 40 directories of small text files.
        for index in 0..<files {
            let dir = folderURL.appendingPathComponent(String(format: "d%02d", index % 40), isDirectory: true)
            if index < 40 { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            try Data(Self.text("file \(index)", length: 300).utf8).write(to: dir.appendingPathComponent("file-\(index).txt"))
        }

        var seedStart = DispatchTime.now().uptimeNanoseconds
        let store = try NotebookStore(path: StorePath(fileURL: dbURL), configuredEmbeddingModelKey: nil)
        let notebookId = try XCTUnwrap(store.createNotebook(name: "bench").id)
        let sessionId = try XCTUnwrap(store.createChatSession(notebookId: notebookId, title: "bench").id)
        let fileSystem = NativeFolderFileSystem()
        let folder = try store.createFolder(notebookId: notebookId, draft: FolderDraft(rootPath: folderURL.path, displayName: "Folder",
            includeExts: FolderRules.defaults.includeExts, ignoreGlobs: FolderRules.defaults.ignoreGlobs, limitsJSON: "{}",
            encodingFallback: "cp1250", watchEnabled: false), identity: fileSystem, now: 1)

        // Seed: the real scanner inventories every file, SQL publishes C chunks per source.
        let scanner = FolderScanner(store: store, fileSystem: fileSystem, tables: try UnicodeTables.bundled(), clock: WallClock())
        let scanJob = try store.requestFolderScan(folderId: folder.id, verifyAll: false, now: 1)
        _ = try XCTUnwrap(store.claimJob(now: WallClock().now(), leaseToken: "seed", id: scanJob))
        try await scanner.scan(folderId: folder.id, verifyAll: false, fence: JobFence(jobId: scanJob, leaseToken: "seed"),
                               now: WallClock().now(), cancelled: { false })
        try store.runOnDatabase { db in
            try db.execute(sql: "DROP TRIGGER chunks_ai")
            let rows = try Row.fetchAll(db, sql: "SELECT id FROM sources WHERE folder_id=?", arguments: [folder.id])
            let revision = try db.makeStatement(sql: """
                INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                VALUES (?,1,?,?,1,2,'2026-10-10 00:00:00.000')
                """)
            let publish = try db.makeStatement(sql: """
                UPDATE sources SET current_revision=?,published_revision_id=?,status='ready',content_hash=?,lang='cs' WHERE id=?
                """)
            let chunk = try db.makeStatement(sql: """
                INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id,char_start,char_end,lang) VALUES (?,?,?,?,?,?,?,'cs')
                """)
            for row in rows {
                let id: Int64 = row["id"]
                let texts = (0..<chunks).map { Self.text("source \(id) chunk \($0)", length: textLength) }
                try revision.execute(arguments: [id, "seed-\(id)", texts.joined()])
                let revisionId = db.lastInsertedRowID
                try publish.execute(arguments: [revisionId, revisionId, "seed-\(id)", id])
                var offset = 0
                for (ord, text) in texts.enumerated() {
                    let length = text.unicodeScalars.count
                    try chunk.execute(arguments: [id, ord, text, textLength / 4, revisionId, offset, offset + length])
                    offset += length
                }
            }
            try db.execute(sql: "INSERT INTO chunks_fts(rowid,text,chunk_id) SELECT id,text,id FROM source_chunks")
            try db.execute(sql: """
                CREATE TRIGGER chunks_ai AFTER INSERT ON source_chunks BEGIN
                 INSERT INTO chunks_fts(rowid,text,chunk_id) VALUES(new.id,new.text,new.id);
                END
                """)
            try db.execute(sql: "UPDATE ingest_jobs SET state='done',lease_token=NULL,lease_until=NULL WHERE kind IN ('extract','scan')")
        }
        // Active vector index through the real build loop (instant embedder).
        let selection = EmbeddingSelection(providerId: "local", endpointRevision: "bench", model: "bench-embed", modelDigest: nil,
            dims: dims, normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")
        let buildJob = try store.requestEmbeddingBuild(notebookId: notebookId, selection: selection, copyExisting: false, now: 1)
        let claimed = try XCTUnwrap(store.claimJob(now: WallClock().now(), leaseToken: "build", id: buildJob))
        try await FolderIndexCoordinator(store: store, admission: IngestionAdmission(), clock: WallClock(),
            session: { _ in FolderEmbeddingSession(selection: selection, embedder: InstantEmbedder(dims: dims)) },
            selectedSelection: { _ in selection }, batchSize: 256)
            .execute(job: claimed, fence: JobFence(jobId: buildJob, leaseToken: "build"))
        XCTAssertNotNil(try store.activeGeneration(notebookId: notebookId), "seed index active")
        let seededChunks = try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM source_chunks")! }
        print(String(format: "CHAT-SCAN-BENCH seed files=%d chunks=%d dims=%d in %.1fs, db=%.0f MB", files, seededChunks, dims,
                     Double(DispatchTime.now().uptimeNanoseconds - seedStart) / 1e9,
                     Double((try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int) ?? 0) / 1e6))

        // Production-shaped composition.
        let server = SimulatedEmbeddingServer(dims: dims, baseMs: baseMs, perInputMs: perInputMs)
        let admission = IngestionAdmission()
        let runtime = try FolderIngestionRuntime.make(store: store, admission: admission,
            session: { _ in FolderEmbeddingSession(selection: selection, embedder: BackgroundEmbedder(server: server)) },
            clock: WallClock(), watches: ReleaseSilentWatches(), fileSystem: fileSystem, dispatch: true)
        let retriever = Retriever(store: store, client: QueryEmbedder(server: server), modelKey: { "local:bench-embed" },
                                  cache: VectorMatrixCache())
        let transport = ReleaseTransport(model: PackModel(providerId: "bench", model: "bench-chat", runtimeContext: 16_384,
            maxOutputTokens: 1_024, contextWindowKnown: true, providerType: "ollama"), answer: "Answer [1].")
        let engine = ChatEngine(store: store,
            coordinator: ContextPackCoordinator(data: CompatibilityPackDataSource(store: store, retriever: retriever),
                                                transports: ReleaseTransportFactory(transport: transport)),
            previews: ContextPreviewSession(), chatModel: "bench-chat", admission: admission)
        try await runtime.start()
        defer { Task { await runtime.stop() } }

        // Main-thread heartbeat (beach ball = the main thread not running for > ~250 ms).
        var stalls: [Double] = []
        var heartbeat = true
        let beat = Task { @MainActor in
            while heartbeat {
                let start = DispatchTime.now().uptimeNanoseconds
                try? await Task.sleep(nanoseconds: 5_000_000)
                stalls.append(max(0, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 - 5))
            }
        }
        // -wal size sampler.
        let walSizes = Samples()
        let walURL = dbURL.path + "-wal"
        let walSampler = Task.detached {
            while !Task.isCancelled {
                let size = (try? FileManager.default.attributesOfItem(atPath: walURL)[.size] as? Int) ?? 0
                walSizes.add(Double(size))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        // Status-strip emulation: refresh on every notification (coalesced) and once a second.
        var statusReads: [Double] = []
        var statusDirty = false
        var statusRunning = true
        func refreshStatus() async {
            let start = DispatchTime.now().uptimeNanoseconds
            if let status = try? await runtime.indexingStatus(notebookId: notebookId), case .ready = status.phase {
                _ = try? store.coverage(notebookId: notebookId, scope: .all)
            }
            _ = try? store.folders(notebookId: notebookId)
            statusReads.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let observers = [Notification.Name.indexingStatusDidChange, .folderIngestionDidChange].map { name in
            NotificationCenter.default.addObserver(forName: name, object: store, queue: .main) { _ in
                MainActor.assumeIsolated { statusDirty = true }
            }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        let statusLoop = Task { @MainActor in
            var last = DispatchTime.now().uptimeNanoseconds
            while statusRunning {
                let now = DispatchTime.now().uptimeNanoseconds
                if statusDirty || now - last > 1_000_000_000 {
                    statusDirty = false
                    last = now
                    await refreshStatus()
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        struct Turn { var capture: Double; var prepare: Double; var send: Double; var total: Double }
        var errors: [String: Int] = [:]
        func turn(_ index: Int) async -> Turn? {
            let question = "smlouva faktura \(Self.words[index % Self.words.count]) projekt"
            let t0 = DispatchTime.now().uptimeNanoseconds
            do {
                let intent = try await engine.captureIntent(sessionId: sessionId, notebookId: notebookId, question: question, scope: .all)
                let t1 = DispatchTime.now().uptimeNanoseconds
                let handle = try await engine.prepare(intent)
                let t2 = DispatchTime.now().uptimeNanoseconds
                let fresh = try await engine.captureIntent(sessionId: sessionId, notebookId: notebookId, question: question, scope: .all)
                _ = try await engine.sendPrepared(handle, expectedKey: PackIntentKey.make(fresh), onToken: { _ in })
                let t3 = DispatchTime.now().uptimeNanoseconds
                return Turn(capture: Double(t1 - t0) / 1e6, prepare: Double(t2 - t1) / 1e6, send: Double(t3 - t2) / 1e6,
                            total: Double(t3 - t0) / 1e6)
            } catch {
                errors[String(describing: error), default: 0] += 1
                return nil
            }
        }
        func report(_ label: String, _ turns: [Turn]) {
            func line(_ name: String, _ values: [Double]) -> String {
                String(format: "%@ p50=%.0f p95=%.0f max=%.0f", name, percentile(values, 0.5), percentile(values, 0.95), values.max() ?? 0)
            }
            print("CHAT-SCAN-BENCH \(label) turns=\(turns.count) errors=\(errors) | "
                  + [line("capture", turns.map(\.capture)), line("prepare", turns.map(\.prepare)),
                     line("send", turns.map(\.send)), line("total", turns.map(\.total))].joined(separator: " | ") + " ms")
        }

        // Idle baseline.
        var idle: [Turn] = []
        for index in 0..<turnsIdle { if let t = await turn(index) { idle.append(t) } }
        report("idle", idle)
        let idleStalls = stalls
        errors = [:]
        stalls = []
        statusReads = []

        // Folder check with real changes: NEW large files appear, periodic rescans keep coming.
        seedStart = DispatchTime.now().uptimeNanoseconds
        let fresh = folderURL.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        for index in 0..<newFiles {
            try Data(Self.text("new file \(index)", length: newKB * 1024).utf8).write(to: fresh.appendingPathComponent("new-\(index).txt"))
        }
        _ = try await runtime.scanNow(folderId: folder.id, verifyAll: false)
        var load: [Turn] = []
        var index = 0
        var lastRescan = DispatchTime.now().uptimeNanoseconds
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(loadSeconds) * 1_000_000_000
        var sawScanning = false
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let t = await turn(index) { load.append(t) }
            index += 1
            let scanning = try store.folderSource(id: folder.id).scanState == "scanning"
            sawScanning = sawScanning || scanning
            if DispatchTime.now().uptimeNanoseconds - lastRescan > UInt64(rescanEvery) * 1_000_000_000 {
                lastRescan = DispatchTime.now().uptimeNanoseconds
                _ = try? await runtime.scanNow(folderId: folder.id, verifyAll: false)
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        heartbeat = false
        statusRunning = false
        _ = await beat.value
        _ = await statusLoop.value
        walSampler.cancel()
        report("during-check", load)
        let published = try store.runOnDatabase { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM sources WHERE rel_path LIKE 'new/%' AND published_revision_id IS NOT NULL")!
        }
        let vectors = try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM chunk_embeddings")! }
        let queryWaits = await server.queryWaitsMs
        print(String(format: "CHAT-SCAN-BENCH background: newPublished=%d/%d vectors=%d sawScanning=%@ | main stalls idle max=%.0f; during p99=%.0f max=%.0f >100ms=%d >250ms=%d | status reads p50=%.0f p95=%.0f max=%.0f n=%d | query embed wait p50=%.0f p95=%.0f max=%.0f ms | wal max=%.1f MB",
                     published, newFiles, vectors, sawScanning ? "yes" : "no", idleStalls.max() ?? 0,
                     percentile(stalls, 0.99), stalls.max() ?? 0, stalls.filter { $0 > 100 }.count, stalls.filter { $0 > 250 }.count,
                     percentile(statusReads, 0.5), percentile(statusReads, 0.95), statusReads.max() ?? 0, statusReads.count,
                     percentile(queryWaits, 0.5), percentile(queryWaits, 0.95), queryWaits.max() ?? 0,
                     (walSizes.all.max() ?? 0) / 1e6))
        XCTAssertFalse(load.isEmpty, "chat turns complete during the folder check")
    }
}

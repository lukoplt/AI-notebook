import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

/// Fixed-latency embedder that stops the build (CancellationError) after `limit` calls
/// and records when each call started.
private final class TimedEmbedder: EmbeddingProducing, @unchecked Sendable {
    private let gate = NSLock()
    private let dims: Int
    private let latencyNs: UInt64
    private let limit: Int
    private var starts: [UInt64] = []
    private var sizes: [Int] = []
    init(dims: Int, latencyMs: Int, limit: Int) {
        self.dims = dims
        latencyNs = UInt64(latencyMs) * 1_000_000
        self.limit = limit
    }
    var calls: [(start: UInt64, size: Int)] { gate.lock(); defer { gate.unlock() }; return Array(zip(starts, sizes)) }
    /// False once the limit is reached (the stopping call is not recorded).
    private func record(_ size: Int) -> Bool {
        gate.lock(); defer { gate.unlock() }
        guard starts.count < limit else { return false }
        starts.append(DispatchTime.now().uptimeNanoseconds)
        sizes.append(size)
        return true
    }
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        if !record(inputs.count) { throw CancellationError() }
        if latencyNs > 0 { try await Task.sleep(nanoseconds: latencyNs) }
        return inputs.indices.map { index in (0..<dims).map { Float(($0 + index) % 7 + 1) } }
    }
}

/// Fixed-latency embedder that records each request's size, first input and start time.
private final class LatencyEmbedder: EmbeddingProducing, @unchecked Sendable {
    private let gate = NSLock()
    private let dims: Int
    private let latencyNs: UInt64
    private var log: [(start: UInt64, size: Int, documents: Int)] = []
    init(dims: Int, latencyMs: Int) {
        self.dims = dims
        latencyNs = UInt64(latencyMs) * 1_000_000
    }
    var calls: [(start: UInt64, size: Int, documents: Int)] { gate.lock(); defer { gate.unlock() }; return log }
    private func record(_ inputs: [String]) {
        gate.lock(); defer { gate.unlock() }
        log.append((DispatchTime.now().uptimeNanoseconds, inputs.count, inputs.filter { $0.hasPrefix("doc ") }.count))
    }
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        record(inputs)
        if latencyNs > 0 { try await Task.sleep(nanoseconds: latencyNs) }
        return inputs.map { text in
            let seed = text.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
            return (0..<dims).map { Float((Int(seed >> UInt32($0 % 24)) & 0xff) + 1) }
        }
    }
}

private struct FixedClock: IngestLeaseClock {
    func now() -> Int64 { 2 }
    func wait(until: Int64) async throws { try await Task.sleep(nanoseconds: 1_000_000_000) }
}

/// Opt-in synthetic large-folder benchmark (AINOTEBOOK_IDX_BENCH=1): one notebook,
/// many published sources and chunks in a file-backed database, a fresh
/// building generation, and the real `FolderIndexCoordinator` loop with a
/// fixed-latency fake embedder. Reports steady-state chunks/s.
@MainActor
final class FolderIndexThroughputBenchmarkTests: XCTestCase {
    private func setting(_ name: String, _ fallback: Int) -> Int {
        Int(ProcessInfo.processInfo.environment["AINOTEBOOK_IDX_BENCH_\(name)"] ?? "") ?? fallback
    }

    /// Seeds once per shape into a template file; each run works on a fresh copy.
    private func template(sources: Int, perSource: Int, textLength: Int) throws -> URL {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AINOTEBOOK_IDX_BENCH_DIR"] ?? NSTemporaryDirectory())
        let url = directory.appendingPathComponent("idx-bench-\(sources)x\(perSource)x\(textLength).sqlite")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let building = directory.appendingPathComponent("idx-bench-building-\(UUID().uuidString).sqlite")
        let store = try NotebookStore(path: StorePath(fileURL: building), configuredEmbeddingModelKey: nil)
        let notebookId = try XCTUnwrap(store.createNotebook(name: "bench").id)
        let words = ["dokument", "smlouva", "faktura", "report", "analysis", "vertrag", "projekt", "zmluva", "budget", "plan"]
        try store.runOnDatabase { db in
            // The per-batch path never reads FTS; seeding without it keeps the template fast.
            try db.execute(sql: "DROP TRIGGER chunks_ai")
            let source = try db.makeStatement(sql: """
                INSERT INTO sources(notebook_id,type,title,status,ingested_at) VALUES (?,'text',?,'ready','2026-10-10 00:00:00.000')
                """)
            let revision = try db.makeStatement(sql: """
                INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                VALUES (?,1,?,'',1,2,'2026-10-10 00:00:00.000')
                """)
            let publish = try db.makeStatement(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?")
            let chunk = try db.makeStatement(sql: """
                INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id,char_start,char_end,lang) VALUES (?,?,?,?,?,?,?,'cs')
                """)
            for s in 0..<sources {
                try source.execute(arguments: [notebookId, "file-\(s).txt"])
                let sourceId = db.lastInsertedRowID
                try revision.execute(arguments: [sourceId, "hash-\(s)"])
                let revisionId = db.lastInsertedRowID
                try publish.execute(arguments: [revisionId, revisionId, sourceId])
                for ord in 0..<perSource {
                    var text = "source \(s) chunk \(ord) "
                    var w = s &+ ord
                    while text.utf8.count < textLength { text += words[w % words.count] + " "; w &+= 7 }
                    try chunk.execute(arguments: [sourceId, ord, text, textLength / 4, revisionId, ord * textLength, (ord + 1) * textLength])
                }
            }
            try db.execute(sql: """
                CREATE TRIGGER chunks_ai AFTER INSERT ON source_chunks BEGIN
                 INSERT INTO chunks_fts(rowid,text,chunk_id) VALUES(new.id,new.text,new.id);
                END
                """)
        }
        try FileManager.default.moveItem(at: building, to: url)
        return url
    }

    /// Full build of a notebook with a spreadsheet-heavy mix (spreadsheets first by id, many
    /// ~200-chunk sheets, one template copied N times, then documents) against a fixed-latency
    /// provider. Reports provider requests/inputs, wall time and when the last document chunk
    /// was sent. Uses only APIs that predate `embedding-plan-v1`, so the same test measures
    /// the previous build loop on an older checkout.
    func testMixedNotebookFullBuild() async throws {
        guard ProcessInfo.processInfo.environment["AINOTEBOOK_IDX_BENCH"] == "1" else {
            throw XCTSkip("set AINOTEBOOK_IDX_BENCH=1 to run the mixed-notebook build benchmark")
        }
        let sheets = setting("SHEETS", 100), sheetChunks = setting("SHEET_CHUNKS", 200), copies = setting("COPIES", 20)
        let documents = setting("DOCS", 500), documentChunks = setting("DOC_CHUNKS", 20)
        let dims = setting("DIMS", 768), latencyMs = setting("LATENCY_MS", 100), textLength = setting("TEXT", 600)
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebookId = try XCTUnwrap(store.createNotebook(name: "mix").id)
        func padded(_ prefix: String) -> String {
            var text = prefix + " "
            var n = prefix.utf8.reduce(0) { $0 &+ Int($1) }
            while text.utf8.count < textLength { text += ["faktura", "smlouva", "row", "budget", "plan", "zmluva"][n % 6] + " "; n &+= 7 }
            return text
        }
        var total = 0
        try store.runOnDatabase { db in
            var nextId: Int64 = 1
            func add(type: String, texts: [String]) throws {
                let id = nextId
                nextId += 1
                try db.execute(sql: "INSERT INTO sources(id,notebook_id,type,title,status,ingested_at) VALUES (?,?,?,?,'ready','2026-10-11 00:00:00.000')",
                               arguments: [id, notebookId, type, "\(type)-\(id)"])
                try db.execute(sql: """
                    INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES (?,1,?,'',1,2,'2026-10-11 00:00:00.000')
                    """, arguments: [id, "h\(id)"])
                let revision = db.lastInsertedRowID
                try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?", arguments: [revision, revision, id])
                let insert = try db.makeStatement(sql: """
                    INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id,char_start,char_end) VALUES (?,?,?,?,?,0,0)
                    """)
                for (ord, text) in texts.enumerated() { try insert.execute(arguments: [id, ord, text, textLength / 4, revision]) }
                total += texts.count
            }
            let template = (0..<sheetChunks).map { padded("template row \($0)") }
            for _ in 0..<copies { try add(type: "xlsx", texts: template) }
            for sheet in 0..<sheets { try add(type: "xlsx", texts: (0..<sheetChunks).map { padded("sheet \(sheet) row \($0)") }) }
            let kinds = ["pdf", "docx", "email", "pptx"]
            for document in 0..<documents {
                try add(type: kinds[document % kinds.count], texts: (0..<documentChunks).map { padded("doc \(document) part \($0)") })
            }
        }
        let selection = EmbeddingSelection(providerId: "local", endpointRevision: "bench", model: "nomic-embed-text", modelDigest: nil,
            dims: dims, normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")
        let embedder = LatencyEmbedder(dims: dims, latencyMs: latencyMs)
        let jobId = try store.requestEmbeddingBuild(notebookId: notebookId, selection: selection, copyExisting: false, now: 1)
        let job = try XCTUnwrap(store.claimJob(now: 1, leaseToken: "bench", id: jobId))
        let coordinator = FolderIndexCoordinator(store: store, admission: IngestionAdmission(), clock: FixedClock(),
            session: { _ in FolderEmbeddingSession(selection: selection, embedder: embedder) },
            selectedSelection: { _ in selection }, batchSize: FolderIndexCoordinator.batchSize)
        let started = DispatchTime.now().uptimeNanoseconds
        try await coordinator.execute(job: job, fence: JobFence(jobId: jobId, leaseToken: "bench"))
        let finished = DispatchTime.now().uptimeNanoseconds
        XCTAssertNotNil(try store.activeGeneration(notebookId: notebookId), "the build completes and activates")
        let calls = embedder.calls
        let lastDocument = calls.last { $0.documents > 0 }.map { Double($0.start - started) / 1e9 } ?? 0
        let vectors = try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM chunk_embeddings")! }
        print(String(format: "IDX-MIX swift chunks=%d sheets=%d+%dcopies x%d docs=%dx%d latencyMs=%d: requests=%d inputs=%d vectors=%d wall=%.1fs lastDocumentSentAt=%.1fs",
                     total, sheets, copies, sheetChunks, documents, documentChunks, latencyMs, calls.count,
                     calls.reduce(0) { $0 + $1.size }, vectors, Double(finished - started) / 1e9, lastDocument))
    }

    func testBackgroundEmbeddingThroughput() async throws {
        guard ProcessInfo.processInfo.environment["AINOTEBOOK_IDX_BENCH"] == "1" else {
            throw XCTSkip("set AINOTEBOOK_IDX_BENCH=1 to run the indexing throughput benchmark")
        }
        let sources = setting("SOURCES", 5_000), perSource = setting("CHUNKS", 80), textLength = setting("TEXT", 1_500)
        let dims = setting("DIMS", 768), latencyMs = setting("LATENCY_MS", 0), batches = setting("BATCHES", 40)
        let batchSize = setting("BATCH_SIZE", FolderIndexCoordinator.batchSize)
        let seed = try template(sources: sources, perSource: perSource, textLength: textLength)
        let work = seed.deletingLastPathComponent().appendingPathComponent("idx-bench-run-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: seed, to: work)
        defer { try? FileManager.default.removeItem(at: work) }

        let store = try NotebookStore(path: StorePath(fileURL: work), configuredEmbeddingModelKey: nil)
        let notebookId = try XCTUnwrap(store.notebooks.first?.id)
        let selection = EmbeddingSelection(providerId: "local", endpointRevision: "bench", model: "nomic-embed-text", modelDigest: nil,
            dims: dims, normalization: "l2", queryFormatVersion: "1", docFormatVersion: "1", chunkerVersion: "2")
        let jobId = try store.requestEmbeddingBuild(notebookId: notebookId, selection: selection, copyExisting: false, now: 1)
        let job = try XCTUnwrap(store.claimJob(now: 1, leaseToken: "bench", id: jobId))
        let embedder = TimedEmbedder(dims: dims, latencyMs: latencyMs, limit: batches)
        let coordinator = FolderIndexCoordinator(store: store, admission: IngestionAdmission(), clock: FixedClock(),
            session: { _ in FolderEmbeddingSession(selection: selection, embedder: embedder) },
            selectedSelection: { _ in selection }, batchSize: batchSize)
        do {
            try await coordinator.execute(job: job, fence: JobFence(jobId: jobId, leaseToken: "bench"))
        } catch is CancellationError {}
        let calls = embedder.calls
        XCTAssertGreaterThanOrEqual(batches, 3)
        XCTAssertEqual(calls.count, batches)
        // Steady state: the first interval (cold page cache, first settle) is excluded.
        let chunks = calls.dropFirst().dropLast().reduce(0) { $0 + $1.size }
        let seconds = Double(calls.last!.start - calls[1].start) / 1e9
        let stored = try store.runOnDatabase { try Int.fetchOne($0, sql: "SELECT count(*) FROM chunk_embeddings")! }
        XCTAssertEqual(stored, calls.reduce(0) { $0 + $1.size }, "every answered batch committed")
        let perBatchMs = seconds * 1000 / Double(calls.count - 2)
        print(String(format: "IDX-BENCH swift sources=%d chunks=%d text=%d dims=%d batch=%d latencyMs=%d: %.1f chunks/s, %.1f ms/batch (%.1f ms non-provider)",
                     sources, sources * perSource, textLength, dims, batchSize, latencyMs, Double(chunks) / seconds,
                     perBatchMs, perBatchMs - Double(latencyMs)))
    }
}

import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

/// Opt-in, local-only evaluation on a real folder (AINOTEBOOK_REAL_FOLDER=/path). Ingests the
/// folder with the production scanner and extraction worker into a store outside the repository
/// (lexical only: no embedding provider is needed), builds the real context pack for a question
/// and prints metrics only. Nothing about the folder is hard-coded here: the question and the
/// expectations come from the environment and file names are never printed.
///
/// - AINOTEBOOK_REAL_QUESTION: the question (required).
/// - AINOTEBOOK_REAL_EXPECT: comma-separated path substrings every one of which must occur in a
///   "Matching files" line of the pack (e.g. project folder names), both with a 32 768-token context and with
///   the 8 192-token default the app assumes for an unlisted remote model.
/// - AINOTEBOOK_REAL_REJECT: comma-separated path substrings no matching line may contain.
/// - AINOTEBOOK_REAL_DB: reuse/persist the ingested store at this path (default: a temp file).
@MainActor
final class RealFolderRetrievalEvalTests: XCTestCase {
    private struct Clock: IngestLeaseClock {
        func now() -> Int64 { Int64(Date().timeIntervalSince1970) }
        func wait(until: Int64) async throws {
            try await Task.sleep(nanoseconds: UInt64(max(0, until - now())) * 1_000_000_000)
        }
    }

    func testRealFolderQuestion() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folderPath = environment["AINOTEBOOK_REAL_FOLDER"] else {
            throw XCTSkip("set AINOTEBOOK_REAL_FOLDER=/path (and AINOTEBOOK_REAL_QUESTION) to run the real-folder eval")
        }
        let question = try XCTUnwrap(environment["AINOTEBOOK_REAL_QUESTION"], "AINOTEBOOK_REAL_QUESTION is required")
        func list(_ name: String) -> [String] {
            (environment[name] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let expect = list("AINOTEBOOK_REAL_EXPECT"), reject = list("AINOTEBOOK_REAL_REJECT")
        let dbURL = URL(fileURLWithPath: environment["AINOTEBOOK_REAL_DB"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("real-eval-\(UUID().uuidString).sqlite").path)
        let reuse = FileManager.default.fileExists(atPath: dbURL.path)
        let store = try NotebookStore(path: StorePath(fileURL: dbURL), configuredEmbeddingModelKey: nil)
        let fileSystem = NativeFolderFileSystem(), clock = Clock()
        let notebookId: Int64, sessionId: Int64
        let started = DispatchTime.now().uptimeNanoseconds
        if reuse, let existing = store.notebooks.first?.id {
            notebookId = existing
            sessionId = try XCTUnwrap(store.createChatSession(notebookId: notebookId, title: "eval").id)
        } else {
            notebookId = try XCTUnwrap(store.createNotebook(name: "real-eval").id)
            sessionId = try XCTUnwrap(store.createChatSession(notebookId: notebookId, title: "eval").id)
            let folder = try store.createFolder(notebookId: notebookId, draft: FolderDraft(rootPath: folderPath, displayName: "Real",
                includeExts: FolderRules.defaults.includeExts, ignoreGlobs: FolderRules.defaults.ignoreGlobs, limitsJSON: "{}",
                encodingFallback: "cp1250", watchEnabled: false), identity: fileSystem, now: clock.now())
            let scanJob = try store.requestFolderScan(folderId: folder.id, verifyAll: false, now: clock.now())
            _ = try XCTUnwrap(store.claimJob(now: clock.now(), leaseToken: "scan", id: scanJob))
            try await FolderScanner(store: store, fileSystem: fileSystem, tables: try UnicodeTables.bundled(), clock: clock)
                .scan(folderId: folder.id, verifyAll: false, fence: JobFence(jobId: scanJob, leaseToken: "scan"),
                      now: clock.now(), cancelled: { false })
        }
        // Drain every queued extraction (also after an interrupted run reusing the store).
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        let admission = IngestionAdmission(maxExtractions: width,
            memoryBytes: AdaptiveConcurrency.memoryBudget(physicalBytes: Int64(ProcessInfo.processInfo.physicalMemory)))
        let queue = JobQueue(store: store, clock: clock, admission: admission)
        let extractor = BoundedDocumentExtractor()
        let worker = FolderExtractionWorker(store: store, fileSystem: fileSystem, detector: .bundled(), clock: clock,
            embeddingSelection: { _ in nil },
            extract: { url, kind, rules in try await extractor.extract(url: url, kind: kind, rules: rules) })
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<width {
                group.addTask(priority: .utility) {
                    while true {
                        let ran = try? await queue.runOne(kind: "extract", reservation: { job in
                            try store.extractionReservation(job: job)
                        }, execute: { job, fence in try await worker.execute(job: job, fence: fence) })
                        if ran != true { return }
                    }
                }
            }
        }
        let (sources, published, chunks) = try store.runOnDatabase { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM sources")!,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM sources WHERE published_revision_id IS NOT NULL")!,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM source_chunks")!)
        }
        print(String(format: "REAL-EVAL store sources=%d published=%d chunks=%d (%@ in %.0fs)", sources, published, chunks,
                     reuse ? "reused" : "ingested", Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9))

        let retriever = Retriever(store: store, client: NoRealEmbedding(), modelKey: { "none" }, cache: VectorMatrixCache())
        // A large local context, then the 8 192-token default the app assumes for an unlisted
        // OpenWebUI / OpenAI-compatible model: the expected paths must be INCLUDED in the pack.
        let models = [
            ("ctx32768", PackModel(providerId: "eval", model: "eval-chat", runtimeContext: 32_768, maxOutputTokens: 1_024,
                                   contextWindowKnown: true, providerType: "ollama")),
            ("ctx8192", PackModel(providerId: "eval", model: "eval-chat", runtimeContext: RagContractV1.Providers.defaultRuntimeContext,
                                  maxOutputTokens: RagContractV1.Providers.defaultMaxOutputTokens, contextWindowKnown: false,
                                  providerType: "openwebui")),
        ]
        for (label, model) in models {
            let engine = ChatEngine(store: store,
                coordinator: ContextPackCoordinator(data: CompatibilityPackDataSource(store: store, retriever: retriever),
                                                    transports: ReleaseTransportFactory(transport: ReleaseTransport(model: model, answer: "-"))),
                previews: ContextPreviewSession(), chatModel: "eval-chat", admission: IngestionAdmission())
            let t0 = DispatchTime.now().uptimeNanoseconds
            let intent = try await engine.captureIntent(sessionId: sessionId, notebookId: notebookId, question: question, scope: .all)
            let handle = try await engine.prepare(intent)
            let prepareMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            let map = handle.request.messages.flatMap(\.sections).filter { $0.kind == "map" }.map(\.text).joined(separator: "\n")
            var inBlock = false, grouped = false
            var matchingLines: [String] = []
            for line in map.components(separatedBy: "\n") {
                if line.hasPrefix("Matching files") { inBlock = true; grouped = line.hasPrefix("Matching files by project"); continue }
                if inBlock { if line.hasPrefix("  ") { matchingLines.append(line) } else { inBlock = false } }
            }
            let evidencePaths = handle.request.citationMap.compactMap(\.relPath)
            let found = expect.filter { needle in matchingLines.contains { $0.contains(needle) } }
            let foundInEvidence = expect.filter { needle in evidencePaths.contains { $0.contains(needle) } }
            let rejected = reject.filter { needle in matchingLines.contains { $0.contains(needle) } }
            let mapTokens = handle.request.messages.flatMap(\.sections).filter { $0.kind == "map" }.map(\.tokens).reduce(0, +)
            let estimated = handle.request.messages.reduce(0) { $0 + 4 + $1.sections.reduce(0) { $0 + $1.tokens } }
            print(String(format: "REAL-EVAL %@ prepare %.0f ms | tokens %d/%d, map %d | matching %@ lines=%d | expected included in matching=%d/%d, in evidence=%d/%d | rejected present=%d/%d | citations=%d",
                         label, prepareMs, estimated, model.runtimeContext - model.maxOutputTokens, mapTokens,
                         grouped ? "grouped" : "file-level", matchingLines.count, found.count, expect.count,
                         foundInEvidence.count, expect.count, rejected.count, reject.count, handle.request.citationMap.count))
            XCTAssertEqual(found.count, expect.count, "\(label): every expected path substring is included in the matching block")
            XCTAssertTrue(rejected.isEmpty, "\(label): no rejected path substring is listed among the matching files")
        }
    }
}

private struct NoRealEmbedding: EmbeddingProducing {
    func embed(model: String, inputs: [String]) async throws -> [[Float]] { throw CancellationError() }
}

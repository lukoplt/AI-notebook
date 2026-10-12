import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

// WP9 release integration support. Test infrastructure only: real file-backed
// store (v18 fixture upgraded through the ordinary initializer), native
// filesystem, bounded extractors, bundled detector/Unicode tables, durable
// queue, generation coordinator, retriever, context-pack coordinator and
// ChatEngine. Only embeddings (in-memory URLProtocol / query double), the chat
// transport, watches and the clock are controlled doubles.

// MARK: - Shared fixture

struct ReleaseExpected: Decodable, Sendable {
    var files: Int?
    var searchable: Int?
    var refreshPending: Int?
    var refreshError: Int?
    var savedMarkers: [Int]?
    var citationVersion: Int?
    var sameSource: Bool?
    var newRevision: Bool?
    var cancelledState: String?
    var oldRevisionRetained: Bool?
    var newJob: Bool?
    var before: String?
    var after: String?
    var missing: Int?
    var oldCitationReadable: Bool?
    var eligible: Bool?
    var availability: String?
    var vectorIncludes: Bool?
    var lexicalIncludes: Bool?
    var mapIncludes: Bool?
    var overviewIncludes: Bool?
    var citations: Int?
    var queryEmbeddingCalls: Int?
    var evidenceSections: Int?
}

struct ReleaseCase: Decodable, Sendable {
    var name: String
    var relPath: String?
    var append: String?
    var pattern: String?
    var cap: Int?
    var expected: ReleaseExpected
}

struct ReleaseAsset: Decodable, Sendable {
    var kind: String
    var repoPath: String
    var relPath: String
    var rawSha256: String
    var canonicalText: String
    var encoding: String?
    var language: String?
}

struct ReleaseEndpointCase: Decodable, Sendable {
    var type: String
    var root: String
    var expected: String
}

struct ReleaseFixture: Decodable, Sendable {
    var contract: String
    var version: Int
    var assets: [ReleaseAsset]
    var endpointCases: [ReleaseEndpointCase]
    var rulesText: String
    var question: String
    var answer: String
    var instructions: String
    var dbFixture: String
    var dbSha256: String
    var runtimeContext: Int
    var maxOutputTokens: Int
    var fetchK: Int
    var topK: Int
    var cases: [ReleaseCase]

    static let supportedCases = ["upgrade-chat", "restart-reconcile", "cancel-resume", "delete-completed-scan",
                                 "rules-restrict", "empty-selection", "zero-evidence"]

    /// The workbook asset's canonical text is superseded by `ingestion-xlsx-v2`.
    static func load() throws -> ReleaseFixture {
        var fixture = try JSONDecoder().decode(ReleaseFixture.self, from: SharedFixtures.data("contracts/release-integration-v1.json"))
        let superseded = try SpreadsheetSupersession.map()["release-integration-v1.json"] ?? [:]
        for index in fixture.assets.indices {
            if let text = superseded[fixture.assets[index].relPath]?["canonicalText"] as? String {
                fixture.assets[index].canonicalText = text
            }
        }
        return fixture
    }

    func caseNamed(_ name: String) -> ReleaseCase {
        guard let row = cases.first(where: { $0.name == name }) else {
            preconditionFailure("release fixture has no case \(name)")
        }
        return row
    }

    /// Repository root (parent of `Tests/`).
    static var repoRoot: URL {
        SharedFixtures.root.deletingLastPathComponent().deletingLastPathComponent()
    }
}

// MARK: - Controlled boundaries

/// Serves only `POST https://wp9.invalid/v1/embeddings` for model `wp9-2d`;
/// every other URL fails, so nothing reaches the network.
final class ReleaseEmbeddingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard request.url?.absoluteString == "https://wp9.invalid/v1/embeddings",
                  let body = request.bodyData,
                  let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  json["model"] as? String == "wp9-2d",
                  let inputs = json["input"] as? [String]
            else { throw URLError(.badURL) }
            let data = try JSONSerialization.data(withJSONObject: ["data": inputs.enumerated().map {
                ["index": $0.offset, "embedding": [1, 0]] as [String: Any]
            }])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

/// Query-side embedding: counts calls and checks the pinned generation's endpoint identity.
actor ReleaseQueryEmbedding: EmbeddingProducing, EmbeddingSessionPreparing {
    private(set) var calls = 0
    let expectedEndpoint: String

    init(expectedEndpoint: String) { self.expectedEndpoint = expectedEndpoint }

    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        try Task.checkCancellation()
        calls += 1
        return inputs.map { _ in [1, 0] }
    }

    func prepareEmbedding(identity: GenerationIdentity) async throws -> ProviderEmbeddingSession {
        XCTAssertEqual(identity.endpointRevision, expectedEndpoint)
        return ProviderEmbeddingSession(client: self, model: identity.model,
                                        storageKey: identity.providerId + ":" + identity.model,
                                        endpointRevision: identity.endpointRevision)
    }
}

/// Fixed time; waits for a future deadline only end when cancelled.
struct ReleaseClock: IngestLeaseClock {
    func now() -> Int64 { 1_800_000_000 }
    func wait(until: Int64) async throws {
        if until <= now() { return }
        let pair = AsyncStream<Void>.makeStream()
        let continuation = pair.continuation
        try await withTaskCancellationHandler {
            for await _ in pair.stream {}
            try Task.checkCancellation()
        } onCancel: {
            continuation.finish()
        }
    }
}

struct ReleaseSilentWatches: FolderWatchFactory {
    struct Handle: FolderWatchHandle {
        func start() throws {}
        func stop() {}
    }
    func make(folder: FolderSource, onEvent: @escaping @Sendable (String) -> Void) throws -> any FolderWatchHandle {
        Handle()
    }
}

/// Captures the exact prepared request at the provider boundary.
actor ReleaseTransport: PreparedPackTransport {
    nonisolated let model: PackModel
    nonisolated let answer: String
    private(set) var requests: [Data] = []

    init(model: PackModel, answer: String) {
        self.model = model
        self.answer = answer
    }

    private func record(_ request: PreparedContextRequest) throws {
        requests.append(try PreparedContextRequestJSON.encode(request))
    }

    nonisolated func stream(_ request: PreparedContextRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.record(request)
                    try Task.checkCancellation()
                    continuation.yield(self.answer)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct ReleaseTransportFactory: PackTransportFactory {
    let transport: ReleaseTransport
    func freeze(_ intent: PackIntent) async throws -> any PreparedPackTransport { transport }
    func describe(requestedModel: String?) async throws -> PackTransportDescription {
        PackTransportDescription(model: transport.model, configurationRevision: 0)
    }
}

/// Barrier after the real bounded extractor and before language/chunk
/// publication. Disarmed it only honours cancellation.
actor ReleaseExtractionGate {
    private var armed = false
    private var entered = false
    private var released = false
    private var onEntered: (@Sendable () -> Void)?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    var hasEntered: Bool { entered }

    func arm(_ callback: @escaping @Sendable () -> Void) {
        armed = true
        entered = false
        released = false
        onEntered = callback
    }

    func afterExtraction() async throws {
        guard armed else { try Task.checkCancellation(); return }
        armed = false
        entered = true
        onEntered?()
        onEntered = nil
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
        try Task.checkCancellation()
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

// MARK: - Harness

/// Everything bound to one open store. `close()` discards it entirely.
@MainActor
struct ReleaseGraph {
    let store: NotebookStore
    let http: URLSession
    let embedding: FolderEmbeddingSession
    let scanner: FolderScanner
    let worker: FolderExtractionWorker
    let queue: JobQueue
    let runtime: FolderIngestionRuntime
    let retriever: Retriever
    let queryEmbedding: ReleaseQueryEmbedding
    let transport: ReleaseTransport
    let previews: ContextPreviewSession
    let engine: ChatEngine
}

struct ReleaseIntegrationError: Error, CustomStringConvertible {
    let description: String
}

@MainActor
final class ReleaseHarness {
    static let providerRoot = "https://wp9.invalid/v1"

    let fixture: ReleaseFixture
    let root: URL
    let folderURL: URL
    let databaseURL: URL
    let clock = ReleaseClock()
    let gate = ReleaseExtractionGate()
    private(set) var notebookId: Int64 = 0
    private(set) var sessionId: Int64 = 0
    private(set) var folderId: Int64 = 0
    private var graph: ReleaseGraph?

    var store: NotebookStore { graph!.store }
    var scanner: FolderScanner { graph!.scanner }
    var worker: FolderExtractionWorker { graph!.worker }
    var queue: JobQueue { graph!.queue }
    var runtime: FolderIngestionRuntime { graph!.runtime }
    var retriever: Retriever { graph!.retriever }
    var queryEmbedding: ReleaseQueryEmbedding { graph!.queryEmbedding }
    var transport: ReleaseTransport { graph!.transport }
    var previews: ContextPreviewSession { graph!.previews }
    var engine: ChatEngine { graph!.engine }

    private init(fixture: ReleaseFixture, root: URL) {
        self.fixture = fixture
        self.root = root
        folderURL = root.appendingPathComponent("Folder", isDirectory: true)
        databaseURL = root.appendingPathComponent("db.sqlite")
    }

    /// Copies the v18 fixture and six assets into a unique temporary tree,
    /// upgrades through the ordinary store initializer, adds the folder once
    /// through the runtime and drains the durable queue.
    static func open() async throws -> ReleaseHarness {
        let fixture = try ReleaseFixture.load()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ainotebook-wp9-" + UUID().uuidString, isDirectory: true)
        let h = ReleaseHarness(fixture: fixture, root: root)
        do {
            try h.materialize()
            try h.makeGraph()
            let notebook = try h.store.createNotebook(name: "WP9 integration")
            h.notebookId = try XCTUnwrap(notebook.id)
            h.sessionId = try XCTUnwrap(h.store.createChatSession(notebookId: h.notebookId, title: "Release chat").id)
            let folder = try await h.runtime.addFolder(notebookId: h.notebookId, url: h.folderURL)
            h.folderId = folder.id
            try await h.drain()
            return h
        } catch {
            await h.close()
            try? h.removeTemporaryFiles()
            throw error
        }
    }

    private func materialize() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let db = try SharedFixtures.data(fixture.dbFixture)
        guard Self.sha(db) == fixture.dbSha256 else { throw ReleaseIntegrationError(description: "v18 fixture hash") }
        try db.write(to: databaseURL)
        for asset in fixture.assets {
            let parts = asset.relPath.split(separator: "/", omittingEmptySubsequences: false)
            guard !asset.relPath.isEmpty, !asset.relPath.hasPrefix("/"),
                  !parts.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else {
                throw ReleaseIntegrationError(description: "unsafe relPath \(asset.relPath)")
            }
            let bytes = try Data(contentsOf: ReleaseFixture.repoRoot.appendingPathComponent(asset.repoPath))
            guard Self.sha(bytes) == asset.rawSha256 else {
                throw ReleaseIntegrationError(description: "asset hash \(asset.repoPath)")
            }
            let destination = folderURL.appendingPathComponent(asset.relPath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: destination)
        }
    }

    private func makeGraph() throws {
        let store = try NotebookStore(path: StorePath(fileURL: databaseURL), configuredEmbeddingModelKey: nil)
        let config = ProviderConfig(id: "wp9", type: .openaiCompatible, name: "WP9", baseURL: Self.providerRoot,
                                    privacyAcknowledged: true, createdAt: Date(timeIntervalSince1970: 0))
        if try store.provider(id: "wp9") == nil { try store.saveProvider(config) }
        let urlConfig = URLSessionConfiguration.ephemeral
        urlConfig.protocolClasses = [ReleaseEmbeddingURLProtocol.self]
        let http = URLSession(configuration: urlConfig)
        let embedding = try FolderEmbeddingSession(config: config, model: "wp9-2d", apiKey: nil, modelDigest: nil,
                                                   queryFormatVersion: "1", docFormatVersion: "1", session: http)
        let fs = NativeFolderFileSystem()
        let clock = self.clock, gate = self.gate
        let admission = IngestionAdmission()
        let scanner = FolderScanner(store: store, fileSystem: fs, tables: try UnicodeTables.bundled(), clock: clock)
        let extractor = BoundedDocumentExtractor()
        let worker = FolderExtractionWorker(store: store, fileSystem: fs, detector: LanguageDetector.bundled(),
            clock: clock, embeddingSelection: { _ in embedding.selection },
            extract: { url, kind, rules in
                let document = try await extractor.extract(url: url, kind: kind, rules: rules)
                try await gate.afterExtraction()
                return document
            })
        let index = FolderIndexCoordinator(store: store, admission: admission, clock: clock,
            session: { _ in embedding }, selectedSelection: { _ in embedding.selection })
        let queue = JobQueue(store: store, clock: clock, admission: admission)
        let runtime = FolderIngestionRuntime(store: store, scanner: scanner, extraction: worker, index: index,
            queue: queue, clock: clock, admission: admission, watches: ReleaseSilentWatches(), dispatch: false,
            milliseconds: { 0 }, observe: { _ in })
        let queryEmbedding = ReleaseQueryEmbedding(expectedEndpoint: embedding.selection.endpointRevision)
        let retriever = Retriever(store: store, client: queryEmbedding, modelKey: { "wp9:wp9-2d" },
                                  cache: VectorMatrixCache())
        let transport = ReleaseTransport(model: PackModel(providerId: "wp9", model: "wp9-chat",
            runtimeContext: fixture.runtimeContext, maxOutputTokens: fixture.maxOutputTokens,
            contextWindowKnown: true, providerType: "openai_compatible"), answer: fixture.answer)
        let previews = ContextPreviewSession()
        let coordinator = ContextPackCoordinator(data: CompatibilityPackDataSource(store: store, retriever: retriever),
                                                 transports: ReleaseTransportFactory(transport: transport))
        let engine = ChatEngine(store: store, coordinator: coordinator, previews: previews, chatModel: "wp9-chat")
        graph = ReleaseGraph(store: store, http: http, embedding: embedding, scanner: scanner, worker: worker,
                             queue: queue, runtime: runtime, retriever: retriever, queryEmbedding: queryEmbedding,
                             transport: transport, previews: previews, engine: engine)
    }

    /// Stops and joins runtime and queue, then discards the whole graph.
    func close() async {
        await gate.release()
        guard let current = graph else { return }
        await current.runtime.stop()
        await current.queue.stop()
        current.http.invalidateAndCancel()
        graph = nil
    }

    /// A new graph over the same database; never re-adds the folder.
    func reopen() async throws {
        precondition(graph == nil, "close() before reopen()")
        try makeGraph()
    }

    func removeTemporaryFiles() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func drain() async throws {
        for _ in 0..<256 { if try await !runtime.drainOnce() { return } }
        XCTFail("durable queue did not quiesce in 256 attempts")
        throw ReleaseIntegrationError(description: "releaseDrainExceeded")
    }

    func source(_ relPath: String) throws -> Source {
        let matches = try store.sources(notebookId: notebookId).filter { $0.folderId == folderId && $0.relPath == relPath }
        guard matches.count == 1 else { throw ReleaseIntegrationError(description: "source \(relPath): \(matches.count)") }
        return matches[0]
    }

    func prepare(scope: RetrievalScope? = nil, mode: String = "answer", cap: Int? = nil) async throws -> PreparedPackHandle {
        let selected = scope ?? .selection(sourceIds: [], folderIds: [folderId])
        let intent = PackIntent(notebookId: notebookId, sessionId: sessionId, question: fixture.question, mode: mode,
            scope: selected, providerId: "wp9", model: "wp9-chat", providerConfigurationRevision: 0,
            runtimeContext: fixture.runtimeContext, maxOutputTokens: fixture.maxOutputTokens, evidenceBudgetCap: cap,
            fetchK: fixture.fetchK, topK: fixture.topK, notebookInstructions: "", instructionsOverride: fixture.instructions,
            currentNoteContent: nil, useWebSearch: false,
            historyFingerprint: try store.contextHistoryFingerprint(sessionId: sessionId),
            scopeFingerprint: try store.contextScopeFingerprint(notebookId: notebookId, scope: selected),
            regenerateUserId: nil, replacesAssistantId: nil)
        return try await engine.prepare(intent)
    }

    func send(_ handle: PreparedPackHandle) async throws -> ChatMessage {
        try await engine.sendPrepared(handle, expectedKey: handle.key, onToken: { _ in })
    }

    func integer(_ sql: String) throws -> Int {
        try store.runOnDatabase { try Int.fetchOne($0, sql: sql)! }
    }

    func rawCitations(assistantId: Int64) throws -> String {
        try store.runOnDatabase {
            try String.fetchOne($0, sql: "SELECT citations_json FROM messages WHERE id=?", arguments: [assistantId])!
        }
    }

    // MARK: Lifecycle operations

    /// Requests a verify-all scan and runs exactly that scan job (no extraction).
    func scanOnly() async throws {
        _ = try store.requestFolderScan(folderId: folderId, verifyAll: true, now: clock.now())
        let scanner = self.scanner, folderId = self.folderId, clock = self.clock
        let ran = try await queue.runOne(kind: "scan", reservedBytes: 0) { _, fence in
            try await scanner.scan(folderId: folderId, verifyAll: true, fence: fence, now: clock.now(),
                                   cancelled: { Task.isCancelled })
        }
        XCTAssertTrue(ran)
    }

    /// The production startup operation: the runtime's reconciler recovers
    /// durable state and schedules every watch-enabled folder.
    func reconcile() async throws {
        try await runtime.start()
    }

    func append(caseName: String) throws {
        let row = fixture.caseNamed(caseName)
        let path = folderURL.appendingPathComponent(row.relPath!)
        var bytes = try Data(contentsOf: path)
        bytes.append(Data(row.append!.utf8))
        try bytes.write(to: path, options: .atomic)
    }

    func delete(relPath: String) throws {
        try FileManager.default.removeItem(at: folderURL.appendingPathComponent(relPath))
    }

    func pool(query: String, includeVectors: Bool = true) async throws -> PinnedRetrievalCandidates {
        try await retriever.search(notebookId: notebookId, query: query,
                                   scope: .selection(sourceIds: [], folderIds: [folderId]),
                                   fetchK: fixture.fetchK, includeVectors: includeVectors)
    }

    // MARK: Assertions

    /// Shared expected counts plus real DB observations for one prepared pack.
    func assertPack(_ request: PreparedContextRequest, caseName: String,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let expected = fixture.caseNamed(caseName).expected
        let corpus = request.coverage.corpus
        XCTAssertEqual(corpus.filesInScope, expected.files, file: file, line: line)
        XCTAssertEqual(corpus.searchable, expected.searchable, file: file, line: line)
        XCTAssertEqual(corpus.refreshPending, expected.refreshPending, file: file, line: line)
        XCTAssertEqual(corpus.refreshError, expected.refreshError, file: file, line: line)
        XCTAssertFalse(corpus.partial, file: file, line: line)
        XCTAssertNotNil(request.generationId, file: file, line: line)
        XCTAssertEqual(request.generationId, try store.activeGeneration(notebookId: notebookId)?.id, file: file, line: line)
        XCTAssertEqual(request.messages.first?.sections.map(\.kind), ["rules", "instructions"], file: file, line: line)
        XCTAssertEqual(request.messages.first?.sections.first?.text, fixture.rulesText, file: file, line: line)
        XCTAssertEqual(request.messages.first?.sections.last?.text, fixture.instructions, file: file, line: line)
        let sections = try XCTUnwrap(request.messages.last?.sections)
        XCTAssertEqual(sections.map(\.kind), ["scope", "map"] + Array(repeating: "evidence", count: 6) + ["question"],
                       file: file, line: line)
        XCTAssertEqual(sections.last?.text, "[QUESTION]\n" + fixture.question + "\n[/QUESTION]", file: file, line: line)
        let scope = sections[0].text
        for needle in ["Scope: Folder", "Scan: idle; last complete:", "Corpus: 6 files; 6 searchable",
                       "Freshness: 0 refresh pending; 0 refresh error", "Turn: 6 passages from 6 files"] {
            XCTAssertTrue(scope.contains(needle), "scope lacks \(needle): \(scope)", file: file, line: line)
        }
        XCTAssertFalse(scope.contains("last complete: unknown"), file: file, line: line)
        let map = sections[1].text
        var documentLabels = Set<String>()
        for asset in fixture.assets {
            let source = try self.source(asset.relPath)
            XCTAssertEqual(source.availability, "present", file: file, line: line)
            XCTAssertTrue(source.eligible, file: file, line: line)
            let revisionId = try XCTUnwrap(source.publishedRevisionId)
            let canonical = try XCTUnwrap(store.revision(id: revisionId)).draft.canonicalText
            XCTAssertEqual(Array(canonical.utf8), Array(asset.canonicalText.utf8), asset.relPath, file: file, line: line)
            XCTAssertTrue(map.contains(asset.relPath), "map lacks \(asset.relPath)", file: file, line: line)
            let citation = try XCTUnwrap(request.citationMap.first { $0.sourceId == source.id })
            XCTAssertEqual(citation.folderId, folderId, file: file, line: line)
            XCTAssertEqual(citation.relPath, asset.relPath, file: file, line: line)
            XCTAssertEqual(citation.revisionId, revisionId, file: file, line: line)
            XCTAssertFalse(citation.spans.isEmpty, file: file, line: line)
            XCTAssertEqual(citation.chunkId, citation.chunkIds.first, file: file, line: line)
            let citationText = try XCTUnwrap(citation.text)
            XCTAssertFalse(citationText.isEmpty, file: file, line: line)
            let scalars = Array(asset.canonicalText.unicodeScalars)
            for span in citation.spans {
                XCTAssertGreaterThanOrEqual(span.start, 0, file: file, line: line)
                XCTAssertLessThanOrEqual(span.end, scalars.count, file: file, line: line)
                XCTAssertLessThan(span.start, span.end, file: file, line: line)
                guard span.start >= 0, span.end <= scalars.count, span.start < span.end else { continue }
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[span.start..<span.end])
                XCTAssertEqual(Array(citationText.utf8), Array(String(view).utf8), asset.relPath, file: file, line: line)
            }
            if let language = asset.language {
                // Labels come from the REAL bundled detector through extraction.
                // The model-visible passage label must equal the gold language.
                XCTAssertTrue(sections.contains { $0.kind == "evidence" && $0.text.contains(asset.relPath + " · " + language) },
                              "no evidence header for \(asset.relPath) · \(language)", file: file, line: line)
                // Document label (lang-detector-v1 §document mode): the gold
                // language iff its share reaches mixedDominanceBp, else `und`;
                // no other target language may receive any share.
                let coverage = try XCTUnwrap(source.langCoverage.flatMap {
                    try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }, file: file, line: line)
                let shares = try XCTUnwrap(coverage["sharesBp"] as? [String: Int], file: file, line: line)
                for (target, share) in shares where target != language {
                    XCTAssertEqual(share, 0, "\(asset.relPath) attributed to \(target)", file: file, line: line)
                }
                XCTAssertEqual(source.lang, (shares[language] ?? 0) >= 7000 ? language : "und", asset.relPath,
                               file: file, line: line)
                if let label = source.lang, label != "und" { documentLabels.insert(label) }
            }
        }
        XCTAssertEqual(documentLabels, Set(fixture.assets.compactMap(\.language)),
                       "every gold language must label at least one document", file: file, line: line)
        XCTAssertEqual(try source("cs/terminal.txt").encoding, "windows-1250", file: file, line: line)
        let bytes = try PreparedContextRequestJSON.encode(request)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(root.path), "absolute path leaked",
                       file: file, line: line)
        let pairs = request.sourceRevisions
        XCTAssertEqual(pairs.count, Set(pairs).count, file: file, line: line)
        XCTAssertEqual(pairs, pairs.sorted { ($0.sourceId, $0.revisionId) < ($1.sourceId, $1.revisionId) },
                       file: file, line: line)
        for citation in request.citationMap {
            XCTAssertTrue(pairs.contains(PackSourceRevision(sourceId: citation.sourceId, revisionId: citation.revisionId!)),
                          file: file, line: line)
        }
        let charged = request.messages.flatMap(\.sections).reduce(0) { $0 + $1.tokens }
        XCTAssertLessThanOrEqual(charged + (request.options.maxTokens ?? 0), fixture.runtimeContext, file: file, line: line)
        let pool = try await self.pool(query: fixture.question)
        do {
            XCTAssertEqual(pool.diagnostics.vectorStatus, "used", file: file, line: line)
            let sourceIds = try Set(fixture.assets.map { try XCTUnwrap(source($0.relPath).id) })
            XCTAssertEqual(Set(pool.vector.map(\.reference.sourceId)), sourceIds, file: file, line: line)
            await pool.close()
        } catch {
            await pool.close()
            throw error
        }
        XCTAssertEqual(try integer("SELECT count(*) FROM pragma_foreign_key_check"), 0, file: file, line: line)
    }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

import CryptoKit
import Foundation

public struct BenchmarkRevision: Equatable, Sendable {
    public let sourceId: Int64
    public let revisionId: Int64
    public let documentId: String
    public let contentHash: String
    public let text: String
    public let chunks: [ChunkReference]

    public init(sourceId: Int64, revisionId: Int64, documentId: String, contentHash: String, text: String,
                chunks: [ChunkReference]) {
        self.sourceId = sourceId
        self.revisionId = revisionId
        self.documentId = documentId
        self.contentHash = contentHash
        self.text = text
        self.chunks = chunks
    }
}

public struct BenchmarkCitationAudit: Equatable, Sendable {
    public let packed: [EvalSpan]
    public let snapshotsCorrect: Int
    public let snapshotsTotal: Int
    public let answerMarkersCorrect: Int
    public let answerMarkersTotal: Int
    public let answerGoldSupported: Int
    public let answerMarkersJudged: Int

    public init(packed: [EvalSpan], snapshotsCorrect: Int, snapshotsTotal: Int, answerMarkersCorrect: Int,
                answerMarkersTotal: Int, answerGoldSupported: Int, answerMarkersJudged: Int) {
        self.packed = packed
        self.snapshotsCorrect = snapshotsCorrect
        self.snapshotsTotal = snapshotsTotal
        self.answerMarkersCorrect = answerMarkersCorrect
        self.answerMarkersTotal = answerMarkersTotal
        self.answerGoldSupported = answerGoldSupported
        self.answerMarkersJudged = answerMarkersJudged
    }

    static let empty = BenchmarkCitationAudit(packed: [], snapshotsCorrect: 0, snapshotsTotal: 0, answerMarkersCorrect: 0,
                                              answerMarkersTotal: 0, answerGoldSupported: 0, answerMarkersJudged: 0)
}

/// One phase event (benchmark-v1 §8 `phase`): candidate-level phases carry no chunk count.
public struct BenchmarkPhaseEvent: Equatable, Sendable {
    public let phase: String
    public let profileId: String
    public let chunks: Int?

    public init(phase: String, profileId: String, chunks: Int?) {
        self.phase = phase
        self.profileId = profileId
        self.chunks = chunks
    }
}

/// A captured candidate: exact identity, frozen effective limit and its strict transport.
public struct BenchmarkCapture: Sendable {
    public let identity: GenerationIdentity
    public let effectiveLimit: Int
    public let transport: any StrictEmbeddingTransport
    public let counter: (any ExactTokenCounting)?

    public init(identity: GenerationIdentity, effectiveLimit: Int, transport: any StrictEmbeddingTransport,
                counter: (any ExactTokenCounting)? = nil) {
        self.identity = identity
        self.effectiveLimit = effectiveLimit
        self.transport = transport
        self.counter = counter
    }
}

/// Observable run counters (fixtures assert them; reports never contain them).
@MainActor public final class BenchmarkRunCounters {
    public var candidates = 0, performanceRows = 0, httpCalls = 0, embeddingCalls = 0, chatCalls = 0
    public var retrievalCalls = 0, neighbourCalls = 0, openedPins = 0, releasedPins = 0
    public var completedMeasuredQueries = 0, warmupQueriesPerRow = 0, measuredQueriesPerRow = 0
    public var writerAwaited = false, samplerAwaited = false, privateDatabasesRemoved = true
    public var leakedPins: Int { openedPins - releasedPins }
    public init() {}
}

/// Everything a run takes from the outside world. Live mode wires the captured Ollama
/// adapters; fixture mode wires deterministic fakes and never constructs a network client.
@MainActor public final class BenchmarkRunEnvironment {
    public let platform: String
    public let host: BenchmarkEnvironment
    public let capture: @MainActor (EmbeddingProfile) async throws -> BenchmarkCapture
    public let verify: @MainActor (EmbeddingProfile, BenchmarkCapture) async throws -> Void
    public let observeChat: @MainActor ([ChatTurn]) async throws -> ChatTokenObservation
    /// Raw-prompt body count observation (calibration only; `/api/generate` with raw:true).
    public let observeRaw: (@MainActor (String) async throws -> ChatTokenObservation)?
    public let nowUs: @MainActor () -> Int64
    public let startSampler: @MainActor () async -> ProcessMemorySampler?
    public let memoryMethod: String
    public let sampleIntervalMs: Int
    public let chatDigest: String?
    public let tokenFamily: String?
    public let showTemplateSha256: String?
    public let estimator: TokenEstimatorV2
    public let calibrationHash: String
    public let workDirectory: URL
    /// Fixture mode only: each concurrent measured query waits for one more writer completion.
    public let paceConcurrentQueries: Bool
    public var trace: (@MainActor (BenchmarkPhaseEvent) -> Void)?
    /// Called before every measured query with (phase, chunks, index); tests inject cancellation here.
    public var beforeMeasuredQuery: (@MainActor (String, Int, Int) -> Void)?
    public let counters = BenchmarkRunCounters()

    public init(platform: String, host: BenchmarkEnvironment,
                capture: @escaping @MainActor (EmbeddingProfile) async throws -> BenchmarkCapture,
                verify: @escaping @MainActor (EmbeddingProfile, BenchmarkCapture) async throws -> Void,
                observeChat: @escaping @MainActor ([ChatTurn]) async throws -> ChatTokenObservation,
                observeRaw: (@MainActor (String) async throws -> ChatTokenObservation)?,
                nowUs: @escaping @MainActor () -> Int64,
                startSampler: @escaping @MainActor () async -> ProcessMemorySampler?,
                memoryMethod: String, sampleIntervalMs: Int = BenchmarkTelemetry.sampleIntervalMs,
                chatDigest: String?, tokenFamily: String?, showTemplateSha256: String?, estimator: TokenEstimatorV2,
                calibrationHash: String, workDirectory: URL, paceConcurrentQueries: Bool = false) {
        self.platform = platform
        self.host = host
        self.capture = capture
        self.verify = verify
        self.observeChat = observeChat
        self.observeRaw = observeRaw
        self.nowUs = nowUs
        self.startSampler = startSampler
        self.memoryMethod = memoryMethod
        self.sampleIntervalMs = sampleIntervalMs
        self.chatDigest = chatDigest
        self.tokenFamily = tokenFamily
        self.showTemplateSha256 = showTemplateSha256
        self.estimator = estimator
        self.calibrationHash = calibrationHash
        self.workDirectory = workDirectory
        self.paceConcurrentQueries = paceConcurrentQueries
    }
}

/// Production retrieval/packing benchmark and chat-token calibration (benchmark-v1 §5, §6;
/// plan Task 8c). Each candidate runs in a private file-backed store that is always removed.
@MainActor public enum BenchmarkRunner {
    static let cacheBudgetBytes: Int64 = 536_870_912

    public static func run(options: BenchmarkOptions) async throws -> BenchmarkReportV1 {
        guard options.command == "benchmark" else { throw BenchmarkError(code: "invalidArguments") }
        let loaded = try EvalRunner.load(root: URL(fileURLWithPath: options.root))
        let env = options.mode == "fixture" ? fixtureEnvironment(options) : try await liveEnvironment(options)
        return try await run(options: options, corpus: loaded.corpus, corpusHash: loaded.hash, env: env)
    }

    public static func calibrate(options: BenchmarkOptions) async throws -> TokenCalibrationReportV1 {
        guard options.command == "calibrate" else { throw BenchmarkError(code: "invalidArguments") }
        let loaded = try EvalRunner.load(root: URL(fileURLWithPath: options.root))
        let env = options.mode == "fixture" ? fixtureEnvironment(options) : try await liveEnvironment(options)
        return try await calibrate(options: options, corpus: loaded.corpus, corpusHash: loaded.hash, env: env)
    }

    // MARK: - Calibration (§5)

    static func calibrate(options: BenchmarkOptions, corpus: EvalCorpus, corpusHash: String,
                          env: BenchmarkRunEnvironment) async throws -> TokenCalibrationReportV1 {
        guard let observeRaw = env.observeRaw else { throw BenchmarkError(code: "invalidArguments") }
        guard let digest = env.chatDigest else { throw EmbeddingProfileError(code: "embeddingModelUnavailable") }
        let family = "ollama:" + digest
        let documents = corpus.documents.map {
            CalibrationDocument(documentId: $0.metadata.documentId, language: $0.metadata.language, text: $0.text)
        }
        let queries = corpus.questions.map { q in
            CalibrationQuery(queryId: q.queryId, language: q.language, caseType: q.caseType, text: q.text,
                             goldDocumentIds: orderedUnique((corpus.gold[q.queryId] ?? []).map(\.documentId)))
        }
        let plan = TokenCalibration.samplePlan(documents: documents, queries: queries)
        var samples: [TokenCalibrationReportSample] = []
        for sample in plan {
            try Task.checkCancellation()
            let observed = try await observeRaw(sample.text)
            if let count = observed.promptTokens, count < 0 { throw EmbeddingProfileError(code: "invalidTokenCount") }
            samples.append(TokenCalibrationReportSample(
                id: sample.id, language: sample.language, split: sample.split, documentId: sample.documentId,
                start: sample.start, end: sample.end, scalars: sample.scalars, utf8Bytes: sample.utf8Bytes,
                tokens: observed.promptTokens))
        }
        let counted = samples.allSatisfy { $0.tokens != nil }
        let rates = counted ? try TokenCalibration.fit(samples.filter { $0.split == "train" }.map {
            TokenSample(id: $0.id, family: family, language: $0.language, split: "train", scalars: $0.scalars,
                        tokens: $0.tokens!)
        }) : []
        let estimator = try TokenEstimatorV2(family: rates.isEmpty ? "unverified" : family, rates: rates)
        let checks = try await promptChecks(options: options, corpus: corpus, plan: plan, estimator: estimator, env: env)
        let complete = counted && checks.allSatisfy { $0.actualTokens != nil }
        let summary = try TokenCalibrationReportV1.summarize(status: complete ? "complete" : "incomplete", family: family,
                                                              samples: samples, rates: rates, promptChecks: checks)
        let report = TokenCalibrationReportV1(
            status: complete ? "complete" : "incomplete", corpusHash: corpusHash, platform: env.platform,
            model: options.chatModel, modelDigest: digest, ollamaVersion: env.host.ollamaVersion,
            showTemplateSha256: env.showTemplateSha256 ?? String(repeating: "0", count: 64), family: family,
            method: OllamaBenchmarkClient.rawMethod, tokenizerId: nil, tokenizerRevision: nil, tokenizerAssetsSha256: nil,
            samples: samples, rates: rates, promptChecks: checks,
            bodyHoldoutUndercounts: complete ? summary.bodyHoldoutUndercounts : nil,
            promptHoldoutUndercounts: complete ? summary.promptHoldoutUndercounts : nil,
            maxOverestimateTokens: complete ? summary.maxOverestimateTokens : nil,
            calibrated: complete && summary.calibrated, errorCode: complete ? nil : "tokenCountUnavailable")
        try report.validate()
        return report
    }

    /// Complete rendered-prompt checks for planned query samples. Retrieval here is
    /// lexical-only (no candidate embedder takes part in chat calibration); the request is
    /// the real WP8 builder output and the wire messages are its production rendering.
    private static func promptChecks(options: BenchmarkOptions, corpus: EvalCorpus, plan: [CalibrationPlanSample],
                                     estimator: TokenEstimatorV2, env: BenchmarkRunEnvironment) async throws -> [TokenPromptCheck] {
        try FileManager.default.createDirectory(at: env.workDirectory, withIntermediateDirectories: true)
        let dbURL = env.workDirectory.appendingPathComponent("wp7-calibration-\(UUID().uuidString).sqlite")
        defer { removeDatabase(dbURL); removeEmptyWorkDirectory(env) }
        var splits: [String: String] = [:]
        for p in plan where p.kind == "query" { splits[String(p.documentId!.dropFirst("query:".count))] = p.split }
        let store = try NotebookStore(path: StorePath(fileURL: dbURL), configuredEmbeddingModelKey: nil)
        let world = try materialize(store: store, corpus: corpus)
        let retriever = Retriever(store: store, client: NoQueryEmbedding(), modelKey: { "calibration" })
        let hydrator = EvidenceHydrator(reader: store.makeRetrievalReader())
        var checks: [TokenPromptCheck] = []
        for q in corpus.questions.sorted(by: { TokenCalibration.scalarLess($0.queryId, $1.queryId) }) {
            guard let split = splits[q.queryId] else { continue }
            try Task.checkCancellation()
            guard let snapshot = try ScopeResolver.resolve(store: store, notebookId: world.notebooks[q.notebookId]!,
                                                           scope: try mapScope(q.scope, world), modelKey: "calibration")
            else { continue }
            let pool = try await retriever.searchEmbedded(snapshot: snapshot, query: q.text, queryVector: nil,
                                                          fetchK: options.fetchK)
            let request: PreparedContextRequest
            do {
                let fused = pool.fused.map(\.reference)
                let evidence = fused.isEmpty ? [] : try await hydrator.hydrate(snapshot, references: fused, neighborRadius: 1)
                let rrf = Dictionary(pool.fused.map { ($0.reference.chunkId, $0.rrfMicro) }, uniquingKeysWith: { a, _ in a })
                let input = packInput(options: options, question: q, mode: "answer", snapshot: snapshot, world: world,
                                      candidates: passages(evidence.filter { !$0.isNeighbour }, world, snapshot, rrf),
                                      neighbours: passages(evidence.filter(\.isNeighbour), world, snapshot, nil),
                                      overview: [])
                request = try ContextPackBuilder.build(input, estimator: estimator, tuning: try tuning(options))
                await pool.close()
            } catch { await pool.close(); throw error }
            let wire = wireMessages(request)
            let observed = try await env.observeChat(wire)
            if let count = observed.promptTokens, count < 0 { throw EmbeddingProfileError(code: "invalidTokenCount") }
            let estimated = request.messages.reduce(0) { $0 + 4 + $1.sections.reduce(0) { $0 + $1.tokens } }
            let wireObject: [[String: Any]] = wire.map { ["role": $0.role.rawValue, "content": $0.content] }
            let wireHash = sha256Hex(try PreparedContextRequestJSON.canonicalData(wireObject))
            checks.append(TokenPromptCheck(queryId: q.queryId, split: split, preparedHash: try preparedHash(request),
                                           wireMessagesHash: wireHash, actualTokens: observed.promptTokens,
                                           estimatedTokens: estimated))
        }
        return checks
    }

    // MARK: - Benchmark (§6)

    static func run(options: BenchmarkOptions, corpus: EvalCorpus, corpusHash: String,
                    env: BenchmarkRunEnvironment) async throws -> BenchmarkReportV1 {
        var candidates: [BenchmarkCandidate] = []
        defer { removeEmptyWorkDirectory(env) }
        for id in options.profileIds {
            try Task.checkCancellation()
            candidates.append(try await runCandidate(options: options, corpus: corpus,
                                                     profile: try EmbeddingProfiles.require(id), env: env))
        }
        func report(_ status: String) -> BenchmarkReportV1 {
            BenchmarkReportV1(status: status, mode: options.mode, platform: env.platform, environment: env.host,
                              corpus: BenchmarkCorpus(id: corpus.corpusId, hash: corpusHash, documents: corpus.documents.count,
                                                      queries: corpus.questions.count, chunkerVersion: "2"),
                              calibrationHash: env.calibrationHash,
                              parameters: BenchmarkParameters(fetchK: options.fetchK, topK: options.topK,
                                                              evidenceShareBp: options.evidenceShareBp,
                                                              runtimeContext: options.runtimeContext,
                                                              maxOutputTokens: options.maxOutput, seed: options.seed),
                              chat: BenchmarkChat(model: options.chatModel, modelDigest: env.chatDigest,
                                                  tokenFamily: env.tokenFamily, showTemplateSha256: env.showTemplateSha256),
                              candidates: candidates)
        }
        let complete = report("complete")
        do {
            try complete.validate()
            return complete
        } catch let error as BenchmarkError where error.code == "incompleteMeasurement" {
            let honest = report("incomplete")
            try honest.validate()
            return honest
        }
    }

    private static func runCandidate(options: BenchmarkOptions, corpus: EvalCorpus, profile: EmbeddingProfile,
                                     env: BenchmarkRunEnvironment) async throws -> BenchmarkCandidate {
        let counters = env.counters
        counters.candidates += 1
        func trace(_ phase: String, _ chunks: Int? = nil) {
            env.trace?(BenchmarkPhaseEvent(phase: phase, profileId: profile.id, chunks: chunks))
        }
        try FileManager.default.createDirectory(at: env.workDirectory, withIntermediateDirectories: true)
        let dbURL = env.workDirectory.appendingPathComponent("wp7-\(profile.id)-\(UUID().uuidString).sqlite")
        defer {
            removeDatabase(dbURL)
            counters.privateDatabasesRemoved = counters.privateDatabasesRemoved
                && !FileManager.default.fileExists(atPath: dbURL.path)
        }
        trace("inspect")
        let capture: BenchmarkCapture
        do { capture = try await env.capture(profile) }
        catch let error as EmbeddingProfileError { return failed(profile, error.code, nil, options) }
        let identity = capture.identity
        do {
            return try await measureCandidate(options: options, corpus: corpus, profile: profile, capture: capture,
                                              dbURL: dbURL, env: env, trace: trace)
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            guard let code = failureCode(error) else { throw error }
            return failed(profile, code, identity, options)
        }
    }

    private static func measureCandidate(options: BenchmarkOptions, corpus: EvalCorpus, profile: EmbeddingProfile,
                                         capture: BenchmarkCapture, dbURL: URL, env: BenchmarkRunEnvironment,
                                         trace: (String, Int?) -> Void) async throws -> BenchmarkCandidate {
        let identity = capture.identity
        let store = try NotebookStore(path: StorePath(fileURL: dbURL), configuredEmbeddingModelKey: nil)
        let world = try materialize(store: store, corpus: corpus)
        let telemetry = BenchmarkEmbeddingTelemetry()
        let session = ProviderEmbeddingSession(
            storageKey: identity.providerId + ":" + identity.model, endpointRevision: identity.endpointRevision,
            identity: identity, profile: profile,
            pipeline: StrictEmbeddingPipeline(transport: capture.transport, counter: capture.counter, observer: telemetry),
            effectiveLimit: capture.effectiveLimit)
        trace("ingest", nil)
        let ingest = try await ingest(store: store, world: world, identity: identity, session: session,
                                      telemetry: telemetry, env: env)
        trace("quality", nil)
        var rows: [BenchmarkQualityQuery] = []
        var c = [0, 0, 0, 0, 0, 0]
        for q in corpus.questions.sorted(by: { TokenCalibration.scalarLess($0.queryId, $1.queryId) }) {
            try Task.checkCancellation()
            let (row, audit) = try await qualityRow(options: options, corpus: corpus, world: world, store: store,
                                                    session: session, question: q, env: env)
            rows.append(row)
            c[0] += audit.snapshotsCorrect; c[1] += audit.snapshotsTotal; c[2] += audit.answerMarkersCorrect
            c[3] += audit.answerMarkersTotal; c[4] += audit.answerGoldSupported; c[5] += audit.answerMarkersJudged
        }
        var performance: [BenchmarkPerformanceRow] = []
        for chunks in options.chunkCounts {
            performance += try await performanceRows(options: options, store: store, session: session, profile: profile,
                                                     chunks: chunks, env: env)
        }
        trace("verifyModels", nil)
        var error: String?
        do { try await env.verify(profile, capture) }
        catch let changed as EmbeddingProfileError { error = changed.code }
        trace("report", nil)
        return BenchmarkCandidate(
            profileId: profile.id, identity: BenchmarkIdentity(identity), status: error == nil ? "complete" : "failed",
            errorCode: error, quality: BenchmarkQuality(queries: rows),
            citations: BenchmarkCitations(snapshotsCorrect: c[0], snapshotsTotal: c[1], answerMarkersCorrect: c[2],
                                          answerMarkersTotal: c[3], answerGoldSupported: c[4], answerMarkersJudged: c[5]),
            ingest: ingest, performance: performance)
    }

    private static func failureCode(_ error: any Error) -> String? {
        switch error {
        case let e as EmbeddingProfileError: return e.code
        case let e as EmbeddingGenerationError: return e.code
        case let e as RetrievalError: return e.rawValue
        case let e as ContextPackError: return e.rawValue
        case let e as StorageV19Error: return e.code
        case is ProviderError, is OllamaError: return "providerError"
        default: return nil
        }
    }

    private static func failed(_ profile: EmbeddingProfile, _ code: String, _ identity: GenerationIdentity?,
                               _ options: BenchmarkOptions) -> BenchmarkCandidate {
        let root = (try? ProviderAPIRoot.normalize(options.host)) ?? BenchmarkOptions.defaultHost
        let fallback = GenerationIdentity(
            providerId: ProviderConfig.ollamaId, endpointRevision: EmbeddingEndpointRevision.make(type: .ollama, normalizedRoot: root),
            model: profile.model, modelDigest: nil, dims: profile.dims, normalization: "l2",
            queryFormatVersion: profile.formatVersion(.query), docFormatVersion: profile.formatVersion(.document),
            chunkerVersion: "2")
        return BenchmarkCandidate(
            profileId: profile.id, identity: BenchmarkIdentity(identity ?? fallback), status: "failed", errorCode: code,
            quality: BenchmarkQuality(queries: []),
            citations: BenchmarkCitations(snapshotsCorrect: 0, snapshotsTotal: 0, answerMarkersCorrect: 0,
                                          answerMarkersTotal: 0, answerGoldSupported: 0, answerMarkersJudged: 0),
            ingest: BenchmarkIngest(serviceTokens: nil, successfulTokens: nil, rejectedRequests: nil, splitParts: nil,
                                    elapsedUs: nil, tokensPerSecondMilli: nil, runnerPeakRssBytes: nil,
                                    serverPeakRssBytes: nil, combinedPeakRssBytes: nil, serviceTokenStatus: "not_available",
                                    uncountedRequests: 0, memoryMethod: BenchmarkTelemetry.memoryMethod,
                                    sampleIntervalMs: BenchmarkTelemetry.sampleIntervalMs),
            performance: [])
    }

    // MARK: - Corpus materialization

    final class World {
        var notebooks: [Int64: Int64] = [:]
        var folders: [Int64: Int64] = [:]
        var sources: [Int64: Int64] = [:]
        var documentBySource: [Int64: LoadedEvalDocument] = [:]
        var revisions: [PackSourceRevision: BenchmarkRevision] = [:]
        var chunks: [Int64: (revision: BenchmarkRevision, start: Int, end: Int)] = [:]
    }

    private struct EvalFolderIdentity: FolderPathIdentity {
        let folderId: Int64
        func resolve(rootPath: String) throws -> FolderIdentity {
            FolderIdentity(volumeId: "eval", components: ["folder", String(folderId)], rootFileId: "eval-folder-\(folderId)")
        }
    }

    static func materialize(store: NotebookStore, corpus: EvalCorpus) throws -> World {
        let world = World()
        let notebookIds = Set(corpus.documents.map(\.metadata.notebookId) + corpus.questions.map(\.notebookId)).sorted()
        for id in notebookIds { world.notebooks[id] = try store.createNotebook(name: "eval-\(id)").id! }
        let folders = Set(corpus.documents.compactMap { d in d.metadata.folderId.map { FolderKey(notebook: d.metadata.notebookId, folder: $0) } })
            .sorted { ($0.notebook, $0.folder) < ($1.notebook, $1.folder) }
        for key in folders {
            let name = "folder-\(key.folder)"
            world.folders[key.folder] = try store.createFolder(
                notebookId: world.notebooks[key.notebook]!,
                draft: FolderDraft(rootPath: "eval://" + name, displayName: name, includeExts: [], ignoreGlobs: [],
                                   limitsJSON: "{}", encodingFallback: "none", watchEnabled: false),
                identity: EvalFolderIdentity(folderId: key.folder), now: 0).id
        }
        for loaded in corpus.documents.sorted(by: { TokenCalibration.scalarLess($0.metadata.documentId, $1.metadata.documentId) }) {
            try Task.checkCancellation()
            let d = loaded.metadata
            let source = try store.createSource(notebookId: world.notebooks[d.notebookId]!,
                                                type: d.path.hasSuffix(".txt") ? .text : .markdown,
                                                title: displayName(d), uri: nil, rawPath: nil)
            let sourceId = source.id!
            world.sources[d.sourceId] = sourceId
            world.documentBySource[sourceId] = loaded
            if let folder = d.folderId { try store.attachSource(sourceId: sourceId, folderId: world.folders[folder]!, relPath: d.relPath) }
            // Controlled corpus: chunk language comes from its label (a mixed document stays unlabelled).
            let language: String? = ["cs", "sk", "en", "de"].contains(d.language) ? d.language : nil
            let drafts = ScalarChunker.chunk(loaded.text).map {
                RevisionChunkDraft(text: $0.text, tokenCount: $0.tokenCount, pageHint: $0.pageHint, charStart: $0.charStart,
                                   charEnd: $0.charEnd, lang: language, langInherited: language != nil)
            }
            let revision = try store.commitForegroundRevision(
                sourceId: sourceId, draft: RevisionDraft(contentHash: d.contentHash, canonicalText: loaded.text,
                                                         textFormatVersion: 1, chunkerVersion: 2),
                chunks: drafts, now: 0, leaseToken: "wp7-benchmark")
            let stored = try store.chunks(sourceId: sourceId)
            let benchmark = BenchmarkRevision(sourceId: sourceId, revisionId: revision.id, documentId: d.documentId,
                                              contentHash: d.contentHash, text: loaded.text,
                                              chunks: stored.map { ChunkReference(chunkId: $0.id!, sourceId: sourceId,
                                                                                  revisionId: revision.id, ord: $0.ord) })
            world.revisions[PackSourceRevision(sourceId: sourceId, revisionId: revision.id)] = benchmark
            for c in stored {
                world.chunks[c.id!] = (benchmark, c.charStart ?? 0, c.charEnd ?? c.text.unicodeScalars.count)
            }
        }
        return world
    }

    private struct FolderKey: Hashable { let notebook: Int64; let folder: Int64 }

    private static func displayName(_ d: EvalDocument) -> String {
        let name = d.relPath.split(separator: "/").last.map(String.init) ?? d.relPath
        return name.isEmpty ? d.documentId : name
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func mapScope(_ scope: RetrievalScope, _ world: World) throws -> RetrievalScope {
        switch scope {
        case .all: return .all
        case let .selection(sources, folders):
            return .selection(sourceIds: Set(try sources.map { try world.sources[$0] ?? { throw EvalFailure("source_mapping") }() }),
                              folderIds: Set(try folders.map { try world.folders[$0] ?? { throw EvalFailure("source_mapping") }() }))
        }
    }

    /// Maps a reference through its own revision, never the source's current revision.
    static func span(for reference: ChunkReference, start: Int, end: Int,
                     revisions: [PackSourceRevision: BenchmarkRevision]) throws -> EvalSpan {
        guard let revision = revisions[PackSourceRevision(sourceId: reference.sourceId, revisionId: reference.revisionId)] else {
            throw EvalFailure("evidence_mapping")
        }
        return EvalSpan(documentId: revision.documentId, contentHash: revision.contentHash, start: start, end: end)
    }

    private static func span(_ reference: ChunkReference, _ world: World) throws -> EvalSpan {
        guard let chunk = world.chunks[reference.chunkId], chunk.revision.revisionId == reference.revisionId else {
            throw EvalFailure("evidence_mapping")
        }
        return try span(for: reference, start: chunk.start, end: chunk.end, revisions: world.revisions)
    }

    // MARK: - Ingestion

    private static func ingest(store: NotebookStore, world: World, identity: GenerationIdentity,
                               session: ProviderEmbeddingSession, telemetry: BenchmarkEmbeddingTelemetry,
                               env: BenchmarkRunEnvironment) async throws -> BenchmarkIngest {
        let sampler = await env.startSampler()
        let start = env.nowUs()
        var samples: [ProcessMemorySample]?
        do {
            for notebookId in world.notebooks.values.sorted() {
                try Task.checkCancellation()
                let generation = try await EmbeddingGenerationBuilder.stage(store: store, notebookId: notebookId,
                                                                            identity: identity, session: session, now: { 1 })
                // Explicit activation only after a complete stage.
                try store.activateGeneration(id: generation.id, now: 2)
            }
        } catch {
            if let sampler { _ = await sampler.stop(); env.counters.samplerAwaited = true }
            throw error
        }
        if let sampler { samples = await sampler.stop(); env.counters.samplerAwaited = true }
        let elapsed = max(0, env.nowUs() - start)
        let snapshot = try await telemetry.snapshot(purpose: .document)
        let peaks = try samples.flatMap { $0.isEmpty ? nil : try BenchmarkTelemetry.peaks($0) }
        return BenchmarkIngest(serviceTokens: snapshot.serviceTokens, successfulTokens: snapshot.successfulTokens,
                               rejectedRequests: snapshot.rejectedRequests, splitParts: snapshot.splitParts,
                               elapsedUs: elapsed,
                               tokensPerSecondMilli: try BenchmarkMath.tokensPerSecondMilli(tokens: snapshot.successfulTokens,
                                                                                           elapsedUs: elapsed),
                               runnerPeakRssBytes: peaks?.runnerBytes, serverPeakRssBytes: peaks?.serverBytes,
                               combinedPeakRssBytes: peaks?.combinedBytes, serviceTokenStatus: snapshot.serviceTokenStatus,
                               uncountedRequests: snapshot.uncountedRequests, memoryMethod: env.memoryMethod,
                               sampleIntervalMs: env.sampleIntervalMs)
    }

    // MARK: - Quality

    private static let notApplicable = Dictionary(uniqueKeysWithValues: EvalMetrics.names.map { ($0, EvalMetric.notApplicable) })

    static func qualityRow(options: BenchmarkOptions, corpus: EvalCorpus, world: World, store: NotebookStore,
                           session: ProviderEmbeddingSession, question q: EvalQuestion,
                           env: BenchmarkRunEnvironment) async throws -> (BenchmarkQualityQuery, BenchmarkCitationAudit) {
        let counters = env.counters
        let selected = corpus.selectedDocuments(for: q)
        let filesInScope = selected.count, withChunks = selected.filter { !$0.text.isEmpty }.count
        let scope = try mapScope(q.scope, world)
        let gold = corpus.gold[q.queryId] ?? []
        if scope.isEmptySelection || q.caseType == "empty_selection" {
            // No retrieval, embedding or chat call; zero evidence creates no citation.
            let row = EvalQueryRow(queryId: q.queryId, text: q.text, language: q.language, caseType: q.caseType,
                                   status: "measured", filesInScope: 0, candidatesWithChunks: 0, lexical: [], vector: [],
                                   fused: [], metrics: notApplicable)
            return (BenchmarkQualityQuery(eval: row, packed: [], citationMap: [], answerText: nil, preparedHash: nil,
                                          timing: nil, overview: nil), .empty)
        }
        let notebookId = world.notebooks[q.notebookId]!
        guard let snapshot = try ScopeResolver.resolve(store: store, notebookId: notebookId, scope: scope,
                                                       modelKey: session.storageKey) else {
            throw EvalFailure("source_mapping")
        }
        counters.openedPins += 1
        defer { counters.releasedPins += 1 }
        let hydrator = EvidenceHydrator(reader: store.makeRetrievalReader())
        if q.caseType == "overview" {
            do {
                // Overview bypasses retrieval and embedding: first published chunk per scoped source, no neighbours.
                let firsts = snapshot.sources.compactMap { s -> ChunkReference? in
                    guard let published = s.publishedRevisionId else { return nil }
                    return world.revisions[PackSourceRevision(sourceId: s.sourceId, revisionId: published)]?
                        .chunks.min { ($0.ord, $0.chunkId) < ($1.ord, $1.chunkId) }
                }
                let evidence = firsts.isEmpty ? [] : try await hydrator.hydrate(snapshot, references: firsts, neighborRadius: 0)
                let input = packInput(options: options, question: q, mode: "overview", snapshot: snapshot, world: world,
                                      candidates: [], neighbours: [], overview: passages(evidence, world, snapshot, nil))
                let request = try ContextPackBuilder.build(input, estimator: env.estimator, tuning: try tuning(options))
                let answer = try await chat(request, env)
                let audit = try audit(citations: request.citationMap, answer: answer, revisions: Array(world.revisions.values),
                                      gold: gold)
                let row = EvalQueryRow(queryId: q.queryId, text: q.text, language: q.language, caseType: q.caseType,
                                       status: "measured", filesInScope: filesInScope, candidatesWithChunks: withChunks,
                                       lexical: [], vector: [], fused: [], metrics: notApplicable)
                await snapshot.close()
                return (BenchmarkQualityQuery(eval: row, packed: audit.packed, citationMap: request.citationMap,
                                              answerText: answer, preparedHash: try preparedHash(request), timing: nil,
                                              overview: BenchmarkOverview(filesInScope: snapshot.filesInScope,
                                                                          publishedCandidateFiles: firsts.count,
                                                                          filesIncluded: request.coverage.turn.filesIncluded)),
                        audit)
            } catch { await snapshot.close(); throw error }
        }
        let t0 = env.nowUs()
        let vector: [Float]
        do { vector = try await session.embed(inputs: [q.text])[0] } catch { await snapshot.close(); throw error }
        counters.embeddingCalls += 1
        let t1 = env.nowUs()
        let retriever = Retriever(store: store, client: NoQueryEmbedding(), modelKey: { [key = session.storageKey] in key })
        // Ownership of the snapshot transfers to the pool (closed on failure inside).
        let pool = try await retriever.searchEmbedded(snapshot: snapshot, query: q.text, queryVector: vector,
                                                      fetchK: options.fetchK)
        do {
            counters.retrievalCalls += 1
            let t2 = env.nowUs()
            let fused = pool.fused.map(\.reference)
            let evidence = fused.isEmpty ? [] : try await hydrator.hydrate(snapshot, references: fused, neighborRadius: 1)
            if !fused.isEmpty { counters.neighbourCalls += 1 }
            let t3 = env.nowUs()
            let rrf = Dictionary(pool.fused.map { ($0.reference.chunkId, $0.rrfMicro) }, uniquingKeysWith: { a, _ in a })
            let input = packInput(options: options, question: q, mode: "answer", snapshot: snapshot, world: world,
                                  candidates: passages(evidence.filter { !$0.isNeighbour }, world, snapshot, rrf),
                                  neighbours: passages(evidence.filter(\.isNeighbour), world, snapshot, nil), overview: [])
            let prepared = try ContextPackBuilder.build(input, estimator: env.estimator, tuning: try tuning(options))
            let text = try await chat(prepared, env)
            let t4 = env.nowUs()
            let result = try audit(citations: prepared.citationMap, answer: text, revisions: Array(world.revisions.values),
                                   gold: gold)
            let lexical = try pool.lexical.map { try span($0.reference, world) }
            let vectorSpans = try pool.vector.map { try span($0.reference, world) }
            let fusedSpans = try fused.map { try span($0, world) }
            let metrics = try EvalMetrics.measure(gold: gold, lexical: lexical, fused: fusedSpans, topK: options.topK,
                                                  includeVectors: true, packed: result.packed)
            let row = EvalQueryRow(queryId: q.queryId, text: q.text, language: q.language, caseType: q.caseType,
                                   status: "measured", filesInScope: filesInScope, candidatesWithChunks: withChunks,
                                   lexical: lexical, vector: vectorSpans, fused: fusedSpans, metrics: metrics)
            let timing = BenchmarkQueryTiming(embeddingUs: t1 - t0, retrievalUs: t2 - t1, hydrationUs: t3 - t2,
                                              endToEndUs: max(t4 - t0, (t1 - t0) + (t2 - t1) + (t3 - t2)))
            await pool.close()
            return (BenchmarkQualityQuery(eval: row, packed: result.packed, citationMap: prepared.citationMap,
                                          answerText: text, preparedHash: try preparedHash(prepared), timing: timing,
                                          overview: nil), result)
        } catch { await pool.close(); throw error }
    }

    private static func tuning(_ o: BenchmarkOptions) throws -> RagRuntimeTuning {
        try RagRuntimeTuning(fetchK: o.fetchK, topK: o.topK, evidenceShareBp: o.evidenceShareBp)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func preparedHash(_ request: PreparedContextRequest) throws -> String {
        sha256Hex(try PreparedContextRequestJSON.encode(request))
    }

    /// Production section transport: each message's ordered section texts joined with a blank line.
    static func wireMessages(_ request: PreparedContextRequest) -> [ChatTurn] {
        request.messages.map { m in
            ChatTurn(role: m.role == "system" ? .system : (m.role == "assistant" ? .assistant : .user),
                     content: m.sections.map(\.text).joined(separator: "\n\n"))
        }
    }

    private static func chat(_ request: PreparedContextRequest, _ env: BenchmarkRunEnvironment) async throws -> String {
        let observed = try await env.observeChat(wireMessages(request))
        env.counters.chatCalls += 1
        return observed.text
    }

    private static func language(_ value: String) -> String {
        ["cs", "de", "en", "sk", "und", "mixed"].contains(value) ? value : "und"
    }

    private static func passages(_ evidence: [EvidencePassage], _ world: World, _ snapshot: ResolvedRetrievalScope,
                                 _ rrf: [Int64: Int64]?) -> [PackPassage] {
        let scoped = Dictionary(snapshot.sources.map { ($0.sourceId, $0) }, uniquingKeysWith: { a, _ in a })
        return evidence.compactMap { e in
            guard e.spans.count == 1, let source = scoped[e.reference.sourceId],
                  let d = world.documentBySource[e.reference.sourceId]?.metadata else { return nil }
            let s = e.spans[0]
            return PackPassage(chunkId: e.reference.chunkId, sourceId: e.reference.sourceId, revisionId: e.reference.revisionId,
                               folderId: source.folderId, relPath: d.relPath, displayName: displayName(d),
                               language: language(d.language), text: e.text, ordinal: e.reference.ord, start: s.start,
                               end: s.end, pageFrom: s.pageFrom, pageTo: s.pageTo,
                               rrfMicro: rrf?[e.reference.chunkId] ?? 0, truncationCandidates: [])
        }
    }

    private static func packInput(options: BenchmarkOptions, question q: EvalQuestion, mode: String,
                                  snapshot: ResolvedRetrievalScope, world: World, candidates: [PackPassage],
                                  neighbours: [PackPassage], overview: [PackPassage]) -> ContextPackInput {
        let sources = snapshot.sources
        let files = sources.map { s -> PackFile in
            let d = world.documentBySource[s.sourceId]!.metadata
            return PackFile(sourceId: s.sourceId, folderId: s.folderId, relPath: d.relPath, displayName: displayName(d),
                            descriptor: displayName(d), metadataMatch: false, publishedRevisionId: s.publishedRevisionId)
        }
        var revisions: [String: Int64] = [:]
        for s in sources { if let p = s.publishedRevisionId { revisions[String(s.sourceId)] = p } }
        let languages = Set(sources.map { language(world.documentBySource[$0.sourceId]!.metadata.language) })
            .sorted(by: TokenCalibration.scalarLess)
        let scope: PackScopeSnapshot
        switch snapshot.scope {
        case let .selection(s, f):
            scope = PackScopeSnapshot(kind: "selection", name: "Selection", sourceIds: s.sorted(), folderIds: f.sorted(),
                                      languages: languages, lastFullScan: nil, scanState: "idle")
        case .all:
            scope = PackScopeSnapshot(kind: "all", name: "Notebook", sourceIds: [], folderIds: [], languages: languages,
                                      lastFullScan: nil, scanState: "idle")
        }
        return ContextPackInput(
            question: q.text, mode: mode, userInstructions: "", history: [], external: [], candidates: candidates,
            neighbours: neighbours, overviewCandidates: overview, folderMap: files, scope: scope,
            coverage: PackCorpusCoverage(filesInScope: sources.count, searchable: sources.count, pending: 0, error: 0,
                                         skipped: 0, missing: 0, unavailable: 0, refreshPending: 0, refreshError: 0,
                                         partial: false),
            model: PackModel(providerId: ProviderConfig.ollamaId, model: options.chatModel,
                             runtimeContext: options.runtimeContext, maxOutputTokens: options.maxOutput,
                             contextWindowKnown: false, providerType: "ollama"),
            generationId: snapshot.generation?.id, sourceRevisions: revisions, evidenceBudgetCap: nil,
            fetchK: options.fetchK, topK: options.topK)
    }

    private struct NoQueryEmbedding: EmbeddingProducing {
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            throw BenchmarkError(code: "embeddingSessionRequired") // queries embed through the captured session
        }
    }

    // MARK: - Citation audit (§8 `audit`)

    /// A snapshot is correct only with matching source/revision, one span, exact scalar text,
    /// content hash, ordered chunk membership, first chunk, 240-scalar snippet and a unique
    /// marker. Invalid entries stay in the total and are excluded from `packed`.
    public static func audit(citations: [Citation], answer: String, revisions: [BenchmarkRevision],
                             gold: [EvalSpan]) throws -> BenchmarkCitationAudit {
        var markerCounts: [Int: Int] = [:]
        for c in citations { markerCounts[c.marker, default: 0] += 1 }
        var packed: [EvalSpan] = []
        var validMarkers: [Int: EvalSpan] = [:]
        for citation in citations where markerCounts[citation.marker] == 1 {
            guard let revisionId = citation.revisionId,
                  let revision = revisions.first(where: { $0.sourceId == citation.sourceId && $0.revisionId == revisionId }),
                  citation.spans.count == 1, let span = citation.spans.first, let text = citation.text else { continue }
            let scalars = Array(revision.text.unicodeScalars)
            guard span.start >= 0, span.end > span.start, span.end <= scalars.count else { continue }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[span.start..<span.end])
            guard String(view).utf8.elementsEqual(text.utf8),
                  EvalCorpus.sha256(Data(revision.text.utf8)) == revision.contentHash else { continue }
            let references = revision.chunks.filter { citation.chunkIds.contains($0.chunkId) }
                .sorted { ($0.ord, $0.chunkId) < ($1.ord, $1.chunkId) }
            guard !citation.chunkIds.isEmpty, Set(citation.chunkIds).count == citation.chunkIds.count,
                  references.map(\.chunkId) == citation.chunkIds, citation.chunkId == citation.chunkIds.first,
                  references.allSatisfy({ $0.sourceId == citation.sourceId && $0.revisionId == revisionId }),
                  citation.snippet.unicodeScalars.elementsEqual(text.unicodeScalars.prefix(240)) else { continue }
            let retained = EvalSpan(documentId: revision.documentId, contentHash: revision.contentHash,
                                    start: span.start, end: span.end)
            packed.append(retained)
            validMarkers[citation.marker] = retained
        }
        let markers = CitationParser.markers(in: answer)
        var correct = 0, supported = 0
        for marker in markers {
            guard let retained = validMarkers[marker] else { continue }
            correct += 1
            if !gold.isEmpty, (EvalMetrics.recall(gold: gold, evidence: [retained]).found ?? 0) > 0 { supported += 1 }
        }
        return BenchmarkCitationAudit(packed: packed, snapshotsCorrect: packed.count, snapshotsTotal: citations.count,
                                      answerMarkersCorrect: correct, answerMarkersTotal: markers.count,
                                      answerGoldSupported: supported, answerMarkersJudged: gold.isEmpty ? 0 : markers.count)
    }

    // MARK: - Performance

    private static func performanceRows(options: BenchmarkOptions, store: NotebookStore, session: ProviderEmbeddingSession,
                                        profile: EmbeddingProfile, chunks: Int,
                                        env: BenchmarkRunEnvironment) async throws -> [BenchmarkPerformanceRow] {
        var rows: [BenchmarkPerformanceRow] = []
        let handle = try SyntheticRetrievalCorpus.populate(store: store, chunkCount: chunks, dims: profile.dims,
                                                           seed: options.seed)
        let warmCache = VectorMatrixCache(budgetBytes: cacheBudgetBytes)
        let retriever = Retriever(store: store, client: NoQueryEmbedding(), modelKey: { "synthetic" }, cache: warmCache)
        let hydrator = EvidenceHydrator(reader: store.makeRetrievalReader())
        let writerNotebook = try store.createNotebook(name: "wp7-concurrent-writer-\(chunks)").id!
        var writes = 0
        if options.concurrent == "both" || options.concurrent == "off" { rows.append(try await row(false)) }
        if options.concurrent == "both" || options.concurrent == "on" { rows.append(try await row(true)) }
        env.counters.performanceRows += rows.count
        return rows

        func row(_ concurrent: Bool) async throws -> BenchmarkPerformanceRow {
            let phase = concurrent ? "concurrent" : "measure"
            if concurrent { env.trace?(BenchmarkPhaseEvent(phase: "concurrent", profileId: profile.id, chunks: chunks)) }
            var cold: (us: Int64?, mode: String)?
            var calls = 0, measured = 0, completedWrites = 0
            var peakPage: Int64 = 0
            env.counters.warmupQueriesPerRow = options.warmup
            env.counters.measuredQueriesPerRow = options.queries
            env.counters.completedMeasuredQueries = 0
            defer { if concurrent { env.counters.writerAwaited = true } }
            let result = try await BenchmarkMeasurements.run(
                queries: options.queries, warmup: options.warmup, concurrent: concurrent, nowUs: env.nowUs,
                coldLoad: {
                    if !concurrent { env.trace?(BenchmarkPhaseEvent(phase: "cold", profileId: profile.id, chunks: chunks)) }
                    let measured = try await coldLoad(store: store, handle: handle, env: env)
                    cold = measured
                    return measured.us
                },
                runQuery: { i in
                    let warm = calls < options.warmup
                    calls += 1
                    if !concurrent && warm && calls == 1 {
                        env.trace?(BenchmarkPhaseEvent(phase: "warmup", profileId: profile.id, chunks: chunks))
                    }
                    if !concurrent && !warm && measured == 0 {
                        env.trace?(BenchmarkPhaseEvent(phase: "measure", profileId: profile.id, chunks: chunks))
                    }
                    if !warm {
                        env.beforeMeasuredQuery?(phase, chunks, measured)
                        try Task.checkCancellation()
                        if concurrent && env.paceConcurrentQueries {
                            let before = completedWrites
                            while completedWrites == before { try Task.checkCancellation(); await Task.yield() }
                        }
                    }
                    let sample = try await syntheticQuery(store: store, handle: handle, retriever: retriever,
                                                          hydrator: hydrator, session: session, index: i,
                                                          options: options, env: env) { peakPage = max(peakPage, $0) }
                    if !warm { measured += 1; env.counters.completedMeasuredQueries = measured }
                    return sample
                },
                writeBatch: { batch in
                    try Task.checkCancellation()
                    // Real publication in another notebook of the same database (SQL/cache contention only).
                    writes += 1
                    let source = try store.createSource(notebookId: writerNotebook, type: .text, title: "writer-\(writes).txt",
                                                        uri: nil, rawPath: nil)
                    let text = "concurrent writer batch \(batch)"
                    _ = try store.commitForegroundRevision(
                        sourceId: source.id!, draft: RevisionDraft(contentHash: EvalCorpus.sha256(Data(text.utf8)),
                                                                   canonicalText: text, textFormatVersion: 1, chunkerVersion: 2),
                        chunks: ScalarChunker.chunk(text), now: 3, leaseToken: "wp7-writer")
                    completedWrites += 1
                })
            guard let cold else { throw BenchmarkError(code: "invalidSamples") }
            let statistics = await warmCache.statistics()
            return try BenchmarkPerformanceRow(chunks: chunks, concurrent: concurrent, warmupQueries: options.warmup,
                                               coldCacheLoadUs: cold.us, cacheMode: cold.mode,
                                               residentBytes: cold.mode == "cached" ? statistics.residentBytes : 0,
                                               peakPageBytes: peakPage, completedWrites: result.completedWrites,
                                               overlapUs: result.overlapUs, samples: result.samples)
        }
    }

    /// A fresh application cache; the timed region is the first pinned search that admits and
    /// fills it (no OS cache flush, no query embedding). A refused admission is `streamed`.
    private static func coldLoad(store: NotebookStore, handle: SyntheticRetrievalHandle,
                                 env: BenchmarkRunEnvironment) async throws -> (us: Int64?, mode: String) {
        let admission = BenchmarkMeasurements.cacheAdmission(chunks: handle.chunkCount, dims: handle.dims,
                                                             budgetBytes: cacheBudgetBytes)
        guard admission.cacheMode == "cached" else { return (nil, "streamed") }
        let cache = VectorMatrixCache(budgetBytes: cacheBudgetBytes)
        let retriever = Retriever(store: store, client: NoQueryEmbedding(), modelKey: { "synthetic" }, cache: cache)
        guard let snapshot = try ScopeResolver.resolve(store: store, notebookId: handle.notebookId, scope: .all,
                                                       modelKey: "synthetic") else { throw EvalFailure("source_mapping") }
        env.counters.openedPins += 1
        defer { env.counters.releasedPins += 1 }
        let start = env.nowUs()
        let pool = try await retriever.searchEmbedded(snapshot: snapshot, query: "needle0",
                                                      queryVector: SyntheticRetrievalCorpus.row(index: 0, dims: handle.dims).vector,
                                                      fetchK: 1)
        await pool.close()
        let elapsed = env.nowUs() - start
        guard elapsed >= 0 else { throw BenchmarkError(code: "invalidSamples") }
        return (elapsed, "cached")
    }

    private static func syntheticQuery(store: NotebookStore, handle: SyntheticRetrievalHandle, retriever: Retriever,
                                       hydrator: EvidenceHydrator, session: ProviderEmbeddingSession, index: Int,
                                       options: BenchmarkOptions, env: BenchmarkRunEnvironment,
                                       peakPage: (Int64) -> Void) async throws -> BenchmarkTimingSample {
        try Task.checkCancellation()
        let query = "needle\(index % 97)"
        guard let snapshot = try ScopeResolver.resolve(store: store, notebookId: handle.notebookId, scope: .all,
                                                       modelKey: "synthetic") else { throw EvalFailure("source_mapping") }
        env.counters.openedPins += 1
        defer { env.counters.releasedPins += 1 }
        let sample = try await RetrievalPerformance.measure(
            snapshot: snapshot,
            embedding: { try await session.embed(inputs: [query])[0] },
            retrieval: { vector in
                try await retriever.searchEmbedded(snapshot: snapshot, query: query, queryVector: vector, fetchK: options.fetchK)
            },
            hydration: { pool in
                peakPage(pool.diagnostics.peakPageBytes)
                let top = pool.fused.prefix(options.topK).map(\.reference)
                if !top.isEmpty { _ = try await hydrator.hydrate(snapshot, references: Array(top), neighborRadius: 1) }
            },
            ticksPerSecond: 1_000_000, now: { UInt64(max(0, env.nowUs())) })
        let e = BenchmarkMath.microseconds(fromMilliseconds: sample.queryEmbeddingMs)
        let r = BenchmarkMath.microseconds(fromMilliseconds: sample.warmRetrievalMs)
        let h = BenchmarkMath.microseconds(fromMilliseconds: sample.hydrationMs)
        return BenchmarkTimingSample(queryId: index, embeddingUs: e, retrievalUs: r, hydrationUs: h, endToEndUs: e + r + h)
    }

    // MARK: - Files

    private static func removeDatabase(_ url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private static func removeEmptyWorkDirectory(_ env: BenchmarkRunEnvironment) {
        let path = env.workDirectory.path
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: path), entries.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Environments

    /// Fixture mode: unit vector at `FNV1a32(formatted UTF-8) mod outputDims` (inside the kept
    /// Matryoshka prefix), prompt count = scalar count, chat answer `[1]` only when an evidence
    /// marker exists, fixed digests and a counter clock. Never a measurement.
    static func fixtureEnvironment(_ options: BenchmarkOptions, workDirectory: URL? = nil) -> BenchmarkRunEnvironment {
        var tick: Int64 = 0
        let sampleTicks = FixtureTicks()
        let pendingHash = (try? TokenEstimateResource.bundled().payloadHash) ?? String(repeating: "0", count: 64)
        let root = (try? ProviderAPIRoot.normalize(options.host)) ?? BenchmarkOptions.defaultHost
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        return BenchmarkRunEnvironment(
            platform: "macos",
            host: BenchmarkEnvironment(cpu: "fixture", ramBytes: 17_179_869_184, os: "fixture", architecture: architecture,
                                       buildCommit: String(repeating: "f", count: 40), ollamaVersion: "0.0.0-fixture",
                                       accelerator: "fixture"),
            capture: { profile in
                try Task.checkCancellation()
                let index = (EmbeddingProfiles.ids.firstIndex(of: profile.id) ?? 0) + 1
                let hex = Array("0123456789abcdef")[index % 16]
                let limit = profile.maxInputTokens
                let identity = GenerationIdentity(
                    providerId: ProviderConfig.ollamaId,
                    endpointRevision: EmbeddingEndpointRevision.make(type: .ollama, normalizedRoot: root),
                    model: profile.model, modelDigest: "sha256:" + String(repeating: String(hex), count: 64),
                    dims: profile.dims, normalization: "l2",
                    queryFormatVersion: profile.formatVersion(.query, effectiveLimit: limit),
                    docFormatVersion: profile.formatVersion(.document, effectiveLimit: limit), chunkerVersion: "2")
                return BenchmarkCapture(identity: identity, effectiveLimit: limit,
                                        transport: FixtureTransport(outputDims: profile.dims))
            },
            verify: { _, _ in try Task.checkCancellation() },
            observeChat: { messages in
                try Task.checkCancellation()
                let evidence = messages.contains { $0.content.contains("[1]") }
                let prompt = messages.reduce(0) { $0 + $1.content.unicodeScalars.count }
                return ChatTokenObservation(text: evidence ? "[1]" : "Not found.", promptTokens: prompt, outputTokens: 1)
            },
            observeRaw: { text in
                try Task.checkCancellation()
                // Synthetic count only (never a measurement): ceil(3/10 per scalar) plus one BOS-like token.
                let n = text.unicodeScalars.count
                return ChatTokenObservation(text: "x", promptTokens: (n * 3 + 9) / 10 + 1, outputTokens: 1)
            },
            nowUs: { tick += 100; return tick },
            startSampler: {
                let sampler = ProcessMemorySampler(intervalMs: 3_600_000) {
                    ProcessMemorySample(atUs: sampleTicks.next(), runnerBytes: 1_000_000, serverTreeBytes: 2_000_000)
                }
                await sampler.start()
                return sampler
            },
            memoryMethod: "fixture", chatDigest: "sha256:" + String(repeating: "a", count: 64), tokenFamily: "unverified",
            showTemplateSha256: String(repeating: "e", count: 64),
            estimator: (try? TokenEstimatorV2(family: "unverified", rates: []))!,
            calibrationHash: pendingHash,
            workDirectory: workDirectory ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("ainotebook-wp7-\(UUID().uuidString)"),
            paceConcurrentQueries: true)
    }

    private final class FixtureTicks: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 0
        func next() -> Int64 { lock.withLock { value += 1; return value } }
    }

    private struct FixtureTransport: StrictEmbeddingTransport {
        let outputDims: Int
        func embed(model: String, input: String, nativeDims: Int, inputLimit: Int) async throws -> StrictEmbeddingResult {
            try Task.checkCancellation()
            var vector = [Float](repeating: 0, count: nativeDims)
            vector[Int(BenchmarkMeasurements.fnv1a32(input) % UInt32(min(outputDims, nativeDims)))] = 1
            return StrictEmbeddingResult(vector: vector, promptTokens: input.unicodeScalars.count,
                                         totalDurationNs: nil, loadDurationNs: nil)
        }
    }

    private static func liveEnvironment(_ options: BenchmarkOptions) async throws -> BenchmarkRunEnvironment {
        let root = try ProviderAPIRoot.normalize(options.host)
        guard let url = URL(string: root) else { throw BenchmarkError(code: "invalidArguments") }
        let client = OllamaBenchmarkClient(baseURL: url)
        let snapshot = EmbeddingProviderSnapshot(providerId: ProviderConfig.ollamaId, type: .ollama, root: root,
                                                 enabled: true, consented: true, embeddingCapable: true)
        let chatDigest = OllamaBenchmarkClient.exactDigest(model: options.chatModel, rows: try await client.tags())
        let template = try? await client.templateSha256(model: options.chatModel)
        let version = try? await client.version()
        // The benchmark takes its estimator from the supplied exact-digest calibration.
        let resource: TokenEstimateResource
        if let path = options.calibration {
            resource = try JSONDecoder().decode(TokenEstimateResource.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            try resource.validate(production: true)
        } else {
            resource = try TokenEstimateResource.bundled()
        }
        let family = TokenEstimatorV2.resolveFamily(model: options.chatModel, modelDigest: chatDigest,
                                                    bindings: resource.bindings)
        let estimator = try family.map { f in try TokenEstimatorV2(family: f, rates: resource.rates.filter { $0.family == f }) }
            ?? TokenEstimatorV2(family: "unverified", rates: [])
        let countOptions = ChatRequestOptions(runtimeContext: 8192, maxOutputTokens: 1)
        let counter: (any ExactTokenCounting)? = options.tokenizerRoot.map { dir in
            OfflineTokenizerProcess(executable: URL(fileURLWithPath: "/usr/bin/env"),
                                    arguments: ["python3", "tools/benchmark/tokenize_offline.py", "--root", dir])
        }
        let pid = options.ollamaPid
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return BenchmarkRunEnvironment(
            platform: "macos",
            host: BenchmarkEnvironment(cpu: cpuBrand(), ramBytes: Int64(ProcessInfo.processInfo.physicalMemory),
                                       os: ProcessInfo.processInfo.operatingSystemVersionString,
                                       architecture: machine == "x86_64" ? "x64" : machine,
                                       buildCommit: ProcessInfo.processInfo.environment["AINOTEBOOK_BUILD_COMMIT"],
                                       ollamaVersion: version ?? nil, accelerator: "metal"),
            capture: { profile in
                let prepared = try await OllamaBenchmarkClient.prepareProfile(profile, provider: snapshot, client: client)
                return BenchmarkCapture(identity: prepared.identity, effectiveLimit: prepared.effectiveLimit,
                                        transport: client, counter: counter)
            },
            verify: { profile, capture in
                _ = try await OllamaBenchmarkClient.revalidate(capture.identity, profile: profile, client: client)
                guard let context = try await client.contextLength(model: profile.model),
                      min(profile.maxInputTokens, context) == capture.effectiveLimit else {
                    throw EmbeddingProfileError(code: "embeddingModelChanged")
                }
            },
            // Count-only observations: num_ctx 8192, num_predict 1, temperature 0 (benchmark-v1 §5.3).
            observeChat: { try await client.observeChat(model: options.chatModel, messages: $0, options: countOptions) },
            observeRaw: { try await client.observeRaw(model: options.chatModel, text: $0, options: countOptions) },
            nowUs: { Int64(DispatchTime.now().uptimeNanoseconds / 1000) },
            startSampler: {
                guard let pid else { return nil }
                let sampler = ProcessMemorySampler {
                    try BenchmarkTelemetry.sampleProcesses(serverRootPid: pid,
                                                           atUs: Int64(DispatchTime.now().uptimeNanoseconds / 1000))
                }
                await sampler.start()
                return sampler
            },
            memoryMethod: BenchmarkTelemetry.memoryMethod, chatDigest: chatDigest, tokenFamily: family,
            showTemplateSha256: template ?? nil, estimator: estimator, calibrationHash: resource.payloadHash,
            workDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ainotebook-wp7-\(UUID().uuidString)"))
    }

    private static func cpuBrand() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

import Foundation
import GRDB

/// The detector, chunk and metadata products of one extraction, before publication.
struct PreparedExtraction: Sendable {
    let document: CanonicalDocument
    let draft: RevisionDraft
    let chunks: [RevisionChunkDraft]
    let chunkDetections: [LanguageTextDecision?]
    let documentDetection: LanguageAggregate?
    let metadata: PublicationMetadata
}

enum FolderExtractionOutcome: Equatable, Sendable {
    case published(Int64)
    case changedDuringExtraction
    case superseded
}

/// Executes a queue-claimed extract job: snapshot through the validated
/// no-follow adapter, bounded extraction from the private copy, language
/// detection of the canonical text and of each chunk, verification that the
/// original is unchanged, then one fenced publication transaction.
/// IO/codec/limit errors propagate so the queue records a fenced failure and
/// the previous published revision stays searchable.
public struct FolderExtractionWorker: Sendable {
    private let store: NotebookStore
    private let fileSystem: any FolderFileSystem
    private let detector: LanguageDetector
    private let clock: any IngestLeaseClock
    private let embeddingSelection: @Sendable (Int64) async throws -> EmbeddingSelection?
    private let extract: @Sendable (URL, SourceType, FolderRules) async throws -> CanonicalDocument
    /// Re-fetches a loose web source's automatic retry; nil = web retries are unavailable.
    private let web: (any TextExtractor)?

    public init(store: NotebookStore, fileSystem: any FolderFileSystem,
                detector: LanguageDetector, clock: any IngestLeaseClock,
                embeddingSelection: @escaping @Sendable (Int64) async throws -> EmbeddingSelection?,
                web: (any TextExtractor)? = nil,
                extract: @escaping @Sendable (URL, SourceType, FolderRules) async throws -> CanonicalDocument) {
        self.store = store
        self.fileSystem = fileSystem
        self.detector = detector
        self.clock = clock
        self.embeddingSelection = embeddingSelection
        self.web = web
        self.extract = extract
    }

    public func execute(job: IngestJob, fence: JobFence) async throws {
        do { _ = try await run(job: job, fence: fence) } catch {
            await refillSpreadsheetUpgrades(after: job)
            throw error
        }
        await refillSpreadsheetUpgrades(after: job)
    }

    /// A finished spreadsheet-upgrade job tops the throttled batch up again
    /// (`ingestion-reextract-v1` §7), so the upgrade drains with extraction
    /// instead of waiting for the next periodic reconciliation. Best effort.
    private func refillSpreadsheetUpgrades(after job: IngestJob) async {
        guard job.draft.optionsJSON.contains("\"\(ExtractorRevision.spreadsheetOptionsKey)\"") else { return }
        let store = self.store, clock = self.clock
        _ = try? storeWork { try store.requeueSpreadsheetUpgrades(now: clock.now()) }
    }

    func run(job: IngestJob, fence: JobFence) async throws -> FolderExtractionOutcome {
        guard job.draft.kind == "extract", let sourceId = Int64(job.draft.target.dropFirst("source:".count)) else {
            throw StorageV19Error.invalidValue
        }
        let store = self.store, clock = self.clock
        // A loose source's automatic retry re-reads its own file or URL (ingestion-retry-cap-v1 §3a).
        if let loose = try storeWork({ try store.looseExtractionTarget(sourceId: sourceId) }) {
            return try await runLoose(loose, job: job, fence: fence)
        }
        let loaded = try storeWork { () throws -> (ExtractionRequest, FolderSource, Int64)? in
            guard let request = try store.extractionRequest(sourceId: sourceId),
                  let source = try store.source(id: sourceId) else { return nil }
            let state = try store.runOnDatabase { db in
                try Row.fetchOne(db, sql: "SELECT availability,eligible FROM sources WHERE id=?", arguments: [sourceId])
            }
            guard let state, state["availability"] as String == "present", state["eligible"] as Bool else { return nil }
            return (request, try store.folderSource(id: request.folderId), source.notebookId)
        }
        guard let (request, folder, notebookId) = loaded else {
            // Missing, ineligible or unavailable: nothing to extract.
            _ = try storeWork { try store.cancelOwnedExtraction(fence: fence, now: clock.now()) }
            return .superseded
        }
        let snapshot = try snapshot(request: request, folder: folder)
        defer { snapshot.close() }
        try Task.checkCancellation()
        let prepared = try await prepare(request: request, snapshot: snapshot)
        try Task.checkCancellation()
        let selection = try await Self.publishableSelection(notebookId, embeddingSelection)
        return try await finish(request: request, folder: folder, snapshot: snapshot, prepared: prepared,
                                selection: selection, fence: fence)
    }

    /// One automatic attempt for a loose source: the bounded canonical pipeline
    /// on its local file (as `IngestionService` ingests it), or a re-fetch of a
    /// web source. Errors propagate so the queue records a fenced failure; a
    /// source with nothing to re-read ends its job without an attempt.
    func runLoose(_ target: LooseExtractionTarget, job: IngestJob, fence: JobFence) async throws -> FolderExtractionOutcome {
        let store = self.store, clock = self.clock
        if let file = target.file {
            let rules = FolderRules.defaults, limits = rules.limits
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size <= limits.fileBytes else { throw IngestionError(code: "fileLimit") }
            let document = try await extract(file, target.kind, rules)
            try Task.checkCancellation()
            let (hash, bytes) = try IngestionService.streamingHash(file, maxBytes: limits.fileBytes)
            let prepared = try Self.prepare(document: document, contentHash: hash, sizeBytes: bytes,
                                            filename: file.lastPathComponent, limits: limits, detector: detector)
            let selection = try await Self.publishableSelection(target.notebookId, embeddingSelection)
            try Task.checkCancellation()
            let revision = try storeWork {
                try store.publishLooseExtraction(sourceId: target.sourceId, draft: prepared.draft, chunks: prepared.chunks,
                                                 metadata: prepared.metadata, embeddingSelection: selection,
                                                 fence: fence, now: clock.now())
            }
            return revision.map { .published($0.id) } ?? .superseded
        }
        // A URL is fetched only for an explicit user retry unless background web retries are on (§3a).
        if let url = target.url, let web,
           ExtractionRetryBudget.backgroundWebRetry || RetryBudgetSQL.userInitiated(job) {
            let extracted = try await web.extract(from: url, kind: target.kind)
            try Task.checkCancellation()
            let assembled = ExtractedRevisionAssembly.make(extracted: extracted, kind: target.kind)
            let revision = try storeWork {
                try store.commitExtraction(sourceId: target.sourceId, draft: assembled.draft, chunks: assembled.chunks,
                                           fence: fence, now: clock.now())
            }
            return revision.map { .published($0.id) } ?? .superseded
        }
        _ = try storeWork { try store.abandonLooseExtraction(fence: fence, now: clock.now()) }
        return .superseded
    }

    /// A selection lookup failure (e.g. a Keychain error) never fails extraction:
    /// the revision publishes without an embed job and the indexing status shows
    /// why. Only cancellation propagates.
    static func publishableSelection(_ notebookId: Int64,
                                     _ lookup: @Sendable (Int64) async throws -> EmbeddingSelection?) async throws -> EmbeddingSelection? {
        do { return try await lookup(notebookId) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    func snapshot(request: ExtractionRequest, folder: FolderSource) throws -> FolderFileSnapshot {
        try fileSystem.snapshot(root: folder, relativePath: request.relPath, maxBytes: request.rules.limits.fileBytes)
    }

    func prepare(request: ExtractionRequest, snapshot: FolderFileSnapshot) async throws -> PreparedExtraction {
        let kind = SourceType.detect(filename: request.relPath) ?? .text
        let document = try await extract(snapshot.url, kind, request.rules)
        return try prepare(document: document, request: request, snapshot: snapshot)
    }

    /// Detection runs on canonical text and on each original chunk; spans are
    /// never derived from normalized detector offsets.
    func prepare(document: CanonicalDocument, request: ExtractionRequest, snapshot: FolderFileSnapshot) throws -> PreparedExtraction {
        let filename = request.relPath.split(separator: "/").last.map(String.init) ?? request.relPath
        return try Self.prepare(document: document, contentHash: snapshot.hash, sizeBytes: snapshot.stamp.sizeBytes,
                                filename: filename, limits: request.rules.limits, detector: detector)
    }

    /// Shared by folder and loose publication: bounded scalar chunks, document
    /// and per-chunk detection, deterministic descriptor and coverage.
    static func prepare(document: CanonicalDocument, contentHash: String, sizeBytes: Int64, filename: String,
                        limits: IngestionLimits, detector: LanguageDetector) throws -> PreparedExtraction {
        guard document.text.unicodeScalars.count <= limits.textScalars else { throw IngestionError(code: "textLimit") }
        // Label-only detection: the same decisions as detectDocument/detectText without diagnostics.
        let documentResult = detector.decideDocument(document.text)
        let raw = try ScalarChunker.bounded(document.text, pages: document.pages, maxChunks: limits.chunks)
        var detections: [LanguageTextDecision?] = []
        let chunks = raw.map { chunk -> RevisionChunkDraft in
            let result = detector.decideText(chunk.text)
            detections.append(result)
            let language = ChunkLanguage.resolve(label: result?.label, reason: result?.reason,
                                                 documentLabel: documentResult?.label)
            return RevisionChunkDraft(text: chunk.text, tokenCount: chunk.tokenCount, pageHint: chunk.pageHint,
                                      charStart: chunk.charStart, charEnd: chunk.charEnd,
                                      lang: language.lang, langInherited: language.langInherited)
        }
        let descriptor = SourceDescriptor.make(document: document, filename: filename,
                                               sizeBytes: sizeBytes, lang: documentResult?.label)
        let metadata = PublicationMetadata(encoding: document.encoding, lang: documentResult?.label,
                                           coverageJSON: try documentResult.map(LanguageCoverageJSON.make),
                                           descriptorJSON: try descriptor.json(), pages: document.pages)
        return PreparedExtraction(document: document,
                                  draft: RevisionDraft(contentHash: contentHash, canonicalText: document.text,
                                                       textFormatVersion: textFormatVersion(kind: document.kind),
                                                       chunkerVersion: 2),
                                  chunks: chunks, chunkDetections: detections, documentDetection: documentResult,
                                  metadata: metadata)
    }

    /// Spreadsheets carry the compact spreadsheet text (`ingestion-xlsx-v2`); every other kind format 1.
    static func textFormatVersion(kind: String) -> Int {
        kind == SourceType.xlsx.rawValue ? SpreadsheetText.formatVersion : 1
    }

    /// Post-extraction stat and streaming hash of the original must match the
    /// snapshot; otherwise fresh work is queued and nothing is published.
    func finish(request: ExtractionRequest, folder: FolderSource, snapshot: FolderFileSnapshot,
                prepared: PreparedExtraction, selection: EmbeddingSelection?, fence: JobFence,
                fault: @escaping @Sendable (String) throws -> Void = { _ in }) async throws -> FolderExtractionOutcome {
        let store = self.store, clock = self.clock
        let original = try fileSystem.hash(root: folder, relativePath: request.relPath, maxBytes: request.rules.limits.fileBytes)
        guard original.sha256.utf8.elementsEqual(snapshot.hash.utf8), original.stamp == snapshot.stamp else {
            _ = try storeWork { try store.requestFreshExtraction(sourceId: request.sourceId, fence: fence, now: clock.now()) }
            return .changedDuringExtraction
        }
        let observed = ExtractionRequest(sourceId: request.sourceId, folderId: request.folderId, relPath: request.relPath,
                                         stamp: snapshot.stamp, hash: snapshot.hash, rules: request.rules)
        let revision = try storeWork {
            try store.publishFolderExtraction(request: observed, draft: prepared.draft, chunks: prepared.chunks,
                                              metadata: prepared.metadata, embeddingSelection: selection,
                                              fence: fence, now: clock.now(), fault: fault)
        }
        return revision.map { .published($0.id) } ?? .superseded
    }
}

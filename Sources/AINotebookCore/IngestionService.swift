import CryptoKit
import Foundation

/// Orchestrates: type-detect → text-extract → chunk → persist, updating
/// the source's status row at every stage. Mutating store calls are
/// serialised through the store's `@MainActor`; the heavy extraction work
/// runs off-actor.
///
/// `@unchecked Sendable` because the only mutable reference held is
/// `NotebookStore`, which is itself `@MainActor`-isolated — every touch
/// is hopped onto the main actor via `MainActor.run`, so cross-thread
/// races are impossible in practice.
public final class IngestionService: @unchecked Sendable {
    public enum IngestionError: Error, Equatable {
        case unsupportedExtension(String)
    }

    private let store: NotebookStore
    private let plain:  TextExtractor?
    private let pdf:    TextExtractor?
    private let web:    TextExtractor
    private let office: TextExtractor?
    private let onChunksWritten: (@Sendable () async -> Void)?
    private let leaseClock: any IngestLeaseClock
    private let detector: LanguageDetector
    private let embeddingSelection: (@Sendable (Int64) async throws -> EmbeddingSelection?)?
    /// The process-wide durable folder runtime, when the app installed one.
    public let folderRuntime: FolderIngestionRuntime?

    /// File extractors left `nil` use the bounded canonical path (scalar
    /// chunks v2, encoding/descriptor/language/page map). Injected legacy
    /// extractors keep their exact behaviour for compatibility tests.
    public init(
        store: NotebookStore,
        plain:  TextExtractor? = nil,
        pdf:    TextExtractor? = nil,
        web:    TextExtractor = WebExtractor(),
        office: TextExtractor? = nil,
        onChunksWritten: (@Sendable () async -> Void)? = nil,
        leaseClock: any IngestLeaseClock = SystemIngestLeaseClock(),
        folderRuntime: FolderIngestionRuntime? = nil,
        detector: LanguageDetector = .bundled(),
        embeddingSelection: (@Sendable (Int64) async throws -> EmbeddingSelection?)? = nil
    ) {
        self.store = store
        self.plain = plain
        self.pdf = pdf
        self.web = web
        self.office = office
        self.onChunksWritten = onChunksWritten
        self.leaseClock = leaseClock
        self.folderRuntime = folderRuntime
        self.detector = detector
        self.embeddingSelection = embeddingSelection
    }

    /// The injected legacy extractor for a file kind, or nil for the canonical path.
    private func legacyExtractor(for kind: SourceType) -> TextExtractor? {
        switch kind {
        case .pdf: return pdf
        case .text, .markdown: return plain
        case .docx, .pptx, .xlsx: return office
        case .web: return web
        case .note, .email: return nil
        }
    }

    @discardableResult
    public func ingestFile(_ url: URL, into notebookId: Int64) async throws -> Source {
        guard let kind = SourceType.detect(filename: url.lastPathComponent) else {
            throw IngestionError.unsupportedExtension(url.pathExtension)
        }
        let title = url.deletingPathExtension().lastPathComponent
        let source = try await MainActor.run {
            try store.createSource(
                notebookId: notebookId,
                type: kind,
                title: title,
                uri: nil,
                rawPath: url.path
            )
        }
        return try await runFile(source: source, url: url, kind: kind)
    }

    private func runFile(source: Source, url: URL, kind: SourceType) async throws -> Source {
        if let legacy = legacyExtractor(for: kind) {
            return try await runPipeline(for: source) { try await legacy.extract(from: url, kind: kind) }
        }
        return try await runCanonicalPipeline(for: source, url: url, kind: kind)
    }

    @discardableResult
    public func ingestRawText(title: String, text: String, into notebookId: Int64) async throws -> Source {
        let source = try await MainActor.run {
            try store.createSource(
                notebookId: notebookId,
                type: .text,
                title: title,
                uri: nil,
                rawPath: nil
            )
        }
        return try await runPipeline(for: source) {
            ExtractedText(title: title, text: text)
        }
    }

    @discardableResult
    public func ingestURL(_ url: URL, into notebookId: Int64) async throws -> Source {
        let source = try await MainActor.run {
            try store.createSource(
                notebookId: notebookId,
                type: .web,
                title: url.host ?? url.absoluteString,
                uri: url.absoluteString,
                rawPath: nil
            )
        }
        return try await runPipeline(for: source) { [self] in
            try await web.extract(from: url, kind: .web)
        }
    }

    /// Re-ingests an existing source from its stored raw path or URI (folder
    /// watch / URL re-crawl, FR-E1/E2). Ported from the Windows `ReIngestAsync`.
    @discardableResult
    public func reIngest(sourceId: Int64) async throws -> Source {
        let loaded = try await MainActor.run { () throws -> (Source, Bool)? in
            guard let source = try store.source(id: sourceId) else { return nil }
            let inFolder = try store.runOnDatabase {
                try Int64.fetchOne($0, sql: "SELECT folder_id FROM sources WHERE id=?", arguments: [sourceId])
            } != nil
            return (source, inFolder)
        }
        guard let (source, inFolder) = loaded else { throw IngestionError.unsupportedExtension("(source \(sourceId) not found)") }
        if inFolder {
            // Folder files are re-read only through the durable, fenced worker.
            let clock = leaseClock
            return try await MainActor.run { () throws -> Source in
                try store.requestSourceExtraction(sourceId: sourceId, now: clock.now())
                return try store.source(id: sourceId) ?? source
            }
        }
        let kind = source.type
        if let raw = source.rawPath {
            return try await runFile(source: source, url: URL(fileURLWithPath: raw), kind: kind)
        }
        guard let uri = source.uri, let url = URL(string: uri) else {
            throw IngestionError.unsupportedExtension("(source \(sourceId) has no path/URI)")
        }
        return try await runPipeline(for: source) { [self] in
            switch kind {
            case .note: throw IngestionError.unsupportedExtension("note")
            default: return try await web.extract(from: url, kind: kind)
            }
        }
    }

    /// Bounded canonical extraction for loose files: the same preparation and
    /// fenced metadata/page-map/embed-job publication as folder sources.
    private func runCanonicalPipeline(for sourceIn: Source, url: URL, kind: SourceType) async throws -> Source {
        let sourceId = sourceIn.id!, notebookId = sourceIn.notebookId
        let limits = IngestionLimits.defaults, detector = self.detector
        return try await withLease(sourceId: sourceId) { [self] fence in
            let document = try await BoundedDocumentExtractor().extract(url: url, kind: kind, rules: .defaults)
            let (hash, size) = try Self.streamingHash(url, maxBytes: limits.fileBytes)
            let prepared = try FolderExtractionWorker.prepare(document: document, contentHash: hash, sizeBytes: size,
                                                              filename: url.lastPathComponent, limits: limits, detector: detector)
            var selection: EmbeddingSelection?
            if let embeddingSelection {
                selection = try await FolderExtractionWorker.publishableSelection(notebookId, embeddingSelection)
            }
            try Task.checkCancellation()
            return try await MainActor.run {
                try store.publishLooseExtraction(sourceId: sourceId, draft: prepared.draft, chunks: prepared.chunks,
                    metadata: prepared.metadata, embeddingSelection: selection, fence: fence, now: leaseClock.now()) != nil
            }
        }
    }

    /// Bounded streaming SHA-256 of a local file; never buffers the whole file.
    static func streamingHash(_ url: URL, maxBytes: Int64) throws -> (String, Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let block = try handle.read(upToCount: 65_536), !block.isEmpty else { break }
            total += Int64(block.count)
            guard total <= maxBytes else { throw FolderIngestionLimit.fileLimit }
            digest.update(data: block)
        }
        return (digest.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    private enum FolderIngestionLimit: Error { case fileLimit }

    private func runPipeline(
        for sourceIn: Source,
        extract: @escaping () async throws -> ExtractedText
    ) async throws -> Source {
        let sourceId = sourceIn.id!
        return try await withLease(sourceId: sourceId) { [self] fence in
            let extracted = try await extract()
            try Task.checkCancellation()
            let assembled = ExtractedRevisionAssembly.make(extracted: extracted, kind: sourceIn.type)
            return try await MainActor.run {
                try Task.checkCancellation()
                return try store.commitExtraction(sourceId: sourceId, draft: assembled.draft,
                    chunks: assembled.chunks, fence: fence, now: leaseClock.now()) != nil
            }
        }
    }

    /// Foreground lease bracket shared by legacy and canonical paths. A
    /// cancelled attempt becomes a visible `cancelled` refresh error (never a
    /// permanently pending refresh); other errors fail the fenced job.
    private func withLease(sourceId: Int64, body: @escaping (JobFence) async throws -> Bool) async throws -> Source {
        let fence = try await MainActor.run {
            try Task.checkCancellation()
            return try store.beginExtraction(sourceId: sourceId, now: leaseClock.now(), leaseToken: UUID().uuidString)
        }
        let renewal = ExtractionLeaseRenewal.start(store: store, fence: fence, clock: leaseClock)
        return try await withTaskCancellationHandler {
            do {
                let committed = try await body(fence)
                renewal.cancel()
                await renewal.value
                let source = try await MainActor.run { () throws -> Source in
                    guard let fresh = try store.source(id: sourceId) else { throw StorageV19Error.notFound }
                    return fresh
                }
                if committed { await onChunksWritten?() }
                return source
            } catch {
                renewal.cancel()
                await renewal.value
                let cancelled = error is CancellationError || Task.isCancelled
                _ = try? await MainActor.run {
                    if cancelled {
                        return try store.cancelIngestJob(id: fence.jobId, fence: fence, now: leaseClock.now())
                    }
                    return try store.failJob(fence: fence, error: Self.code(error), now: leaseClock.now())
                }
                throw error
            }
        } onCancel: {
            renewal.cancel()
        }
    }

    private static func code(_ error: Error) -> String {
        if let error = error as? AINotebookCore.IngestionError { return error.code }
        if error is FolderIngestionLimit { return "fileLimit" }
        return String(describing: error)
    }
}

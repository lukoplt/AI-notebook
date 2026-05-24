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
    private let plain:  TextExtractor
    private let pdf:    TextExtractor
    private let web:    TextExtractor
    private let office: TextExtractor
    private let onChunksWritten: (@Sendable () async -> Void)?

    public init(
        store: NotebookStore,
        plain:  TextExtractor = PlainTextExtractor(),
        pdf:    TextExtractor = PDFExtractor(),
        web:    TextExtractor = WebExtractor(),
        office: TextExtractor = OfficeExtractor(),
        onChunksWritten: (@Sendable () async -> Void)? = nil
    ) {
        self.store = store
        self.plain = plain
        self.pdf = pdf
        self.web = web
        self.office = office
        self.onChunksWritten = onChunksWritten
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
        return try await runPipeline(for: source) { [self] in
            switch kind {
            case .pdf:
                let extracted = try await pdf.extract(from: url, kind: kind)
                let pages: [(String, Int)]
                if let hints = extracted.pageHints {
                    let split = extracted.text.split(separator: "\u{0C}", omittingEmptySubsequences: false)
                    pages = zip(split, hints).map { (String($0.0), $0.1) }
                } else {
                    pages = [(extracted.text, 0)]
                }
                return (extracted, Chunker.chunkPaged(pages))
            case .text, .markdown:
                let e = try await plain.extract(from: url, kind: kind)
                return (e, Chunker.chunk(e.text))
            case .docx, .pptx, .xlsx:
                let e = try await office.extract(from: url, kind: kind)
                return (e, Chunker.chunk(e.text))
            case .web:
                let e = try await web.extract(from: url, kind: kind)
                return (e, Chunker.chunk(e.text))
            case .note:
                // .note sources are managed via Notebook notes, not file ingestion.
                throw IngestionError.unsupportedExtension(url.pathExtension)
            }
        }
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
            let e = ExtractedText(title: title, text: text)
            return (e, Chunker.chunk(text))
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
            let e = try await web.extract(from: url, kind: .web)
            return (e, Chunker.chunk(e.text))
        }
    }

    private func runPipeline(
        for sourceIn: Source,
        extract: () async throws -> (ExtractedText, [ChunkDraft])
    ) async throws -> Source {
        var source = sourceIn
        do {
            try await MainActor.run {
                try store.updateSourceStatus(id: source.id!, status: .chunking, error: nil)
            }
            let (_, chunks) = try await extract()
            try await MainActor.run {
                try store.replaceChunks(sourceId: source.id!, chunks: chunks)
                try store.updateSourceStatus(id: source.id!, status: .ready, error: nil)
            }
            await onChunksWritten?()
            source.status = .ready
            return source
        } catch {
            let message = String(describing: error)
            try? await MainActor.run {
                try store.updateSourceStatus(id: source.id!, status: .error, error: message)
            }
            throw error
        }
    }
}

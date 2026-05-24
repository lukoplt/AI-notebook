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
            case .pdf:                                  return try await pdf.extract(from: url, kind: kind)
            case .text, .markdown:                      return try await plain.extract(from: url, kind: kind)
            case .docx, .pptx, .xlsx:                   return try await office.extract(from: url, kind: kind)
            case .web:                                  return try await web.extract(from: url, kind: kind)
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

    private func runPipeline(
        for sourceIn: Source,
        extract: () async throws -> ExtractedText
    ) async throws -> Source {
        var source = sourceIn
        do {
            try await MainActor.run {
                try store.updateSourceStatus(id: source.id!, status: .chunking, error: nil)
            }
            let extracted = try await extract()
            let chunks = Chunker.chunk(extracted.text)
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

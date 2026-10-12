import Foundation
import PDFKit

/// Test instrumentation is synchronous and runs at the same pre-allocation
/// boundaries as the production reader. It can inject cancellation/errors.
struct DocumentReadHooks: Sendable {
    let event: @Sendable (String, Int) throws -> Void
    init(event: @escaping @Sendable (String, Int) throws -> Void = { _, _ in }) { self.event = event }
}

public struct BoundedDocumentExtractor: Sendable {
    private let hooks: DocumentReadHooks
    public init() { hooks = DocumentReadHooks() }
    init(hooks: DocumentReadHooks) { self.hooks = hooks }

    public func extract(url: URL, kind: SourceType, rules: FolderRules) async throws -> CanonicalDocument {
        do { return try await extractLocal(url: url, kind: kind, rules: rules) }
        catch where url.isFileURL && !((error as? IngestionError)?.code.hasSuffix("Limit") ?? false) {
            // A loose file still in the cloud (iCloud placeholder) fails to read: say so.
            throw DatalessFile.readFailure(error, stillDataless: DatalessFile.isNotDownloaded(url))
        }
    }

    private func extractLocal(url: URL, kind: SourceType, rules: FolderRules) async throws -> CanonicalDocument {
        try Task.checkCancellation()
        guard url.isFileURL else { throw IngestionError(code: "outsideRoot") }
        try rules.limits.validate()
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length <= UInt64(rules.limits.fileBytes) else { throw IngestionError(code: "fileLimit") }
        try file.seek(toOffset: 0)

        switch kind {
        case .text, .markdown:
            var readBytes: Int64 = 0
            let decoded = try TextDecoding.decode(read: {
                try Task.checkCancellation()
                guard let data = try file.read(upToCount: 65_536), !data.isEmpty else { return nil }
                guard data.count <= rules.limits.fileBytes - readBytes else { throw IngestionError(code: "fileLimit") }
                readBytes += Int64(data.count)
                return data
            }, rewind: {
                try file.seek(toOffset: 0)
                readBytes = 0
            }, fallback: rules.encodingFallback, maxScalars: rules.limits.textScalars)
            return CanonicalDocument(text: decoded.text, title: nil, kind: kind.rawValue,
                                     pages: [], sheetNames: [], encoding: decoded.encoding)
        case .pdf:
            return try readPDF(url: url, limits: rules.limits)
        case .docx, .pptx, .xlsx:
            let reader = try BoundedOfficeReader(url: url, limits: rules.limits, hooks: hooks)
            defer { reader.close() }
            return try reader.read(kind: kind)
        case .email:
            // Bounded by fileBytes above; the reader debits decoded bytes from officeBytes.
            var bytes: [UInt8] = []
            bytes.reserveCapacity(Int(length))
            while let block = try file.read(upToCount: 65_536), !block.isEmpty {
                try Task.checkCancellation()
                guard bytes.count + block.count <= Int(rules.limits.fileBytes) else { throw IngestionError(code: "fileLimit") }
                bytes += block
            }
            return try MailReader.read(data: bytes, fileExtension: url.pathExtension, fallback: rules.encodingFallback,
                                       limits: rules.limits)
        default:
            throw IngestionError(code: "unsupportedSyntax")
        }
    }

    private func readPDF(url: URL, limits: IngestionLimits) throws -> CanonicalDocument {
        guard let document = PDFDocument(url: url), !document.isLocked else { throw IngestionError(code: "corruptArchive") }
        guard document.pageCount <= limits.pdfPages else { throw IngestionError(code: "pageLimit") }
        var builder = try CanonicalTextBuilder(maxScalars: limits.textScalars)
        var pages: [PageBoundary] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            if index > 0 { try builder.append("\n\n") }
            let start = builder.count
            try hooks.event("pageText", 1)
            // PDFKit allocates a page string internally. The canonical output cap
            // cannot bound that allocation; the worker reserves a parser allowance.
            guard let page = document.page(at: index) else { throw IngestionError(code: "corruptArchive") }
            let scalars = (page.string ?? "").unicodeScalars
            var lo = scalars.startIndex, hi = scalars.endIndex
            while lo < hi, ScalarChunker.isWhitespace(scalars[lo].value) { scalars.formIndex(after: &lo) }
            while lo < hi {
                let previous = scalars.index(before: hi)
                guard ScalarChunker.isWhitespace(scalars[previous].value) else { break }
                hi = previous
            }
            var scalarCount = 0
            for _ in scalars[lo..<hi] {
                guard scalarCount < limits.textScalars - builder.count else { throw IngestionError(code: "textLimit") }
                scalarCount += 1
            }
            try builder.append(String(scalars[lo..<hi]))
            pages.append(PageBoundary(page: index + 1, start: start, end: builder.count))
        }
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return CanonicalDocument(text: builder.text, title: title, kind: "pdf", pages: pages, sheetNames: [], encoding: nil)
    }
}

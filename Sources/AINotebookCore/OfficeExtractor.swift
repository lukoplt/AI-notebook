// Sources/AINotebookCore/OfficeExtractor.swift
import Foundation

/// Legacy `TextExtractor` for .docx/.pptx/.xlsx (injectable into
/// `IngestionService`). It shares the bounded OOXML reader used by folder and
/// loose-file indexing, so both resolve the main part through the package
/// relationships (e.g. `word/document2.xml`) and order slides by presentation
/// order. Same behaviour as Windows `OfficeTextExtractor`.
public struct OfficeExtractor: TextExtractor {
    public init() {}

    public func extract(from url: URL, kind: SourceType) async throws -> ExtractedText {
        guard [.docx, .pptx, .xlsx].contains(kind) else { throw ExtractorError.officeArchiveCorrupt(url) }
        let document: CanonicalDocument
        do {
            document = try await BoundedDocumentExtractor().extract(url: url, kind: kind, rules: .defaults)
        } catch let error as IngestionError {
            switch error.code {
            case "missingMainPart": throw ExtractorError.officeMainPartMissing(url)
            case "corruptArchive", "invalidRelationship", "invalidCell", "unsupportedSyntax":
                throw ExtractorError.officeArchiveCorrupt(url)
            default: throw error   // limits, notDownloaded, ...: keep the specific code
            }
        }
        let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExtractorError.emptyContent }
        return ExtractedText(title: url.deletingPathExtension().lastPathComponent, text: text)
    }
}

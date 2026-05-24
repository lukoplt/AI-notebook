// Sources/AINotebookCore/PDFExtractor.swift
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

public struct PDFExtractor: TextExtractor {
    public init() {}

    public func extract(from url: URL, kind: SourceType) async throws -> ExtractedText {
        guard let doc = PDFDocument(url: url) else {
            throw ExtractorError.pdfOpenFailed(url)
        }
        var parts: [String] = []
        var hints: [Int] = []
        for i in 0..<doc.pageCount {
            if let p = doc.page(at: i), let s = p.string {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(trimmed)
                    hints.append(i + 1)
                }
            }
        }
        let joined = parts.joined(separator: "\u{0C}")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ExtractorError.emptyContent
        }
        let title = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
            ?? url.deletingPathExtension().lastPathComponent
        return ExtractedText(title: title, text: trimmed, pageHints: hints)
    }
}

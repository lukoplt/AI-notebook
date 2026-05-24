// Sources/AINotebookCore/TextExtractor.swift
import Foundation

public struct ExtractedText: Equatable, Sendable {
    public var title: String
    public var text: String
    /// Optional per-chunk page hints, indexed identically to chunks produced
    /// downstream. `nil` when the extractor cannot determine page boundaries
    /// (txt / md / web / Office text streams).
    public var pageHints: [Int]?

    public init(title: String, text: String, pageHints: [Int]? = nil) {
        self.title = title
        self.text = text
        self.pageHints = pageHints
    }
}

public enum ExtractorError: Error, Equatable {
    case fileNotReadable(URL)
    case unsupportedEncoding(URL)
    case emptyContent
    case pdfOpenFailed(URL)
    case officeArchiveCorrupt(URL)
    case webFetchFailed(URL, status: Int)
    case webResponseNotHTML(URL, mime: String?)
}

public protocol TextExtractor: Sendable {
    /// Extract normalized text. `kind` is the caller's best guess at the
    /// source type (the extractor may double-check it).
    func extract(from url: URL, kind: SourceType) async throws -> ExtractedText
}

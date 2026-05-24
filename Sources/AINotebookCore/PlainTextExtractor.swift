// Sources/AINotebookCore/PlainTextExtractor.swift
import Foundation

public struct PlainTextExtractor: TextExtractor {
    public init() {}

    public func extract(from url: URL, kind: SourceType) async throws -> ExtractedText {
        guard let data = try? Data(contentsOf: url) else {
            throw ExtractorError.fileNotReadable(url)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ExtractorError.unsupportedEncoding(url)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ExtractorError.emptyContent
        }
        let title: String
        if kind == .markdown, let h1 = Self.firstMarkdownHeading(text) {
            title = h1
        } else {
            title = url.deletingPathExtension().lastPathComponent
        }
        return ExtractedText(title: title, text: trimmed)
    }

    private static func firstMarkdownHeading(_ raw: String) -> String? {
        for line in raw.split(whereSeparator: { $0.isNewline }) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") {
                return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

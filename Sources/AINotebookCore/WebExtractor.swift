// Sources/AINotebookCore/WebExtractor.swift
import Foundation
import SwiftSoup

public struct WebExtractor: TextExtractor {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func extract(from url: URL, kind: SourceType) async throws -> ExtractedText {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw ExtractorError.webFetchFailed(url, status: 0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ExtractorError.webFetchFailed(url, status: http.statusCode)
        }
        let mime = http.value(forHTTPHeaderField: "Content-Type")
        guard (mime ?? "").lowercased().contains("text/html") else {
            throw ExtractorError.webResponseNotHTML(url, mime: mime)
        }
        let html = String(decoding: data, as: UTF8.self)
        return try Self.parseHTML(html, sourceURL: url)
    }

    /// Pure HTML → ExtractedText. Tested independently so we don't need a
    /// network stub in unit tests.
    static func parseHTML(_ html: String, sourceURL: URL) throws -> ExtractedText {
        let doc = try SwiftSoup.parse(html)
        // Remove non-content elements before reading the body.
        for tag in ["script", "style", "nav", "footer", "aside", "header", "noscript", "form"] {
            for el in try doc.select(tag).array() {
                try el.remove()
            }
        }
        // Prefer <article> when present, otherwise <main>, otherwise <body>.
        let root: SwiftSoup.Element
        if let art = try doc.select("article").first() {
            root = art
        } else if let main = try doc.select("main").first() {
            root = main
        } else if let body = doc.body() {
            root = body
        } else {
            throw ExtractorError.emptyContent
        }
        let text = try root.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ExtractorError.emptyContent
        }
        let docTitle = (try? doc.title()) ?? ""
        let title = docTitle.isEmpty ? (sourceURL.host ?? "Web source") : docTitle
        return ExtractedText(title: title, text: text)
    }
}

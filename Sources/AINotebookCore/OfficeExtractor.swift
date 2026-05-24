// Sources/AINotebookCore/OfficeExtractor.swift
import Foundation
import ZIPFoundation

public struct OfficeExtractor: TextExtractor {
    public init() {}

    public func extract(from url: URL, kind: SourceType) async throws -> ExtractedText {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ExtractorError.officeArchiveCorrupt(url)
        }

        let xmlPaths: [String]
        switch kind {
        case .docx: xmlPaths = ["word/document.xml"]
        case .pptx: xmlPaths = Self.slidePaths(in: archive)
        case .xlsx: xmlPaths = ["xl/sharedStrings.xml"]
        default:
            throw ExtractorError.officeArchiveCorrupt(url)
        }

        var collected: [String] = []
        for path in xmlPaths {
            guard let entry = archive[path] else { continue }
            var bytes = Data()
            do {
                _ = try archive.extract(entry) { bytes.append($0) }
            } catch {
                throw ExtractorError.officeArchiveCorrupt(url)
            }
            let text = Self.parseXMLTextNodes(bytes)
            if !text.isEmpty { collected.append(text) }
        }
        let joined = collected.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else {
            throw ExtractorError.emptyContent
        }
        let title = url.deletingPathExtension().lastPathComponent
        return ExtractedText(title: title, text: joined)
    }

    /// pptx stores each slide as `ppt/slides/slideN.xml`. Enumerate them.
    private static func slidePaths(in archive: Archive) -> [String] {
        var paths: [String] = []
        for entry in archive {
            let p = entry.path
            if p.hasPrefix("ppt/slides/slide"), p.hasSuffix(".xml") {
                paths.append(p)
            }
        }
        return paths.sorted()
    }

    /// XMLParser-driven plain-text extraction. Collects all character data,
    /// joined by spaces.
    static func parseXMLTextNodes(_ data: Data) -> String {
        let parser = XMLParser(data: data)
        let collector = TextCollector()
        parser.delegate = collector
        parser.parse()
        return collector.text
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class TextCollector: NSObject, XMLParserDelegate {
    var text: [String] = []

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { text.append(t) }
    }
}

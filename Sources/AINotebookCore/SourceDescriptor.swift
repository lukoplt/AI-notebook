import Foundation

/// Deterministic per-revision metadata. It never contains summaries, prose,
/// LLM output or absolute paths. An unknown language encodes as explicit null.
public struct SourceDescriptor: Codable, Sendable, Equatable {
    public let version: Int
    public let title: String
    public let type: String
    public let pageCount: Int
    public let sheetCount: Int
    public let sizeBytes: Int64
    public let lang: String?

    public init(version: Int = 1, title: String, type: String, pageCount: Int, sheetCount: Int, sizeBytes: Int64, lang: String?) {
        self.version = version
        self.title = title
        self.type = type
        self.pageCount = pageCount
        self.sheetCount = sheetCount
        self.sizeBytes = sizeBytes
        self.lang = lang
    }

    /// Title preference: nonblank embedded title, first Markdown `# ` heading,
    /// then the filename without its extension.
    public static func make(document: CanonicalDocument, filename: String, sizeBytes: Int64, lang: String?) -> SourceDescriptor {
        SourceDescriptor(title: title(document: document, filename: filename), type: document.kind,
                         pageCount: document.pages.count, sheetCount: document.sheetNames.count,
                         sizeBytes: sizeBytes, lang: lang)
    }

    static func title(document: CanonicalDocument, filename: String) -> String {
        if let embedded = document.title?.trimmingCharacters(in: .whitespacesAndNewlines), !embedded.isEmpty {
            return embedded
        }
        if ["markdown", "md"].contains(document.kind) || filename.lowercased().hasSuffix(".md")
            || filename.lowercased().hasSuffix(".markdown") {
            for line in document.text.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("# ") {
                let heading = line.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
                if !heading.isEmpty { return heading }
            }
        }
        let name = filename.split(separator: "/").last.map(String.init) ?? filename
        let scalars = Array(name.unicodeScalars)
        if let dot = scalars.lastIndex(of: "."), dot > 0 {
            return String(String.UnicodeScalarView(scalars[..<dot]))
        }
        return name
    }

    private enum CodingKeys: String, CodingKey { case version, title, type, pageCount, sheetCount, sizeBytes, lang }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(title, forKey: .title)
        try container.encode(type, forKey: .type)
        try container.encode(pageCount, forKey: .pageCount)
        try container.encode(sheetCount, forKey: .sheetCount)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encode(lang, forKey: .lang) // explicit null, never omitted
    }

    /// Sorted-key compact JSON, byte-stable across runs.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// `{version:1,langCoverageBp,sharesBp,unknownShareBp}` for a completed document detection.
enum LanguageCoverageJSON {
    static func make(_ result: LanguageAggregate) throws -> String {
        let value: [String: Any] = ["version": 1, "langCoverageBp": result.langCoverageBp,
                                    "sharesBp": result.sharesBp, "unknownShareBp": result.unknownShareBp]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
                      as: UTF8.self)
    }
}

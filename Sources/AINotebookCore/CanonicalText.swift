import Foundation

/// Assembles unchanged canonical Unicode scalars, including every separator.
public enum CanonicalText {
    public static func assemble(kind: String, parts: [String], names: [String] = [], maxScalars: Int) throws -> CanonicalDocument {
        var builder = try CanonicalTextBuilder(maxScalars: maxScalars)
        var pages: [PageBoundary] = []
        switch kind {
        case "text", "txt", "markdown", "md", "note", "web":
            for part in parts { try builder.append(part) }
        case "pdf":
            for (index, part) in parts.enumerated() {
                if index > 0 { try builder.append("\n\n") }
                let start = builder.count
                try builder.append(part)
                pages.append(PageBoundary(page: index + 1, start: start, end: builder.count))
            }
        case "docx":
            for (index, part) in parts.enumerated() {
                if index > 0 { try builder.append("\n") }
                try builder.append(part)
            }
        case "pptx":
            for (index, part) in parts.enumerated() {
                if index > 0 { try builder.append("\n\n") }
                try builder.append("## Slide \(index + 1)\n")
                try builder.append(part)
            }
        case "xlsx":
            guard names.count == parts.count else { throw IngestionError(code: "invalidRelationship") }
            for (index, part) in parts.enumerated() {
                if index > 0 { try builder.append("\n\n") }
                try builder.append("## ")
                try builder.append(names[index])
                try builder.append("\n")
                try builder.append(part)
            }
        default:
            throw IngestionError(code: "unsupportedSyntax")
        }
        return CanonicalDocument(text: builder.text, title: nil, kind: kind, pages: pages,
                                 sheetNames: kind == "xlsx" ? names : [], encoding: nil)
    }
}

/// A reusable scalar bound for extractors; failed appends leave the buffer unchanged.
struct CanonicalTextBuilder {
    private(set) var text = ""
    private(set) var count = 0
    private let maxScalars: Int

    init(maxScalars: Int) throws {
        guard maxScalars >= 0 else { throw IngestionError(code: "textLimit") }
        self.maxScalars = maxScalars
    }

    mutating func append(_ value: String) throws {
        let remaining = maxScalars - count
        var added = 0
        for _ in value.unicodeScalars {
            guard added < remaining else { throw IngestionError(code: "textLimit") }
            added += 1
        }
        text.append(value)
        count += added
    }
}

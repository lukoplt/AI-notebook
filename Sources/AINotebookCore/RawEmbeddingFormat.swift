import Foundation

/// Raw (non-catalog) embedding input formats, contract embedding-raw-format-v2
/// (`docs/contracts/embedding-raw-format-v2.md`, fixture `embedding-raw-format-v2.json`).
/// `legacy` and `1` embed text verbatim; `2` adds the model family's task prefixes and, for
/// documents, a one-line path header. A generation's stored format decides how its queries
/// are embedded, so an older generation keeps working while a format-2 build replaces it.
public enum RawEmbeddingFormat {
    public static let current = "2"
    public static let headerMaxScalars = 200

    /// ASCII-lowercased model name without surrounding ASCII whitespace, namespace and tag.
    static func family(_ model: String) -> String {
        let ascii: Set<UInt32> = [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D]
        var scalars = Array(model.unicodeScalars)
        while let first = scalars.first, ascii.contains(first.value) { scalars.removeFirst() }
        while let last = scalars.last, ascii.contains(last.value) { scalars.removeLast() }
        let lowered = String(String.UnicodeScalarView(scalars.map {
            (0x41...0x5A).contains($0.value) ? UnicodeScalar($0.value + 32)! : $0
        }))
        let name = lowered.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? lowered
        return name.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
    }

    public static func prefixes(model: String) -> (query: String, document: String) {
        let name = family(model)
        if name.hasPrefix("nomic-embed-text") { return ("search_query: ", "search_document: ") }
        let parts = name.replacingOccurrences(of: "_", with: "-").split(separator: "-", omittingEmptySubsequences: false)
        if parts.contains("e5") && !name.contains("instruct") { return ("query: ", "passage: ") }
        return ("", "")
    }

    /// The source's folder-relative path (or title for a loose source) as one line: runs of
    /// ASCII whitespace become one space, ends trimmed, at most 200 scalars, then "\n".
    public static func header(relPath: String?, title: String) -> String {
        let line = (relPath?.isEmpty == false ? relPath! : title)
        let ascii: Set<UInt32> = [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D]
        var words: [String] = [], current = String.UnicodeScalarView()
        for scalar in line.unicodeScalars {
            if ascii.contains(scalar.value) {
                if !current.isEmpty { words.append(String(current)); current = String.UnicodeScalarView() }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { words.append(String(current)) }
        let joined = words.joined(separator: " ")
        guard !joined.isEmpty else { return "" }
        return String(String.UnicodeScalarView(joined.unicodeScalars.prefix(headerMaxScalars))) + "\n"
    }

    public static func query(_ text: String, model: String, format: String) -> String {
        format == "2" ? prefixes(model: model).query + text : text
    }

    /// `headed` is the chunk text already preceded by its `header` (the indexer adds it).
    public static func document(_ headed: String, model: String, format: String) -> String {
        format == "2" ? prefixes(model: model).document + headed : headed
    }
}

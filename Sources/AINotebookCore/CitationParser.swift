import Foundation

public enum CitationParser {

    private static let pattern = #"\[(\d+)\]"#

    public static func markers(in text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var results: [Int] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            let numRange = m.range(at: 1)
            let raw = ns.substring(with: numRange)
            if let n = Int(raw), n > 0 {
                results.append(n)
            }
        }
        return results
    }
}

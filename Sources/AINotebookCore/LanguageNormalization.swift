import Foundation

struct LanguageWords: Codable, Equatable, Sendable {
    let words: [String]
    let wordScalars: [[UInt32]]
    let boundaryWords: [[Int32]]
    let letterCount: Int64
    let wordCount: Int64
}

enum LanguageNormalization {
    /// Decode before applying the scalar cap. Each unmatched surrogate consumes
    /// exactly one UTF-16 unit and contributes one replacement scalar.
    static func decode(_ units: [UInt16], cap: Int) -> [UInt32] {
        precondition(cap >= 0)
        var scalars: [UInt32] = []
        scalars.reserveCapacity(min(units.count, cap))
        var index = 0
        while index < units.count && scalars.count < cap {
            let first = UInt32(units[index])
            if (0xD800...0xDBFF).contains(first), index + 1 < units.count,
               (0xDC00...0xDFFF).contains(UInt32(units[index + 1])) {
                scalars.append(0x10000 + (first - 0xD800) * 1024
                    + UInt32(units[index + 1]) - 0xDC00)
                index += 2
            } else {
                scalars.append((0xD800...0xDFFF).contains(first) ? 0xFFFD : first)
                index += 1
            }
        }
        return scalars
    }

    static func stream(_ text: String, tables: UnicodeTables, cap: Int) -> [UInt32] {
        precondition(cap >= 0)
        return normalize(text.unicodeScalars.prefix(cap).map(\.value), tables: tables, cap: cap)
    }

    static func stream(utf16Units: [UInt16], tables: UnicodeTables, cap: Int) -> [UInt32] {
        normalize(decode(utf16Units, cap: cap), tables: tables, cap: cap)
    }

    private static func normalize(_ scalars: [UInt32], tables: UnicodeTables, cap: Int) -> [UInt32] {
        // Intermediate expansions are not capped: final NFC must see the entire
        // retained input before the second input cap is applied.
        Array(tables.nfc(tables.fullCaseFold(tables.nfc(scalars))).prefix(cap))
    }

    static func classify(_ scalars: [UInt32], tables: UnicodeTables) -> LanguageWords {
        var words: [String] = []
        var wordScalars: [[UInt32]] = []
        var boundaryWords: [[Int32]] = []
        var active: [UInt32] = []
        var letterCount: Int64 = 0

        func flush() {
            guard !active.isEmpty else { return }
            words.append(String(decoding: active, as: UTF32.self))
            wordScalars.append(active)
            boundaryWords.append([Int32(-1)] + active.map(Int32.init) + [Int32(-2)])
            active.removeAll(keepingCapacity: true)
        }

        for scalar in scalars {
            switch tables.generalCategory(scalar) {
            case "Lu", "Ll", "Lt", "Lm", "Lo":
                active.append(scalar)
                letterCount += 1
            case "Mn", "Mc", "Me":
                if !active.isEmpty { active.append(scalar) }
            default:
                flush()
            }
        }
        flush()
        return LanguageWords(words: words, wordScalars: wordScalars, boundaryWords: boundaryWords,
                             letterCount: letterCount, wordCount: Int64(words.count))
    }
}

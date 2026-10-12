import Foundation

/// Text primitives of the bounded e-mail readers (contract `ingestion-mail-v1`,
/// reference `tools/contracts/gen_mail_fixtures.py`, same rules as Windows
/// `MailText`). Decoding never fails: unknown or invalid input degrades to a
/// fallback single-byte codec or U+FFFD, never to an error.
enum MailText {
    typealias Scalars = [Unicode.Scalar]

    static func isWhite(_ scalar: Unicode.Scalar) -> Bool { ScalarChunker.isWhitespace(scalar.value) }

    /// Whitespace runs become one U+0020; leading/trailing whitespace is removed.
    static func collapse(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var pending = false
        for scalar in text.unicodeScalars {
            if isWhite(scalar) {
                pending = !out.isEmpty
                continue
            }
            if pending {
                out.append(" ")
                pending = false
            }
            out.append(scalar)
        }
        return String(out)
    }

    static func trim(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var lo = 0, hi = scalars.count
        while lo < hi, isWhite(scalars[lo]) { lo += 1 }
        while hi > lo, isWhite(scalars[hi - 1]) { hi -= 1 }
        return lo == 0 && hi == scalars.count ? text : String(String.UnicodeScalarView(scalars[lo..<hi]))
    }

    /// CRLF and lone CR become LF.
    static func normalizeNewlines(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" {
                out.append("\n")
                previousCR = true
                continue
            }
            if scalar == "\n" && previousCR {
                previousCR = false
                continue
            }
            previousCR = false
            out.append(scalar)
        }
        return String(out)
    }

    static func asciiLower(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            out.append((65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar)
        }
        return String(out)
    }

    static func asciiUpper(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            out.append((97...122).contains(scalar.value) ? Unicode.Scalar(scalar.value - 32)! : scalar)
        }
        return String(out)
    }

    // MARK: Charsets

    private static let labels: [String: String] = [
        "utf-8": "utf-8", "utf8": "utf-8", "us-ascii": "utf-8", "ascii": "utf-8", "ansi_x3.4-1968": "utf-8",
        "iso-8859-1": "windows-1252", "iso8859-1": "windows-1252", "latin1": "windows-1252", "l1": "windows-1252",
        "windows-1252": "windows-1252", "cp1252": "windows-1252",
        "iso-8859-2": "iso-8859-2", "iso8859-2": "iso-8859-2", "latin2": "iso-8859-2", "l2": "iso-8859-2",
        "windows-1250": "windows-1250", "cp1250": "windows-1250", "x-cp1250": "windows-1250",
    ]

    /// MAPI code page -> codec.
    static func codec(codePage: UInt32) -> String {
        switch codePage {
        case 1250: return "windows-1250"
        case 1252, 28591: return "windows-1252"
        case 28592: return "iso-8859-2"
        case 65001, 20127: return "utf-8"
        default: return "auto"
        }
    }

    /// ASCII-lowercased label without surrounding whitespace/quotes -> codec, else "auto".
    static func codec(label: String) -> String {
        let scalars = Array(asciiLower(label).unicodeScalars)
        let strip: Set<UInt32> = [0x20, 0x09, 0x0D, 0x0A, 0x22, 0x27]
        var lo = 0, hi = scalars.count
        while lo < hi, strip.contains(scalars[lo].value) { lo += 1 }
        while hi > lo, strip.contains(scalars[hi - 1].value) { hi -= 1 }
        return labels[String(String.UnicodeScalarView(scalars[lo..<hi]))] ?? "auto"
    }

    /// `codec`: utf-8, windows-1250, windows-1252, iso-8859-2 or auto. Invalid
    /// UTF-8 falls back to windows-1250 (folder fallback cp1250) or windows-1252.
    static func decode(_ bytes: [UInt8], codec: String, fallback: String) -> String {
        if let table = table(codec) { return singleByte(bytes, table) }
        if let text = strictUTF8(bytes) { return text }
        return singleByte(bytes, fallback == "cp1250" ? windows1250 : windows1252)
    }

    private static func table(_ codec: String) -> [UInt16]? {
        switch codec {
        case "windows-1250": return windows1250
        case "windows-1252": return windows1252
        case "iso-8859-2": return iso88592
        default: return nil
        }
    }

    private static func singleByte(_ bytes: [UInt8], _ table: [UInt16]) -> String {
        var out = String.UnicodeScalarView()
        for byte in bytes {
            out.append(byte < 0x80 ? Unicode.Scalar(byte) : Unicode.Scalar(UInt32(table[Int(byte) - 0x80]))!)
        }
        return String(out)
    }

    /// Same strict rules as `TextDecoding`: no overlongs, surrogates or values above U+10FFFF.
    static func strictUTF8(_ bytes: [UInt8]) -> String? {
        var out = String.UnicodeScalarView()
        var i = 0
        let n = bytes.count
        while i < n {
            let first = bytes[i]
            if first < 0x80 {
                out.append(Unicode.Scalar(first))
                i += 1
                continue
            }
            let length: Int
            var value: UInt32
            switch first {
            case 0xC2...0xDF: length = 2; value = UInt32(first & 0x1F)
            case 0xE0...0xEF: length = 3; value = UInt32(first & 0x0F)
            case 0xF0...0xF4: length = 4; value = UInt32(first & 0x07)
            default: return nil
            }
            guard i + length <= n else { return nil }
            for k in 1..<length {
                let byte = bytes[i + k]
                guard (0x80...0xBF).contains(byte) else { return nil }
                value = value << 6 | UInt32(byte & 0x3F)
            }
            guard value >= [0, 0, 0x80, 0x800, 0x10000][length], value <= 0x10FFFF,
                  !(0xD800...0xDFFF).contains(value), let scalar = Unicode.Scalar(value) else { return nil }
            out.append(scalar)
            i += length
        }
        return String(out)
    }

    /// UTF-16LE; unpaired surrogates and an odd trailing byte become U+FFFD.
    static func utf16LE(_ bytes: [UInt8]) -> String {
        var out = String.UnicodeScalarView()
        let n = bytes.count - bytes.count % 2
        var i = 0
        while i < n {
            let unit = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8
            i += 2
            if (0xD800...0xDBFF).contains(unit), i < n {
                let low = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8
                if (0xDC00...0xDFFF).contains(low) {
                    out.append(Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))!)
                    i += 2
                    continue
                }
            }
            out.append((0xD800...0xDFFF).contains(unit) ? "\u{FFFD}" : Unicode.Scalar(unit)!)
        }
        if bytes.count % 2 == 1 { out.append("\u{FFFD}") }
        return String(out)
    }

    // MARK: Transfer encodings

    private static let base64Values: [Int8] = {
        var table = [Int8](repeating: -1, count: 256)
        for (index, byte) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
            table[Int(byte)] = Int8(index)
        }
        return table
    }()

    static func base64Value(_ byte: UInt8) -> Int? {
        let value = base64Values[Int(byte)]
        return value < 0 ? nil : Int(value)
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x37
        case 0x61...0x66: return byte - 0x57
        default: return nil
        }
    }

    /// Every non-alphabet byte (whitespace, '=', junk) is ignored; a trailing single sextet is dropped.
    static func base64Lenient<C: Collection>(_ data: C) -> [UInt8] where C.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(data.count / 4 * 3 + 2)
        var buffer: UInt32 = 0
        var count = 0
        for byte in data {
            guard let value = base64Value(byte) else { continue }
            buffer = buffer << 6 | UInt32(value)
            count += 1
            if count == 4 {
                out.append(UInt8(buffer >> 16 & 0xFF))
                out.append(UInt8(buffer >> 8 & 0xFF))
                out.append(UInt8(buffer & 0xFF))
                buffer = 0
                count = 0
            }
        }
        if count == 2 {
            out.append(UInt8(buffer >> 4 & 0xFF))
        } else if count == 3 {
            out.append(UInt8(buffer >> 10 & 0xFF))
            out.append(UInt8(buffer >> 2 & 0xFF))
        }
        return out
    }

    static func quotedPrintable<C: RandomAccessCollection>(_ data: C) -> [UInt8] where C.Element == UInt8, C.Index == Int {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        let base = data.startIndex
        let n = data.count
        func at(_ k: Int) -> UInt8 { data[base + k] }
        var i = 0
        while i < n {
            let byte = at(i)
            guard byte == 0x3D else {
                out.append(byte)
                i += 1
                continue
            }
            var j = i + 1
            while j < n, at(j) == 0x20 || at(j) == 0x09 { j += 1 }
            if j < n, at(j) == 0x0A { i = j + 1; continue }
            if j + 1 < n, at(j) == 0x0D, at(j + 1) == 0x0A { i = j + 2; continue }
            if j == n { i = n; continue }
            if i + 2 < n, let high = hexValue(at(i + 1)), let low = hexValue(at(i + 2)) {
                out.append(high << 4 | low)
                i += 3
                continue
            }
            out.append(byte)
            i += 1
        }
        return out
    }

    // MARK: RFC 2047 encoded words

    private static func encodedWord(_ text: Scalars, _ i: Int) -> (end: Int, label: String, bytes: [UInt8])? {
        let n = text.count
        guard i + 1 < n, text[i] == "=", text[i + 1] == "?" else { return nil }
        let j = i + 2
        var k = j
        while k < n, text[k] != "?", !isWhite(text[k]) { k += 1 }
        guard k > j, k < n, text[k] == "?" else { return nil }
        var labelScalars = String.UnicodeScalarView()
        for scalar in text[j..<k] {
            if scalar == "*" { break }
            labelScalars.append(scalar)
        }
        let label = asciiLower(String(labelScalars))
        guard k + 2 < n, text[k + 2] == "?", ["b", "B", "q", "Q"].contains(text[k + 1]) else { return nil }
        let mode = text[k + 1] == "b" || text[k + 1] == "B" ? "B" : "Q"
        let p = k + 3
        var q = p
        while q < n, text[q] != "?", !isWhite(text[q]) { q += 1 }
        guard q + 1 < n, text[q] == "?", text[q + 1] == "=" else { return nil }
        var raw: [UInt8] = []
        for scalar in text[p..<q] {
            guard (0x21...0x7E).contains(scalar.value) else { return nil }
            raw.append(UInt8(scalar.value))
        }
        var data: [UInt8] = []
        if mode == "B" {
            var body = raw[...]
            while body.last == 0x3D { body = body.dropLast() }
            guard body.allSatisfy({ base64Value($0) != nil }), body.count % 4 != 1 else { return nil }
            data = base64Lenient(body)
        } else {
            var m = 0
            while m < raw.count {
                let c = raw[m]
                if c == 0x5F {
                    data.append(0x20)
                    m += 1
                } else if c == 0x3D {
                    guard m + 2 < raw.count, let high = hexValue(raw[m + 1]), let low = hexValue(raw[m + 2]) else { return nil }
                    data.append(high << 4 | low)
                    m += 3
                } else {
                    data.append(c)
                    m += 1
                }
            }
        }
        return (q + 2, label, data)
    }

    /// Encoded words decoded; whitespace between adjacent words dropped; adjacent
    /// words with the same (lowercased) label concatenate bytes before decoding.
    static func decodeWords(_ value: String, fallback: String) -> String {
        let text = Array(value.unicodeScalars)
        var out = String.UnicodeScalarView()
        var pendingLabel: String?
        var pendingBytes: [UInt8] = []
        var gapStart = 0
        func flush() {
            out.append(contentsOf: decode(pendingBytes, codec: codec(label: pendingLabel!), fallback: fallback).unicodeScalars)
            pendingLabel = nil
            pendingBytes.removeAll(keepingCapacity: true)
        }
        var i = 0
        while i < text.count {
            if text[i] == "=", let word = encodedWord(text, i) {
                if pendingLabel != word.label {
                    if pendingLabel != nil { flush() }
                    pendingLabel = word.label
                }
                pendingBytes.append(contentsOf: word.bytes)
                i = word.end
                gapStart = i
                continue
            }
            if pendingLabel != nil, !isWhite(text[i]) {
                flush()
                out.append(contentsOf: text[gapStart..<i])
            }
            if pendingLabel == nil { out.append(text[i]) }
            i += 1
        }
        if pendingLabel != nil {
            flush()
            out.append(contentsOf: text[gapStart..<text.count])
        }
        return String(out)
    }

    static func decodeHeader(_ value: String, fallback: String) -> String {
        collapse(decodeWords(value, fallback: fallback))
    }

    // MARK: Parameters (RFC 2045 / RFC 2231)

    /// `type/sub; a=b; c="q\"x"` -> (lowercased type, lowercased name -> value; first wins).
    static func parameters(_ value: String) -> (kind: String, params: [String: String]) {
        var segments: [String] = []
        var current = String.UnicodeScalarView()
        var quoted = false, escape = false
        for scalar in value.unicodeScalars {
            if escape {
                current.append(scalar)
                escape = false
            } else if quoted && scalar == "\\" {
                current.append(scalar)
                escape = true
            } else if scalar == "\"" {
                current.append(scalar)
                quoted.toggle()
            } else if scalar == ";" && !quoted {
                segments.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        segments.append(String(current))
        let kind = asciiLower(trim(segments[0]))
        var params: [String: String] = [:]
        for segment in segments.dropFirst() {
            let scalars = Array(segment.unicodeScalars)
            guard let equals = scalars.firstIndex(of: "=") else { continue }
            let name = asciiLower(trim(String(String.UnicodeScalarView(scalars[..<equals]))))
            var raw = Array(trim(String(String.UnicodeScalarView(scalars[(equals + 1)...]))).unicodeScalars)
            if raw.count >= 2, raw.first == "\"", raw.last == "\"" {
                let inner = Array(raw[1..<(raw.count - 1)])
                var unquoted: [Unicode.Scalar] = []
                var k = 0
                while k < inner.count {
                    if inner[k] == "\\", k + 1 < inner.count {
                        unquoted.append(inner[k + 1])
                        k += 2
                    } else {
                        unquoted.append(inner[k])
                        k += 1
                    }
                }
                raw = unquoted
            }
            if !name.isEmpty, params[name] == nil { params[name] = String(String.UnicodeScalarView(raw)) }
        }
        return (kind, params)
    }

    private static func percentDecoded(_ text: String) -> [UInt8] {
        let raw = Array(text.utf8)
        var out: [UInt8] = []
        var k = 0
        while k < raw.count {
            if raw[k] == 0x25, k + 2 < raw.count, let high = hexValue(raw[k + 1]), let low = hexValue(raw[k + 2]) {
                out.append(high << 4 | low)
                k += 3
            } else {
                out.append(raw[k])
                k += 1
            }
        }
        return out
    }

    /// RFC 2231 extended value or numbered continuations (max 100), else the plain value (encoded words allowed).
    static func parameter(_ params: [String: String], _ name: String, fallback: String) -> String {
        if let value = params[name + "*"] { return collapse(extended([(value, true)], fallback: fallback)) }
        var segments: [(String, Bool)] = []
        for index in 0..<100 {
            if let value = params["\(name)*\(index)*"] { segments.append((value, true)) }
            else if let value = params["\(name)*\(index)"] { segments.append((value, false)) }
            else { break }
        }
        if !segments.isEmpty { return collapse(extended(segments, fallback: fallback)) }
        if let value = params[name] { return decodeHeader(value, fallback: fallback) }
        return ""
    }

    private static func extended(_ segments: [(String, Bool)], fallback: String) -> String {
        var codecName = "auto"
        var data: [UInt8] = []
        for (index, (value, isExtended)) in segments.enumerated() {
            if isExtended {
                var payload = value
                let scalars = Array(value.unicodeScalars)
                if index == 0, scalars.filter({ $0 == "'" }).count >= 2 {
                    let first = scalars.firstIndex(of: "'")!
                    let second = scalars[(first + 1)...].firstIndex(of: "'")!
                    codecName = codec(label: String(String.UnicodeScalarView(scalars[..<first])))
                    payload = String(String.UnicodeScalarView(scalars[(second + 1)...]))
                }
                data += percentDecoded(payload)
            } else {
                data += Array(value.utf8)
            }
        }
        return decode(data, codec: codecName, fallback: fallback)
    }

    // MARK: HTML -> text

    private static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "dd", "div", "dl", "dt", "fieldset", "figure",
        "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p",
        "pre", "section", "table", "tr", "ul"]
    private static let skippedElements: Set<String> = ["head", "script", "style", "title"]
    private static let entities: [String: Unicode.Scalar] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"",
                                                             "apos": "'", "nbsp": "\u{00A0}"]

    private static func isLetter(_ s: Unicode.Scalar) -> Bool { (65...90).contains(s.value) || (97...122).contains(s.value) }
    private static func isAlnum(_ s: Unicode.Scalar) -> Bool { isLetter(s) || (48...57).contains(s.value) }

    private static func find(_ html: Scalars, _ needle: String, from start: Int, foldCase: Bool = false) -> Int? {
        let pattern = Array(needle.unicodeScalars)
        guard start <= html.count, pattern.count <= html.count else { return nil }
        var index = start
        while index + pattern.count <= html.count {
            var matched = true
            for (offset, expected) in pattern.enumerated() {
                var actual = html[index + offset]
                if foldCase, (65...90).contains(actual.value) { actual = Unicode.Scalar(actual.value + 32)! }
                if actual != expected { matched = false; break }
            }
            if matched { return index }
            index += 1
        }
        return nil
    }

    /// Tags removed; head/script/style/title content skipped; block elements
    /// start a line, `<br>` breaks (at most one blank line); whitespace collapsed;
    /// the six basic named and all numeric character references decoded.
    static func htmlToText(_ value: String) -> String {
        let html = Array(value.unicodeScalars)
        let n = html.count
        var out = String.UnicodeScalarView()
        var pending = false, newlines = 0, atStart = true

        func text(_ scalar: Unicode.Scalar) {
            if isWhite(scalar) { pending = true; return }
            if pending && !atStart && newlines == 0 { out.append(" ") }
            pending = false
            newlines = 0
            atStart = false
            out.append(scalar)
        }
        func line(hard: Bool) {
            pending = false
            if atStart { return }
            if hard {
                if newlines < 2 { out.append("\n"); newlines += 1 }
            } else if newlines == 0 {
                out.append("\n")
                newlines = 1
            }
        }

        var i = 0
        while i < n {
            let scalar = html[i]
            if scalar == "<" {
                if i + 3 < n, html[i + 1] == "!", html[i + 2] == "-", html[i + 3] == "-" {
                    i = find(html, "-->", from: i + 4).map { $0 + 3 } ?? n
                    continue
                }
                if i + 1 < n, html[i + 1] == "!" || html[i + 1] == "?" {
                    i = find(html, ">", from: i + 2).map { $0 + 1 } ?? n
                    continue
                }
                var j = i + 1
                let closing = j < n && html[j] == "/"
                if closing { j += 1 }
                var k = j
                while k < n, isAlnum(html[k]) { k += 1 }
                if k == j || !isLetter(html[j]) {
                    text(scalar)
                    i += 1
                    continue
                }
                let name = asciiLower(String(String.UnicodeScalarView(html[j..<k])))
                var quote: Unicode.Scalar?
                while k < n {
                    let c = html[k]
                    if let open = quote {
                        if c == open { quote = nil }
                    } else if c == "\"" || c == "'" {
                        quote = c
                    } else if c == ">" {
                        break
                    }
                    k += 1
                }
                i = k + 1
                if !closing, skippedElements.contains(name) {
                    if let end = find(html, "</" + name, from: min(i, n), foldCase: true) {
                        i = find(html, ">", from: end).map { $0 + 1 } ?? n
                    } else {
                        i = n
                    }
                    continue
                }
                if name == "br" { line(hard: true) }
                else if blockElements.contains(name) { line(hard: false) }
                else if name == "td" || name == "th" { pending = true }
                continue
            }
            if scalar == "&", let end = (i + 1..<min(i + 12, n)).first(where: { html[$0] == ";" }), end > i + 1 {
                let reference = Array(html[(i + 1)..<end])
                var decoded: Unicode.Scalar?
                if reference[0] == "#" {
                    var digits = Array(reference.dropFirst())
                    var radix = 10
                    if let first = digits.first, first == "x" || first == "X" {
                        digits.removeFirst()
                        radix = 16
                    }
                    let allowed = digits.allSatisfy { radix == 16 ? hexValue(UInt8(truncatingIfNeeded: $0.value)) != nil && $0.value < 128
                                                                   : (48...57).contains($0.value) }
                    if (1...8).contains(digits.count), allowed,
                       let code = UInt32(String(String.UnicodeScalarView(digits)), radix: radix) {
                        decoded = code == 0 || (0xD800...0xDFFF).contains(code) || code > 0x10FFFF
                            ? "\u{FFFD}" : Unicode.Scalar(code)
                    }
                } else {
                    decoded = entities[String(String.UnicodeScalarView(reference))]
                }
                if let decoded {
                    text(decoded)
                    i = end + 1
                    continue
                }
            }
            text(scalar)
            i += 1
        }
        while out.last == "\n" { out.removeLast() }
        return String(out)
    }

    // MARK: Tables (bytes 0x80...0xFF; undefined positions are U+FFFD)

    static let windows1250: [UInt16] = [
        0x20AC, 0xFFFD, 0x201A, 0xFFFD, 0x201E, 0x2026, 0x2020, 0x2021, 0xFFFD, 0x2030, 0x0160, 0x2039, 0x015A, 0x0164, 0x017D, 0x0179,
        0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0xFFFD, 0x2122, 0x0161, 0x203A, 0x015B, 0x0165, 0x017E, 0x017A,
        0x00A0, 0x02C7, 0x02D8, 0x0141, 0x00A4, 0x0104, 0x00A6, 0x00A7, 0x00A8, 0x00A9, 0x015E, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x017B,
        0x00B0, 0x00B1, 0x02DB, 0x0142, 0x00B4, 0x00B5, 0x00B6, 0x00B7, 0x00B8, 0x0105, 0x015F, 0x00BB, 0x013D, 0x02DD, 0x013E, 0x017C,
        0x0154, 0x00C1, 0x00C2, 0x0102, 0x00C4, 0x0139, 0x0106, 0x00C7, 0x010C, 0x00C9, 0x0118, 0x00CB, 0x011A, 0x00CD, 0x00CE, 0x010E,
        0x0110, 0x0143, 0x0147, 0x00D3, 0x00D4, 0x0150, 0x00D6, 0x00D7, 0x0158, 0x016E, 0x00DA, 0x0170, 0x00DC, 0x00DD, 0x0162, 0x00DF,
        0x0155, 0x00E1, 0x00E2, 0x0103, 0x00E4, 0x013A, 0x0107, 0x00E7, 0x010D, 0x00E9, 0x0119, 0x00EB, 0x011B, 0x00ED, 0x00EE, 0x010F,
        0x0111, 0x0144, 0x0148, 0x00F3, 0x00F4, 0x0151, 0x00F6, 0x00F7, 0x0159, 0x016F, 0x00FA, 0x0171, 0x00FC, 0x00FD, 0x0163, 0x02D9]

    static let windows1252: [UInt16] = [
        0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
        0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
        0x00A0, 0x00A1, 0x00A2, 0x00A3, 0x00A4, 0x00A5, 0x00A6, 0x00A7, 0x00A8, 0x00A9, 0x00AA, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x00AF,
        0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B6, 0x00B7, 0x00B8, 0x00B9, 0x00BA, 0x00BB, 0x00BC, 0x00BD, 0x00BE, 0x00BF,
        0x00C0, 0x00C1, 0x00C2, 0x00C3, 0x00C4, 0x00C5, 0x00C6, 0x00C7, 0x00C8, 0x00C9, 0x00CA, 0x00CB, 0x00CC, 0x00CD, 0x00CE, 0x00CF,
        0x00D0, 0x00D1, 0x00D2, 0x00D3, 0x00D4, 0x00D5, 0x00D6, 0x00D7, 0x00D8, 0x00D9, 0x00DA, 0x00DB, 0x00DC, 0x00DD, 0x00DE, 0x00DF,
        0x00E0, 0x00E1, 0x00E2, 0x00E3, 0x00E4, 0x00E5, 0x00E6, 0x00E7, 0x00E8, 0x00E9, 0x00EA, 0x00EB, 0x00EC, 0x00ED, 0x00EE, 0x00EF,
        0x00F0, 0x00F1, 0x00F2, 0x00F3, 0x00F4, 0x00F5, 0x00F6, 0x00F7, 0x00F8, 0x00F9, 0x00FA, 0x00FB, 0x00FC, 0x00FD, 0x00FE, 0x00FF]

    static let iso88592: [UInt16] = [
        0x0080, 0x0081, 0x0082, 0x0083, 0x0084, 0x0085, 0x0086, 0x0087, 0x0088, 0x0089, 0x008A, 0x008B, 0x008C, 0x008D, 0x008E, 0x008F,
        0x0090, 0x0091, 0x0092, 0x0093, 0x0094, 0x0095, 0x0096, 0x0097, 0x0098, 0x0099, 0x009A, 0x009B, 0x009C, 0x009D, 0x009E, 0x009F,
        0x00A0, 0x0104, 0x02D8, 0x0141, 0x00A4, 0x013D, 0x015A, 0x00A7, 0x00A8, 0x0160, 0x015E, 0x0164, 0x0179, 0x00AD, 0x017D, 0x017B,
        0x00B0, 0x0105, 0x02DB, 0x0142, 0x00B4, 0x013E, 0x015B, 0x02C7, 0x00B8, 0x0161, 0x015F, 0x0165, 0x017A, 0x02DD, 0x017E, 0x017C,
        0x0154, 0x00C1, 0x00C2, 0x0102, 0x00C4, 0x0139, 0x0106, 0x00C7, 0x010C, 0x00C9, 0x0118, 0x00CB, 0x011A, 0x00CD, 0x00CE, 0x010E,
        0x0110, 0x0143, 0x0147, 0x00D3, 0x00D4, 0x0150, 0x00D6, 0x00D7, 0x0158, 0x016E, 0x00DA, 0x0170, 0x00DC, 0x00DD, 0x0162, 0x00DF,
        0x0155, 0x00E1, 0x00E2, 0x0103, 0x00E4, 0x013A, 0x0107, 0x00E7, 0x010D, 0x00E9, 0x0119, 0x00EB, 0x011B, 0x00ED, 0x00EE, 0x010F,
        0x0111, 0x0144, 0x0148, 0x00F3, 0x00F4, 0x0151, 0x00F6, 0x00F7, 0x0159, 0x016F, 0x00FA, 0x0171, 0x00FC, 0x00FD, 0x0163, 0x02D9]
}

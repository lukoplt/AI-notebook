import Foundation

/// Strict, integer-only JSON for the detector's artifact and provenance formats.
/// Run before Foundation decoding, which otherwise tolerates duplicate keys and
/// exponent/fraction spellings of integer values.
enum LanguageJSON {
    enum Invalid: Error { case data(String) }

    indirect enum Value: Equatable, Sendable {
        case object([String: Value]), array([Value]), string(String), integer(Int64), bool(Bool), null

        func checkKeys(_ keys: [String]) throws {
            guard case let .object(fields) = self, Set(fields.keys) == Set(keys) else {
                throw Invalid.data("unexpected object keys")
            }
        }
        func field(_ key: String) throws -> Value {
            guard case let .object(fields) = self, let value = fields[key] else {
                throw Invalid.data("missing field: \(key)")
            }
            return value
        }
        func array() throws -> [Value] {
            guard case let .array(values) = self else { throw Invalid.data("expected array") }
            return values
        }
        func string() throws -> String {
            guard case let .string(value) = self else { throw Invalid.data("expected string") }
            return value
        }
        func integer() throws -> Int64 {
            guard case let .integer(value) = self else { throw Invalid.data("expected integer") }
            return value
        }
    }

    static func validate(_ data: Data) throws { _ = try parse(data) }
    static func parse(_ data: Data) throws -> Value {
        guard data.last == 10, !data.starts(with: [0xEF, 0xBB, 0xBF]),
              String(data: data, encoding: .utf8) != nil else { throw Invalid.data("expected UTF-8, no BOM, final LF") }
        var scanner = Scanner(bytes: Array(data))
        let value = try scanner.value(depth: 0)
        scanner.whitespace()
        guard scanner.index == scanner.bytes.count, case .object = value else { throw Invalid.data("expected one object") }
        return value
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func whitespace() {
            while let c = peek, c == 32 || c == 9 || c == 10 || c == 13 { index += 1 }
        }
        mutating func take(_ c: UInt8) throws {
            guard peek == c else { throw Invalid.data("unexpected token") }
            index += 1
        }
        mutating func literal(_ text: String) throws {
            for c in text.utf8 { try take(c) }
        }
        mutating func value(depth: Int) throws -> Value {
            whitespace()
            guard let c = peek else { throw Invalid.data("missing value") }
            switch c {
            case 123:
                guard depth < 64 else { throw Invalid.data("maximum depth exceeded") }
                index += 1
                whitespace()
                var fields: [String: Value] = [:]
                var keys = Set<[UInt8]>()
                if peek == 125 { index += 1; return .object(fields) }
                while true {
                    whitespace()
                    let key = try string()
                    // Every artifact/manifest property name is ASCII. Swift's
                    // String dictionaries compare canonical equivalents, so an
                    // unknown Kelvin-sign spelling must never alias an ASCII K.
                    guard key.utf8.allSatisfy({ $0 < 128 }) else { throw Invalid.data("non-ASCII schema key") }
                    guard keys.insert(Array(key.utf8)).inserted else { throw Invalid.data("duplicate key") }
                    whitespace()
                    try take(58)
                    fields[key] = try value(depth: depth + 1)
                    whitespace()
                    if peek == 125 { index += 1; return .object(fields) }
                    try take(44)
                }
            case 91:
                guard depth < 64 else { throw Invalid.data("maximum depth exceeded") }
                index += 1
                whitespace()
                var values: [Value] = []
                if peek == 93 { index += 1; return .array(values) }
                while true {
                    values.append(try value(depth: depth + 1))
                    whitespace()
                    if peek == 93 { index += 1; return .array(values) }
                    try take(44)
                }
            case 34: return .string(try string())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            case 45, 48...57:
                let start = index
                if peek == 45 { index += 1 }
                if peek == 48 { index += 1 }
                else {
                    guard let first = peek, (49...57).contains(first) else { throw Invalid.data("invalid integer") }
                    while let digit = peek, (48...57).contains(digit) { index += 1 }
                }
                guard let result = Int64(String(decoding: bytes[start..<index], as: UTF8.self)) else {
                    throw Invalid.data("integer overflow")
                }
                return .integer(result)
            default: throw Invalid.data("invalid token")
            }
        }
        mutating func hexUnit() throws -> UInt32 {
            var result: UInt32 = 0
            for _ in 0..<4 {
                guard let c = peek else { throw Invalid.data("incomplete escape") }
                let digit: UInt32
                switch c {
                case 48...57: digit = UInt32(c - 48)
                case 65...70: digit = UInt32(c - 55)
                case 97...102: digit = UInt32(c - 87)
                default: throw Invalid.data("invalid hex escape")
                }
                result = result * 16 + digit
                index += 1
            }
            return result
        }
        mutating func string() throws -> String {
            try take(34)
            var result: [UInt8] = []
            while let c = peek {
                index += 1
                if c == 34 {
                    guard let text = String(bytes: result, encoding: .utf8) else { throw Invalid.data("invalid string") }
                    return text
                }
                guard c >= 32 else { throw Invalid.data("unescaped control") }
                if c != 92 { result.append(c); continue }
                guard let escape = peek else { throw Invalid.data("incomplete escape") }
                index += 1
                switch escape {
                case 34, 47, 92: result.append(escape)
                case 98: result.append(8)
                case 102: result.append(12)
                case 110: result.append(10)
                case 114: result.append(13)
                case 116: result.append(9)
                case 117:
                    var cp = try hexUnit()
                    if (0xD800...0xDBFF).contains(cp) {
                        try take(92)
                        try take(117)
                        let low = try hexUnit()
                        guard (0xDC00...0xDFFF).contains(low) else { throw Invalid.data("unpaired surrogate") }
                        cp = 0x10000 + (cp - 0xD800) * 1024 + low - 0xDC00
                    }
                    guard let scalar = Unicode.Scalar(cp) else { throw Invalid.data("unpaired surrogate") }
                    result.append(contentsOf: String(scalar).utf8)
                default: throw Invalid.data("invalid escape")
                }
            }
            throw Invalid.data("unterminated string")
        }
    }
}

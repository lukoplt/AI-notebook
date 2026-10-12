import Foundation

/// Compact spreadsheet canonical text, `text_format_version` 2 (contract
/// `ingestion-xlsx-v2`, same rules as Windows `SpreadsheetText`). Pure, locale
/// independent string arithmetic: no binary floating point, no formatters.
enum SpreadsheetText {
    /// `source_revisions.text_format_version` of every XLSX revision rendered by these rules.
    static let formatVersion = 2
    static let significantDigits = 15
    static let cellSeparator = " | "

    // MARK: Values (§3)

    /// Every maximal run of TAB/LF/CR/SPACE becomes one SPACE; SPACE is trimmed at both ends.
    static func normalize(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var pending = false
        for scalar in text.unicodeScalars {
            if isASCIIWhitespace(scalar.value) { pending = true; continue }
            if pending, !output.isEmpty { output.append(" ") }
            pending = false
            output.append(scalar)
        }
        return String(output)
    }

    /// The `"<COL>="`-free column name of a 1-based column (1 → A, 27 → AA).
    static func columnName(_ column: Int) -> String {
        var value = column
        var scalars: [Unicode.Scalar] = []
        while value > 0 {
            let remainder = (value - 1) % 26
            scalars.append(Unicode.Scalar(UInt8(65 + remainder)))
            value = (value - 1) / 26
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars.reversed())
        return String(view)
    }

    // MARK: Numbers (§4)

    enum Decimal: Equatable {
        case zero
        /// value = 0.digits × 10^exponent; digits are ASCII, no leading/trailing zero, at most 15.
        case value(negative: Bool, digits: [UInt8], exponent: Int)
    }

    /// nil: not a numeric lexeme, or outside the representable exponent range.
    static func parse(_ raw: String) -> Decimal? {
        var bytes = Array(raw.utf8)
        while let first = bytes.first, isASCIIWhitespace(UInt32(first)) { bytes.removeFirst() }
        while let last = bytes.last, isASCIIWhitespace(UInt32(last)) { bytes.removeLast() }
        var index = 0
        var negative = false
        if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 {
            negative = bytes[index] == 45
            index += 1
        }
        var integer: [UInt8] = [], fraction: [UInt8] = []
        while index < bytes.count, isDigit(bytes[index]) { integer.append(bytes[index]); index += 1 }
        if index < bytes.count, bytes[index] == 46 {
            index += 1
            while index < bytes.count, isDigit(bytes[index]) { fraction.append(bytes[index]); index += 1 }
        }
        guard !integer.isEmpty || !fraction.isEmpty else { return nil }
        var exponent = 0
        if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
            index += 1
            var sign = 1
            if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 {
                sign = bytes[index] == 45 ? -1 : 1
                index += 1
            }
            var digits: [UInt8] = []
            while index < bytes.count, isDigit(bytes[index]) { digits.append(bytes[index]); index += 1 }
            guard !digits.isEmpty else { return nil }
            let significant = digits.drop { $0 == 48 }
            guard significant.count <= 5 else { return nil }
            exponent = sign * significant.reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        guard index == bytes.count else { return nil }
        var digits = integer + fraction
        var n = integer.count
        let leading = digits.prefix { $0 == 48 }.count
        digits.removeFirst(leading)
        n -= leading
        while digits.last == 48 { digits.removeLast() }
        guard !digits.isEmpty else { return .zero }
        n += exponent
        if digits.count > significantDigits {
            let roundUp = digits[significantDigits] >= 53
            digits = Array(digits.prefix(significantDigits))
            if roundUp {
                var position = digits.count - 1
                while position >= 0, digits[position] == 57 { digits[position] = 48; position -= 1 }
                if position < 0 {
                    digits.insert(49, at: 0)
                    n += 1
                    digits = Array(digits.prefix(significantDigits))
                } else {
                    digits[position] += 1
                }
            }
            while digits.last == 48 { digits.removeLast() }
        }
        guard (-400...400).contains(n) else { return nil }
        return .value(negative: negative, digits: digits, exponent: n)
    }

    /// The compact decimal text (ECMAScript Number::toString layout, uppercase `E`), or nil.
    static func number(_ raw: String) -> String? {
        guard let parsed = parse(raw) else { return nil }
        guard case let .value(negative, digits, n) = parsed else { return "0" }
        let d = String(decoding: digits, as: UTF8.self)
        let k = digits.count
        let body: String
        if k <= n, n <= 21 {
            body = d + String(repeating: "0", count: n - k)
        } else if 0 < n, n <= 21 {
            body = String(decoding: digits[..<n], as: UTF8.self) + "." + String(decoding: digits[n...], as: UTF8.self)
        } else if -6 < n, n <= 0 {
            body = "0." + String(repeating: "0", count: -n) + d
        } else {
            let e = n - 1
            let mantissa = k > 1 ? String(decoding: digits[..<1], as: UTF8.self) + "." + String(decoding: digits[1...], as: UTF8.self) : d
            body = mantissa + "E" + (e >= 0 ? "+" : "-") + String(abs(e))
        }
        return (negative ? "-" : "") + body
    }

    // MARK: Dates (§5)

    /// ISO date/time of a positive serial in the workbook's date system, or nil
    /// (the caller then renders the value as a number).
    static func date(_ raw: String, date1904: Bool) -> String? {
        guard case let .value(negative, digits, n)? = parse(raw), !negative, n <= 7 else { return nil }
        let integer: Int
        let fraction: [UInt8]
        if n <= 0 {
            integer = 0
            fraction = Array(repeating: 48, count: -n) + digits
        } else {
            let padded = digits + Array(repeating: 48, count: max(0, n - digits.count))
            integer = padded[..<n].reduce(0) { $0 * 10 + Int($1 - 48) }
            fraction = Array(padded[n...])
        }
        guard integer <= 3_000_000 else { return nil }
        var seconds = 0
        if !fraction.isEmpty, n > -6 {
            let f = fraction.reduce(0) { $0 * 10 + Int($1 - 48) }
            let m = fraction.count
            let numerator: Int, denominator: Int
            if m == 1 { (numerator, denominator) = (f * 86_400, 10) }
            else { (numerator, denominator) = (f * 864, power10(m - 2)) }
            seconds = numerator / denominator + (2 * (numerator % denominator) >= denominator ? 1 : 0)
        }
        let total = integer * 86_400 + seconds
        let day = total / 86_400, secondOfDay = total % 86_400
        let hours = secondOfDay / 3600, minutes = secondOfDay % 3600 / 60, rest = secondOfDay % 60
        let clock = pad(hours, 2) + ":" + pad(minutes, 2) + (rest > 0 ? ":" + pad(rest, 2) : "")
        if day == 0 { return clock }
        let civil: (year: Int, month: Int, day: Int)
        if date1904 { civil = civilFromDays(daysFromCivil(1904, 1, 1) + day) }
        else if day < 60 { civil = civilFromDays(daysFromCivil(1899, 12, 31) + day) }
        else if day == 60 { civil = (1900, 2, 29) }
        else { civil = civilFromDays(daysFromCivil(1899, 12, 30) + day) }
        guard civil.year <= 9999 else { return nil }
        let text = pad(civil.year, 4) + "-" + pad(civil.month, 2) + "-" + pad(civil.day, 2)
        return secondOfDay > 0 ? text + " " + clock : text
    }

    /// Days since 1970-01-01 (proleptic Gregorian; H. Hinnant's integer algorithm).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp + (mp < 10 ? 3 : -9)
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    // MARK: Number formats (§6)

    static func isBuiltInDate(_ id: Int) -> Bool {
        (14...22).contains(id) || (27...36).contains(id) || (45...47).contains(id) || (50...58).contains(id)
    }

    /// Ignores quoted/escaped literals and color/condition brackets; a bracket
    /// holding one repeated h, m or s (elapsed time) is a date/time token.
    /// Scientific `E` is deliberately not a date token.
    static func isDateFormat(_ code: String) -> Bool {
        let scalars = Array(code.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let value = scalars[index].value
            if value == 34 {
                index += 1
                while index < scalars.count, scalars[index].value != 34 { index += 1 }
            } else if value == 92 || value == 95 || value == 42 {
                index += 1
            } else if value == 91 {
                guard let end = scalars[(index + 1)...].firstIndex(where: { $0.value == 93 }) else { return false }
                let content = scalars[(index + 1)..<end].map { lower($0.value) }
                if let first = content.first, [104, 109, 115].contains(first), content.allSatisfy({ $0 == first }) { return true }
                index = end
            } else if [121, 109, 100, 104, 115].contains(lower(value)) {
                return true
            }
            index += 1
        }
        return false
    }

    // MARK: Rows (§2)

    /// One rendered, non-empty cell value.
    struct RenderedCell {
        let row: Int
        let column: Int
        let text: String
    }

    /// Appends the row lines of one sheet (cells sorted by row, then column):
    /// `R<row>: v1 | v2 | <COL>=v3`, where a column that does not directly
    /// follow the previous rendered cell of the row (or column A for the first
    /// one) is prefixed with its name.
    static func appendRows(_ cells: [RenderedCell], to output: inout CanonicalTextBuilder) throws {
        var currentRow: Int?
        var previousColumn = 0
        for cell in cells {
            if currentRow != cell.row {
                if currentRow != nil { try output.append("\n") }
                try output.append("R")
                try output.append(String(cell.row))
                try output.append(": ")
                currentRow = cell.row
                previousColumn = 0
            } else {
                try output.append(cellSeparator)
            }
            if cell.column != previousColumn + 1 {
                try output.append(columnName(cell.column))
                try output.append("=")
            }
            try output.append(cell.text)
            previousColumn = cell.column
        }
    }

    // MARK: Helpers

    private static func isASCIIWhitespace(_ value: UInt32) -> Bool { value == 9 || value == 10 || value == 13 || value == 32 }
    private static func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
    private static func lower(_ value: UInt32) -> UInt32 { (65...90).contains(value) ? value + 32 : value }
    private static func power10(_ exponent: Int) -> Int { (0..<exponent).reduce(1) { value, _ in value * 10 } }
    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}

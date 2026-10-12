import Foundation

/// Strict codecs preserve the original scalar stream, including whitespace.
public enum TextDecoding {
    public static func decode(_ bytes: Data, fallback: String, maxScalars: Int) throws -> DecodedText {
        var consumed = false
        return try decode(read: {
            guard !consumed else { return nil }
            consumed = true
            return bytes
        }, rewind: { consumed = false }, fallback: fallback, maxScalars: maxScalars)
    }

    /// The caller supplies bounded blocks and can reopen/rewind after invalid BOM-less UTF-8.
    /// A BOM commits to its codec; only BOM-less UTF-8 can fall back to Windows-1250.
    static func decode(read: () throws -> Data?, rewind: () throws -> Void,
                       fallback: String, maxScalars: Int) throws -> DecodedText {
        guard maxScalars >= 0 else { throw IngestionError(code: "textLimit") }
        guard fallback == "none" || fallback == "cp1250" else {
            throw IngestionError(code: "unsupportedEncoding")
        }
        return try withoutActuallyEscaping(read) { read in
            let input = Bytes(read: read)
            var prefix: [UInt8] = []
            for _ in 0..<3 {
                if let b = try input.next() { prefix.append(b) } else { break }
            }
            let encoding: String
            if prefix.starts(with: [0xEF, 0xBB, 0xBF]) {
                encoding = "utf-8-bom"
                prefix.removeFirst(3)
            } else if prefix.starts(with: [0xFF, 0xFE]) {
                encoding = "utf-16le"
                prefix.removeFirst(2)
            } else if prefix.starts(with: [0xFE, 0xFF]) {
                encoding = "utf-16be"
                prefix.removeFirst(2)
            } else {
                encoding = "utf-8"
            }
            input.prefix = prefix
            do {
                return DecodedText(text: try decode(input, encoding: encoding, maxScalars: maxScalars), encoding: encoding)
            } catch let error as IngestionError where error.code == "unsupportedEncoding"
                && encoding == "utf-8" && fallback == "cp1250" {
                try rewind()
                return DecodedText(text: try decode(Bytes(read: read), encoding: "windows-1250", maxScalars: maxScalars),
                                   encoding: "windows-1250")
            }
        }
    }

    private final class Bytes {
        let read: () throws -> Data?
        var block = Data()
        var offset = 0
        var prefix: [UInt8] = []
        var prefixOffset = 0
        init(read: @escaping () throws -> Data?) { self.read = read }
        func next() throws -> UInt8? {
            if prefixOffset < prefix.count {
                defer { prefixOffset += 1 }
                return prefix[prefixOffset]
            }
            while offset == block.count {
                try Task.checkCancellation()
                guard let next = try read() else { return nil }
                block = next
                offset = 0
            }
            defer { offset += 1 }
            return block[block.startIndex + offset]
        }
    }

    private static func decode(_ input: Bytes, encoding: String, maxScalars: Int) throws -> String {
        var result = String.UnicodeScalarView()
        var count = 0
        func invalid() -> IngestionError { IngestionError(code: "unsupportedEncoding") }
        func append(_ value: UInt32) throws {
            guard let scalar = Unicode.Scalar(value) else { throw invalid() }
            guard count < maxScalars else { throw IngestionError(code: "textLimit") }
            result.append(scalar)
            count += 1
        }
        func unit(first: UInt8, little: Bool) throws -> UInt32 {
            guard let second = try input.next() else { throw invalid() }
            return little ? UInt32(first) | UInt32(second) << 8 : UInt32(first) << 8 | UInt32(second)
        }
        while let first = try input.next() {
            if encoding == "windows-1250" {
                if first < 128 { try append(UInt32(first)); continue }
                guard ![0x81, 0x83, 0x88, 0x90, 0x98].contains(first),
                      let decoded = String(data: Data([first]), encoding: .windowsCP1250),
                      decoded.unicodeScalars.count == 1,
                      decoded.data(using: .windowsCP1250, allowLossyConversion: false) == Data([first]),
                      let scalar = decoded.unicodeScalars.first else { throw invalid() }
                try append(scalar.value)
            } else if encoding == "utf-16le" || encoding == "utf-16be" {
                let little = encoding == "utf-16le"
                let high = try unit(first: first, little: little)
                if (0xD800...0xDBFF).contains(high) {
                    guard let byte = try input.next() else { throw invalid() }
                    let low = try unit(first: byte, little: little)
                    guard (0xDC00...0xDFFF).contains(low) else { throw invalid() }
                    try append(0x10000 + (high - 0xD800) * 0x400 + low - 0xDC00)
                } else {
                    guard !(0xDC00...0xDFFF).contains(high) else { throw invalid() }
                    try append(high)
                }
            } else {
                if first < 0x80 { try append(UInt32(first)); continue }
                let length: Int
                var value: UInt32
                switch first {
                case 0xC2...0xDF: length = 2; value = UInt32(first & 0x1F)
                case 0xE0...0xEF: length = 3; value = UInt32(first & 0x0F)
                case 0xF0...0xF4: length = 4; value = UInt32(first & 0x07)
                default: throw invalid()
                }
                for _ in 1..<length {
                    guard let b = try input.next(), (0x80...0xBF).contains(b) else { throw invalid() }
                    value = value << 6 | UInt32(b & 0x3F)
                }
                guard value >= [0, 0, 0x80, 0x800, 0x10000][length], value <= 0x10FFFF,
                      !(0xD800...0xDFFF).contains(value) else { throw invalid() }
                try append(value)
            }
        }
        return String(result)
    }
}

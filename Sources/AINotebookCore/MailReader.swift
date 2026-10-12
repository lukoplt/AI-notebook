import Foundation

/// Bounded `.eml` (RFC 5322/MIME) and Outlook `.msg` (MS-OXMSG in MS-CFB)
/// reader producing canonical text (contract `ingestion-mail-v1`, reference
/// `tools/contracts/gen_mail_fixtures.py`, same output as Windows `MailReader`):
///
///     Subject: …\nFrom: …\nTo: …\nCc: …\nDate: …\nAttachments: a, b\n\n<body>
///
/// Header lines with an empty value are omitted; field labels are fixed English.
/// Attachments are listed by name only — their payloads (and any macro or
/// embedded object) are never decoded, read or executed.
enum MailReader {
    static let maxMimeDepth = 32
    static let maxMimeParts = 10_000
    static let maxAttachments = 10_000

    struct Fields {
        var subject = "", from = "", to = "", cc = "", date = ""
    }

    static func read(data: [UInt8], fileExtension: String, fallback: String, limits: IngestionLimits) throws -> CanonicalDocument {
        guard Int64(data.count) <= limits.fileBytes else { throw IngestionError(code: "fileLimit") }
        let budget = MailByteBudget(maximum: limits.officeBytes)
        let parsed: (Fields, [String], String)
        if data.count >= 8, Array(data[0..<8]) == CompoundFile.magic {
            parsed = try readMSG(data, fallback: fallback, budget: budget)
        } else if MailText.asciiLower(fileExtension) == "msg" {
            throw IngestionError(code: "corruptArchive")
        } else {
            parsed = try readEML(data, fallback: fallback, budget: budget)
        }
        let (fields, attachments, body) = parsed
        var lines: [String] = []
        for (label, value) in [("Subject", fields.subject), ("From", fields.from), ("To", fields.to),
                               ("Cc", fields.cc), ("Date", fields.date)] where !value.isEmpty {
            lines.append("\(label): \(value)")
        }
        if !attachments.isEmpty { lines.append("Attachments: " + attachments.joined(separator: ", ")) }
        var builder = try CanonicalTextBuilder(maxScalars: limits.textScalars)
        let head = lines.joined(separator: "\n")
        try builder.append(head)
        if !head.isEmpty && !body.isEmpty { try builder.append("\n\n") }
        try builder.append(body)
        return CanonicalDocument(text: builder.text, title: fields.subject.isEmpty ? nil : fields.subject,
                                 kind: SourceType.email.rawValue, pages: [], sheetNames: [], encoding: nil)
    }

    // MARK: EML

    final class Entity {
        var kind = "text/plain"
        var params: [String: String] = [:]
        var disposition = ""
        var name = ""
        var transferEncoding = ""
        var body: ArraySlice<UInt8> = []
        var children: [Entity] = []

        var isMultipart: Bool { kind.hasPrefix("multipart/") && !(params["boundary"] ?? "").isEmpty }
        var isAttachment: Bool { disposition == "attachment" || (disposition != "inline" && !name.isEmpty) }
    }

    private struct Line { let start: Int; let contentEnd: Int; let next: Int }

    /// The line starting at `i` (< end): LF ends a line; a CR before it is not content.
    private static func lineAt(_ data: [UInt8], _ i: Int, end: Int) -> Line {
        guard let j = data[i..<end].firstIndex(of: 0x0A) else { return Line(start: i, contentEnd: end, next: end) }
        return Line(start: i, contentEnd: j > i && data[j - 1] == 0x0D ? j - 1 : j, next: j + 1)
    }

    /// Unfolded headers (lowercased name, decoded raw value) and the body offset.
    private static func headers(_ data: [UInt8], _ start: Int, _ end: Int, fallback: String) throws -> ([(String, String)], Int) {
        var raw: [([UInt8], [UInt8])] = []
        var open = false
        var bodyStart = end
        var position = start
        while position < end {
            try Task.checkCancellation()
            let line = lineAt(data, position, end: end)
            position = line.next
            if line.contentEnd == line.start {
                bodyStart = line.next
                break
            }
            let first = data[line.start]
            if first == 0x20 || first == 0x09 {
                if open { raw[raw.count - 1].1 += data[line.start..<line.contentEnd] }
                continue
            }
            guard let colon = data[line.start..<line.contentEnd].firstIndex(of: 0x3A), colon > line.start else {
                open = false
                continue
            }
            raw.append((Array(data[line.start..<colon]), Array(data[(colon + 1)..<line.contentEnd])))
            open = true
        }
        let result = raw.map { name, value -> (String, String) in
            var lo = 0, hi = name.count
            while lo < hi, name[lo] == 0x20 || name[lo] == 0x09 { lo += 1 }
            while hi > lo, name[hi - 1] == 0x20 || name[hi - 1] == 0x09 { hi -= 1 }
            var key = String.UnicodeScalarView()
            for byte in name[lo..<hi] { key.append(Unicode.Scalar((65...90).contains(byte) ? byte + 32 : byte)) }
            return (String(key), MailText.decode(value, codec: "auto", fallback: fallback))
        }
        return (result, bodyStart)
    }

    private static func header(_ headers: [(String, String)], _ name: String) -> String? {
        headers.first { $0.0 == name }?.1
    }

    private static func parseEntity(_ data: [UInt8], _ start: Int, _ end: Int, depth: Int, parts: inout Int,
                                    fallback: String) throws -> (Entity, [(String, String)]) {
        guard depth <= maxMimeDepth else { throw IngestionError(code: "officeLimit") }
        parts += 1
        guard parts <= maxMimeParts else { throw IngestionError(code: "officeLimit") }
        let (headers, bodyStart) = try headers(data, start, end, fallback: fallback)
        let entity = Entity()
        var (kind, params) = MailText.parameters(header(headers, "content-type") ?? "")
        if !kind.unicodeScalars.contains("/") { (kind, params) = ("text/plain", [:]) }
        entity.kind = kind
        entity.params = params
        let (disposition, dispositionParams) = MailText.parameters(header(headers, "content-disposition") ?? "")
        entity.disposition = disposition
        let filename = MailText.parameter(dispositionParams, "filename", fallback: fallback)
        entity.name = filename.isEmpty ? MailText.parameter(params, "name", fallback: fallback) : filename
        entity.transferEncoding = MailText.asciiLower(MailText.trim(header(headers, "content-transfer-encoding") ?? ""))
        if entity.isMultipart {
            let boundary = Array((params["boundary"] ?? "").utf8)
            for (partStart, partEnd) in try split(data, bodyStart, end, boundary: boundary) {
                entity.children.append(try parseEntity(data, partStart, partEnd, depth: depth + 1, parts: &parts,
                                                       fallback: fallback).0)
            }
        } else {
            entity.body = data[bodyStart..<end]
        }
        return (entity, headers)
    }

    private static func split(_ data: [UInt8], _ start: Int, _ end: Int, boundary: [UInt8]) throws -> [(Int, Int)] {
        let delimiter: [UInt8] = [0x2D, 0x2D] + boundary
        let close = delimiter + [0x2D, 0x2D]
        var parts: [(Int, Int)] = []
        var open: Int?
        var position = start
        while position < end {
            try Task.checkCancellation()
            let line = lineAt(data, position, end: end)
            position = line.next
            var stop = line.contentEnd
            while stop > line.start, data[stop - 1] == 0x20 || data[stop - 1] == 0x09 { stop -= 1 }
            let content = data[line.start..<stop]
            let isClose = content.elementsEqual(close)
            guard isClose || content.elementsEqual(delimiter) else { continue }
            if let partStart = open {
                var partEnd = line.start
                if partEnd > partStart, data[partEnd - 1] == 0x0A {
                    partEnd -= 1
                    if partEnd > partStart, data[partEnd - 1] == 0x0D { partEnd -= 1 }
                }
                parts.append((partStart, max(partStart, partEnd)))
            }
            if isClose { return parts }
            open = line.next
        }
        if let partStart = open { parts.append((partStart, end)) }
        return parts
    }

    private static func leafText(_ entity: Entity, budget: MailByteBudget, fallback: String) throws -> String {
        var bytes: [UInt8]
        switch entity.transferEncoding {
        case "base64": bytes = MailText.base64Lenient(entity.body)
        case "quoted-printable": bytes = MailText.quotedPrintable(Array(entity.body))
        default: bytes = Array(entity.body)
        }
        try budget.accept(bytes.count)
        var text = MailText.normalizeNewlines(MailText.decode(bytes, codec: MailText.codec(label: entity.params["charset"] ?? ""),
                                                              fallback: fallback))
        bytes = []
        if entity.kind == "text/html" { text = MailText.htmlToText(text) }
        return MailText.trim(text)
    }

    /// multipart/alternative: the first text/plain child, else the first child
    /// yielding a body; other multiparts join their children's bodies.
    private static func body(_ entity: Entity, budget: MailByteBudget, fallback: String) throws -> String? {
        try Task.checkCancellation()
        if entity.isMultipart {
            let children = entity.children.filter { !$0.isAttachment }
            if entity.kind == "multipart/alternative" {
                if let plain = children.first(where: { $0.kind == "text/plain" }) {
                    return try leafText(plain, budget: budget, fallback: fallback)
                }
                for child in children {
                    if let value = try body(child, budget: budget, fallback: fallback) { return value }
                }
                return nil
            }
            var bodies: [String] = []
            for child in children {
                if let value = try body(child, budget: budget, fallback: fallback) { bodies.append(value) }
            }
            return bodies.isEmpty ? nil : bodies.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        guard !entity.isAttachment, entity.kind == "text/plain" || entity.kind == "text/html" else { return nil }
        return try leafText(entity, budget: budget, fallback: fallback)
    }

    private static func attachments(_ entity: Entity, into names: inout [String]) throws {
        if entity.isMultipart {
            for child in entity.children { try attachments(child, into: &names) }
        } else if entity.isAttachment && !entity.name.isEmpty {
            guard names.count < maxAttachments else { throw IngestionError(code: "officeLimit") }
            names.append(entity.name)
        }
    }

    static func readEML(_ data: [UInt8], fallback: String, budget: MailByteBudget) throws -> (Fields, [String], String) {
        var start = 0
        if data.starts(with: Array("From ".utf8)) {
            start = data.firstIndex(of: 0x0A).map { $0 + 1 } ?? data.count
        }
        var parts = 0
        let (root, headers) = try parseEntity(data, start, data.count, depth: 0, parts: &parts, fallback: fallback)
        func field(_ name: String) -> String { MailText.decodeHeader(header(headers, name) ?? "", fallback: fallback) }
        let fields = Fields(subject: field("subject"), from: field("from"), to: field("to"), cc: field("cc"), date: field("date"))
        let text = try body(root, budget: budget, fallback: fallback) ?? ""
        var names: [String] = []
        try attachments(root, into: &names)
        return (fields, names, MailText.trim(text))
    }

    // MARK: MSG

    private enum Tag {
        static let subject: UInt32 = 0x0037, sentName: UInt32 = 0x0042, sentEmail: UInt32 = 0x0065
        static let senderName: UInt32 = 0x0C1A, senderEmail: UInt32 = 0x0C1F, smtp: UInt32 = 0x5D01
        static let displayCc: UInt32 = 0x0E03, displayTo: UInt32 = 0x0E04, body: UInt32 = 0x1000, html: UInt32 = 0x1013
        static let submitTime: UInt32 = 0x0039, deliveryTime: UInt32 = 0x0E06
        static let codePage: UInt32 = 0x3FFD, internetCodePage: UInt32 = 0x3FDE
        static let attachLongName: UInt32 = 0x3707, attachShortName: UInt32 = 0x3704, displayName: UInt32 = 0x3001
    }

    private static func streamName(_ property: UInt32, _ type: UInt32) -> String {
        String(format: "__SUBSTG1.0_%04X%04X", property, type)
    }

    private static func string(_ file: CompoundFile, _ children: [String: Int], _ property: UInt32,
                               codec: String, fallback: String) throws -> String? {
        if let index = children[streamName(property, 0x001F)] {
            var scalars = Array(MailText.utf16LE(try file.stream(index)).unicodeScalars)
            while scalars.last == "\0" { scalars.removeLast() }
            return String(String.UnicodeScalarView(scalars))
        }
        if let index = children[streamName(property, 0x001E)] {
            var bytes = try file.stream(index)
            while bytes.last == 0 { bytes.removeLast() }
            return MailText.decode(bytes, codec: codec, fallback: fallback)
        }
        return nil
    }

    /// Top-level fixed-length properties: id -> (type, 8 value bytes); the first entry per id wins.
    private static func properties(_ file: CompoundFile, _ children: [String: Int]) throws -> [UInt32: (UInt32, [UInt8])] {
        guard let index = children["__PROPERTIES_VERSION1.0"] else { return [:] }
        let data = try file.stream(index)
        var result: [UInt32: (UInt32, [UInt8])] = [:]
        var at = 32
        while at + 16 <= data.count {
            let tag = CompoundFile.u32(data, at)
            if result[tag >> 16] == nil { result[tag >> 16] = (tag & 0xFFFF, Array(data[(at + 8)..<(at + 16)])) }
            at += 16
        }
        return result
    }

    /// FILETIME -> `YYYY-MM-DDTHH:MM:SSZ` (UTC); 0 or a year above 9999 -> "".
    static func filetime(_ value: UInt64) -> String {
        guard value != 0 else { return "" }
        let seconds = Int64(value / 10_000_000) - 11_644_473_600
        var days = seconds / 86_400, rest = seconds % 86_400
        if rest < 0 { rest += 86_400; days -= 1 }
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        guard year <= 9999 else { return "" }
        return String(format: "%04lld-%02lld-%02lldT%02lld:%02lld:%02lldZ", year, month, day, rest / 3600, rest / 60 % 60, rest % 60)
    }

    static func readMSG(_ data: [UInt8], fallback: String, budget: MailByteBudget) throws -> (Fields, [String], String) {
        let file = try CompoundFile(data: data, budget: budget)
        let root = try file.children(of: 0)
        let props = try properties(file, root)
        func long(_ property: UInt32) -> UInt32? {
            guard let value = props[property], value.0 == 0x0003 else { return nil }
            return CompoundFile.u32(value.1, 0)
        }
        let codec = long(Tag.codePage).map(MailText.codec(codePage:)) ?? "auto"
        let htmlCodec = long(Tag.internetCodePage).map(MailText.codec(codePage:)) ?? codec
        func value(_ property: UInt32, _ children: [String: Int]? = nil) throws -> String {
            MailText.collapse(try string(file, children ?? root, property, codec: codec, fallback: fallback) ?? "")
        }
        var name = try value(Tag.senderName)
        if name.isEmpty { name = try value(Tag.sentName) }
        var email = ""
        for property in [Tag.smtp, Tag.senderEmail, Tag.sentEmail] {
            let candidate = try value(property)
            if candidate.unicodeScalars.contains("@") { email = candidate; break }
        }
        let from = !name.isEmpty && !email.isEmpty && name != email ? "\(name) <\(email)>" : (name.isEmpty ? email : name)
        var date = ""
        for property in [Tag.submitTime, Tag.deliveryTime] {
            guard let raw = props[property], raw.0 == 0x0040 else { continue }
            let ticks = raw.1.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
            date = filetime(ticks)
            if !date.isEmpty { break }
        }
        let fields = Fields(subject: try value(Tag.subject), from: from, to: try value(Tag.displayTo),
                            cc: try value(Tag.displayCc), date: date)
        var text = try string(file, root, Tag.body, codec: codec, fallback: fallback)
            .map { MailText.trim(MailText.normalizeNewlines($0)) } ?? ""
        if text.isEmpty {
            var html: String?
            if let binary = root[streamName(Tag.html, 0x0102)] {
                html = MailText.decode(try file.stream(binary), codec: htmlCodec, fallback: fallback)
            } else {
                html = try string(file, root, Tag.html, codec: codec, fallback: fallback)
            }
            text = html.map { MailText.trim(MailText.htmlToText(MailText.normalizeNewlines($0))) } ?? ""
        }
        let storages = root.filter { key, index in
            key.hasPrefix("__ATTACH_VERSION1.0_#") && file.entries[index].kind == 1
        }.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        guard storages.count <= maxAttachments else { throw IngestionError(code: "officeLimit") }
        var names: [String] = []
        for key in storages {
            let children = try file.children(of: root[key]!)
            var name = try value(Tag.attachLongName, children)
            if name.isEmpty { name = try value(Tag.attachShortName, children) }
            if name.isEmpty { name = try value(Tag.displayName, children) }
            if !name.isEmpty { names.append(name) }
        }
        return (fields, names, text)
    }
}

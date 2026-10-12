import Foundation

/// `messages.citations_json` codec (contract `citations` v2, shared fixture
/// `Tests/fixtures/contracts/citations-v2.json`). Legacy rows are a bare JSON
/// array; v2 rows are `{"v":2,"items":[…]}`.
///
/// Decoding never throws: malformed or unknown payloads yield `[]`, and a bad
/// item is skipped, not the whole list. Non-finite number tokens or invalid
/// Unicode invalidate the whole payload, including unknown fields.
/// Numbers are strict — `1.5`, `1e3`,
/// booleans or out-of-range values invalidate the item (`JSONDecoder` would
/// silently accept `1e3` as an integer, so items are read via
/// `JSONSerialization`, which keeps the float/integer distinction). A `null`
/// optional field counts as absent.
public enum CitationsCodec {
    /// Ids and offsets must survive a round trip through any JSON reader.
    static let maxJSONSafeInteger: Int64 = 9_007_199_254_740_991

    private struct V2Out: Encodable {
        let v = 2
        let items: [Citation]
    }

    public static func decode(_ raw: String?) -> [Citation] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              numbersAreFinite(in: data) else { return [] }
        let items: [Any]
        if let array = root as? [Any] {
            items = array
        } else if let object = root as? [String: Any],
                  strictInt(object["v"]) == 2,
                  let array = object["items"] as? [Any] {
            items = array
        } else {
            return []
        }
        return items.compactMap(citation(from:))
    }

    public static func encode(_ citations: [Citation]) -> String? {
        guard !citations.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data?
        if citations.contains(where: \.isV2) {
            data = try? encoder.encode(V2Out(items: citations))
        } else {
            data = try? encoder.encode(citations)
        }
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func numbersAreFinite(in data: Data) -> Bool {
        // JSONSerialization has already checked the JSON grammar. Scan the raw
        // tokens because its dictionaries discard duplicate property values.
        let bytes = Array(data)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x22 {
                index += 1
                while index < bytes.count && bytes[index] != 0x22 {
                    index += bytes[index] == 0x5c ? 2 : 1
                }
                index += 1
            } else if bytes[index] == 0x2d || (0x30...0x39).contains(bytes[index]) {
                let start = index
                while index < bytes.count,
                      (0x30...0x39).contains(bytes[index]) || [0x2b, 0x2d, 0x2e, 0x45, 0x65].contains(bytes[index]) {
                    index += 1
                }
                guard let number = Double(String(decoding: bytes[start..<index], as: UTF8.self)),
                      number.isFinite else { return false }
            } else {
                index += 1
            }
        }
        return true
    }

    // MARK: - Strict item reading

    /// Present-or-absent wrapper: `.absent` for a missing key or JSON null,
    /// `.invalid` for a present value of the wrong kind or range.
    private enum Field<T> {
        case absent, value(T), invalid
    }

    private static func strictInt(_ any: Any?) -> Int64? {
        guard let number = any as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        return number.int64Value
    }

    private static func optionalInt(_ any: Any?, in range: ClosedRange<Int64>) -> Field<Int64> {
        if any == nil || any is NSNull { return .absent }
        guard let value = strictInt(any), range.contains(value) else { return .invalid }
        return .value(value)
    }

    private static func optionalString(_ any: Any?) -> Field<String> {
        if any == nil || any is NSNull { return .absent }
        guard let value = any as? String else { return .invalid }
        return .value(value)
    }

    private static func span(from any: Any) -> CitationSpan? {
        guard let dict = any as? [String: Any],
              let start = strictInt(dict["start"]), let end = strictInt(dict["end"]),
              start >= 0, start < end, end <= maxJSONSafeInteger else { return nil }
        let pageRange: ClosedRange<Int64> = 0...Int64(Int32.max)
        let from: Int?, to: Int?
        switch optionalInt(dict["pageFrom"], in: pageRange) {
        case .absent: from = nil
        case let .value(v): from = Int(v)
        case .invalid: return nil
        }
        switch optionalInt(dict["pageTo"], in: pageRange) {
        case .absent: to = nil
        case let .value(v): to = Int(v)
        case .invalid: return nil
        }
        if let from, let to, from > to { return nil }
        return CitationSpan(start: Int(start), end: Int(end), pageFrom: from, pageTo: to)
    }

    private static func citation(from any: Any) -> Citation? {
        guard let dict = any as? [String: Any],
              let marker = strictInt(dict["marker"]), (1...Int64(Int32.max)).contains(marker),
              let chunkId = strictInt(dict["chunkId"]), (0...maxJSONSafeInteger).contains(chunkId),
              let sourceId = strictInt(dict["sourceId"]), (0...maxJSONSafeInteger).contains(sourceId),
              let snippet = dict["snippet"] as? String
        else { return nil }

        var c = Citation(marker: Int(marker), chunkId: chunkId, sourceId: sourceId, snippet: snippet)
        let idRange: ClosedRange<Int64> = 0...maxJSONSafeInteger

        switch optionalInt(dict["folderId"], in: idRange) {
        case .absent: break
        case let .value(v): c.folderId = v
        case .invalid: return nil
        }
        switch optionalInt(dict["revisionId"], in: idRange) {
        case .absent: break
        case let .value(v): c.revisionId = v
        case .invalid: return nil
        }
        switch optionalString(dict["relPath"]) {
        case .absent: break
        case let .value(v): c.relPath = v
        case .invalid: return nil
        }
        switch optionalString(dict["displayName"]) {
        case .absent: break
        case let .value(v): c.displayName = v
        case .invalid: return nil
        }
        switch optionalString(dict["text"]) {
        case .absent: break
        case let .value(v): c.text = v
        case .invalid: return nil
        }
        if let rawSpans = dict["spans"], !(rawSpans is NSNull) {
            guard let array = rawSpans as? [Any] else { return nil }
            let spans = array.compactMap(span(from:))
            guard spans.count == array.count else { return nil }
            c.spans = spans
        }
        if let rawIds = dict["chunkIds"], !(rawIds is NSNull) {
            guard let array = rawIds as? [Any] else { return nil }
            let ids = array.compactMap { strictInt($0) }.filter { idRange.contains($0) }
            guard ids.count == array.count else { return nil }
            c.chunkIds = ids
        }
        return c
    }
}

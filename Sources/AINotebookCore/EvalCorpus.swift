import CryptoKit
import Foundation

public struct EvalFailure: Error, Equatable, Sendable {
    public let code: String
    public init(_ code: String) { self.code = code }
}

public struct EvalSpan: Codable, Hashable, Sendable {
    public let documentId: String
    public let contentHash: String
    public let start: Int
    public let end: Int

    public init(documentId: String, contentHash: String, start: Int, end: Int) {
        self.documentId = documentId
        self.contentHash = contentHash
        self.start = start
        self.end = end
    }

    private enum CodingKeys: String, CodingKey {
        case documentId = "document_id", contentHash = "content_hash", start, end
    }
}

public struct EvalWindow: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let text: String

    public init(start: Int, end: Int, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct EvalDocument: Codable, Equatable, Sendable {
    public let documentId: String
    public let sourceId: Int64
    public let notebookId: Int64
    public let folderId: Int64?
    public let path: String
    public let relPath: String
    public let language: String
    public let encoding: String
    public let rawSha256: String
    public let contentHash: String

    public init(documentId: String, sourceId: Int64, notebookId: Int64, folderId: Int64?,
                path: String, relPath: String, language: String, encoding: String,
                rawSha256: String, contentHash: String) {
        self.documentId = documentId
        self.sourceId = sourceId
        self.notebookId = notebookId
        self.folderId = folderId
        self.path = path
        self.relPath = relPath
        self.language = language
        self.encoding = encoding
        self.rawSha256 = rawSha256
        self.contentHash = contentHash
    }

    private enum CodingKeys: String, CodingKey {
        case documentId = "document_id", sourceId = "source_id", notebookId = "notebook_id"
        case folderId = "folder_id", path, relPath = "rel_path", language, encoding
        case rawSha256 = "raw_sha256", contentHash = "content_hash"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        documentId = try c.decode(String.self, forKey: .documentId)
        sourceId = try c.decode(Int64.self, forKey: .sourceId)
        notebookId = try c.decode(Int64.self, forKey: .notebookId)
        // Nullable is still required in the asset wire format.
        folderId = try c.decode(Int64?.self, forKey: .folderId)
        path = try c.decode(String.self, forKey: .path)
        relPath = try c.decode(String.self, forKey: .relPath)
        language = try c.decode(String.self, forKey: .language)
        encoding = try c.decode(String.self, forKey: .encoding)
        rawSha256 = try c.decode(String.self, forKey: .rawSha256)
        contentHash = try c.decode(String.self, forKey: .contentHash)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(documentId, forKey: .documentId)
        try c.encode(sourceId, forKey: .sourceId)
        try c.encode(notebookId, forKey: .notebookId)
        try c.encode(folderId, forKey: .folderId)
        try c.encode(path, forKey: .path)
        try c.encode(relPath, forKey: .relPath)
        try c.encode(language, forKey: .language)
        try c.encode(encoding, forKey: .encoding)
        try c.encode(rawSha256, forKey: .rawSha256)
        try c.encode(contentHash, forKey: .contentHash)
    }
}

public struct EvalGold: Codable, Equatable, Sendable {
    public let documentId: String
    public let contentHash: String
    public let phrase: String
    public let occurrence: Int

    public init(documentId: String, contentHash: String, phrase: String, occurrence: Int) {
        self.documentId = documentId
        self.contentHash = contentHash
        self.phrase = phrase
        self.occurrence = occurrence
    }

    private enum CodingKeys: String, CodingKey {
        case documentId = "document_id", contentHash = "content_hash", phrase, occurrence
    }
}

public struct EvalQuestion: Codable, Equatable, Sendable {
    public let queryId: String
    public let text: String
    public let language: String
    public let caseType: String
    public let tags: [String]
    public let notebookId: Int64
    public let scope: RetrievalScope
    public let gold: [EvalGold]
    public let absentReason: String?
    public let overviewDocumentIds: [String]

    public init(queryId: String, text: String, language: String, caseType: String,
                tags: [String], notebookId: Int64, scope: RetrievalScope, gold: [EvalGold],
                absentReason: String?, overviewDocumentIds: [String]) {
        self.queryId = queryId
        self.text = text
        self.language = language
        self.caseType = caseType
        self.tags = tags
        self.notebookId = notebookId
        self.scope = scope
        self.gold = gold
        self.absentReason = absentReason
        self.overviewDocumentIds = overviewDocumentIds
    }

    private enum CodingKeys: String, CodingKey {
        case queryId = "query_id", text, language, caseType = "case_type", tags
        case notebookId = "notebook_id", scope, gold, absentReason = "absent_reason"
        case overviewDocumentIds = "overview_document_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queryId = try c.decode(String.self, forKey: .queryId)
        text = try c.decode(String.self, forKey: .text)
        language = try c.decode(String.self, forKey: .language)
        caseType = try c.decode(String.self, forKey: .caseType)
        tags = try c.decode([String].self, forKey: .tags)
        notebookId = try c.decode(Int64.self, forKey: .notebookId)
        scope = try c.decode(RetrievalScope.self, forKey: .scope)
        gold = try c.decode([EvalGold].self, forKey: .gold)
        absentReason = try c.decode(String?.self, forKey: .absentReason)
        overviewDocumentIds = try c.decode([String].self, forKey: .overviewDocumentIds)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(queryId, forKey: .queryId)
        try c.encode(text, forKey: .text)
        try c.encode(language, forKey: .language)
        try c.encode(caseType, forKey: .caseType)
        try c.encode(tags, forKey: .tags)
        try c.encode(notebookId, forKey: .notebookId)
        try c.encode(scope, forKey: .scope)
        try c.encode(gold, forKey: .gold)
        try c.encode(absentReason, forKey: .absentReason)
        try c.encode(overviewDocumentIds, forKey: .overviewDocumentIds)
    }
}

public struct LoadedEvalDocument: Sendable {
    public let metadata: EvalDocument
    public let text: String

    public init(metadata: EvalDocument, text: String) {
        self.metadata = metadata
        self.text = text
    }
}

/// Immutable eval assets. Canonical text is the strict decoded file, without
/// trimming, normalization, newline conversion or BOM removal.
public struct EvalCorpus: Sendable {
    public let corpusId: String
    public let documents: [LoadedEvalDocument]
    public let questions: [EvalQuestion]
    public let gold: [String: [EvalSpan]]

    public static func load(manifest: Data, queries: Data,
                            readFile: (String) throws -> Data) throws -> EvalCorpus {
        let m: Manifest
        let qs: Questions
        do {
            try EvalJSONPreflight.validate(manifest)
            try EvalJSONPreflight.validate(queries)
            let decoder = JSONDecoder()
            m = try decoder.decode(Manifest.self, from: manifest)
            qs = try decoder.decode(Questions.self, from: queries)
        } catch {
            throw EvalFailure("invalid_query")
        }
        guard m.contract == "eval-corpus", qs.contract == "eval-queries",
              m.version == 1, qs.version == 1, m.license == "MIT",
              isIdentifier(m.corpusId), m.corpusId == qs.corpusId,
              !m.documents.isEmpty, !qs.queries.isEmpty else { throw EvalFailure("invalid_query") }

        for d in m.documents {
            guard isIdentifier(d.documentId), isId(d.sourceId), isId(d.notebookId),
                  d.folderId.map(isId) ?? true,
                  ["cs", "sk", "en", "de", "mixed"].contains(d.language)
            else { throw EvalFailure("invalid_query") }
        }
        for q in qs.queries {
            guard isIdentifier(q.queryId), !q.text.isEmpty, isId(q.notebookId),
                  ["cs", "sk", "en", "de"].contains(q.language),
                  ["answer", "exact_identifier", "scope", "absent", "empty_selection", "overview"].contains(q.caseType),
                  q.gold.allSatisfy({ (Int(Int32.min)...Int(Int32.max)).contains($0.occurrence) })
            else { throw EvalFailure("invalid_query") }
            if case let .selection(sources, folders) = q.scope {
                guard sources.allSatisfy(isId), folders.allSatisfy(isId) else { throw EvalFailure("invalid_query") }
            }
        }

        // Separate scans preserve the documented error precedence.
        var documentIds = Set<String>()
        for d in m.documents where !documentIds.insert(d.documentId).inserted {
            throw EvalFailure("duplicate_document")
        }
        var sourceIds = Set<Int64>()
        for d in m.documents where !sourceIds.insert(d.sourceId).inserted {
            throw EvalFailure("duplicate_source")
        }
        var queryIds = Set<String>()
        for q in qs.queries where !queryIds.insert(q.queryId).inserted {
            throw EvalFailure("duplicate_query")
        }
        var folderNotebooks: [Int64: Int64] = [:]
        var relativePaths = Set<FolderPath>()
        for d in m.documents {
            if let folder = d.folderId {
                guard relativePaths.insert(FolderPath(notebookId: d.notebookId,
                    folderId: folder, path: Data(d.relPath.utf8))).inserted
                else { throw EvalFailure("invalid_path") }
                if let notebook = folderNotebooks[folder], notebook != d.notebookId {
                    throw EvalFailure("invalid_query")
                }
                folderNotebooks[folder] = d.notebookId
            }
        }

        var loaded: [LoadedEvalDocument] = []
        for d in m.documents {
            guard safeRelativePath(d.path), safeRelativePath(d.relPath) else { throw EvalFailure("invalid_path") }
            guard isHash(d.rawSha256), isHash(d.contentHash) else { throw EvalFailure("invalid_hash") }
            let raw: Data
            do { raw = try readFile(d.path) }
            catch { throw EvalFailure("missing_file") }
            guard sha256(raw) == d.rawSha256 else { throw EvalFailure("raw_hash_mismatch") }
            let text = try decode(raw, encoding: d.encoding)
            guard sha256(Data(text.utf8)) == d.contentHash else { throw EvalFailure("content_hash_mismatch") }
            loaded.append(LoadedEvalDocument(metadata: d, text: text))
        }

        let byId = Dictionary(uniqueKeysWithValues: loaded.map { ($0.metadata.documentId, $0) })
        let notebooks = Set(m.documents.map(\.notebookId))
        let folders = Set(folderNotebooks.keys)
        var gold: [String: [EvalSpan]] = [:]
        for q in qs.queries {
            guard notebooks.contains(q.notebookId) else { throw EvalFailure("invalid_query") }
            if case let .selection(sources, selectedFolders) = q.scope {
                guard sources.isSubset(of: sourceIds), selectedFolders.isSubset(of: folders)
                else { throw EvalFailure("invalid_query") }
            }
            let selectedIds = Set(selectedDocuments(in: loaded, for: q).map { $0.metadata.documentId })
            try validateShape(q, selectedIds: selectedIds)
            var tuples = Set<GoldIdentity>()
            for g in q.gold {
                guard tuples.insert(GoldIdentity(documentId: Data(g.documentId.utf8),
                    contentHash: Data(g.contentHash.utf8), phrase: Data(g.phrase.utf8),
                    occurrence: g.occurrence)).inserted else { throw EvalFailure("invalid_gold") }
            }
            var resolved: [EvalSpan] = []
            for g in q.gold {
                guard let doc = byId[g.documentId] else { throw EvalFailure("unknown_document") }
                guard isHash(g.contentHash) else { throw EvalFailure("invalid_hash") }
                guard g.contentHash == doc.metadata.contentHash else { throw EvalFailure("gold_hash_mismatch") }
                guard selectedIds.contains(g.documentId) else { throw EvalFailure("gold_out_of_scope") }
                let span = try occurrence(in: doc.text, phrase: g.phrase, number: g.occurrence)
                resolved.append(EvalSpan(documentId: g.documentId, contentHash: g.contentHash,
                                         start: span.lowerBound, end: span.upperBound))
            }
            gold[q.queryId] = resolved
        }
        return EvalCorpus(corpusId: m.corpusId, documents: loaded, questions: qs.queries, gold: gold)
    }

    public static func decode(_ bytes: Data, encoding: String) throws -> String {
        switch encoding {
        case "utf-8":
            guard String(data: bytes, encoding: .utf8) != nil else { throw EvalFailure("invalid_encoding") }
            // The failable initializer validates but strips a leading BOM.
            return String(decoding: bytes, as: UTF8.self)
        case "windows-1250":
            guard !bytes.contains(where: { [0x81, 0x83, 0x88, 0x90, 0x98].contains($0) }),
                  let text = String(data: bytes, encoding: .windowsCP1250)
            else { throw EvalFailure("invalid_encoding") }
            return text
        default:
            throw EvalFailure("invalid_encoding")
        }
    }

    public static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public static func occurrence(in text: String, phrase: String, number: Int) throws -> Range<Int> {
        let haystack = Array(text.unicodeScalars), needle = Array(phrase.unicodeScalars)
        guard !needle.isEmpty, number > 0 else { throw EvalFailure("invalid_gold") }
        guard needle.count <= haystack.count else { throw EvalFailure("occurrence_not_found") }
        var seen = 0
        for start in 0...(haystack.count - needle.count) {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) {
                seen += 1
                if seen == number { return start..<(start + needle.count) }
            }
        }
        throw EvalFailure("occurrence_not_found")
    }

    /// `eval-scalars-v1`: exact scalar windows, independent of production Chunker.
    public static func windows(_ text: String, size: Int = 2048,
                               overlap: Int = 256) throws -> [EvalWindow] {
        guard size > 0, overlap >= 0, overlap < size else { throw EvalFailure("invalid_window") }
        let scalars = Array(text.unicodeScalars)
        var start = 0, result: [EvalWindow] = []
        while start < scalars.count {
            let end = start + min(size, scalars.count - start)
            result.append(EvalWindow(start: start, end: end,
                text: String(String.UnicodeScalarView(scalars[start..<end]))))
            if end == scalars.count { break }
            start = end - overlap
        }
        return result
    }

    public static func safeRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.contains("\\") && !path.contains(":")
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    public func selectedDocuments(for question: EvalQuestion) -> [LoadedEvalDocument] {
        Self.selectedDocuments(in: documents, for: question)
    }

    private static func selectedDocuments(in documents: [LoadedEvalDocument],
                                          for q: EvalQuestion) -> [LoadedEvalDocument] {
        documents.filter { d in
            guard d.metadata.notebookId == q.notebookId else { return false }
            switch q.scope {
            case .all: return true
            case let .selection(sources, folders):
                return sources.contains(d.metadata.sourceId)
                    || d.metadata.folderId.map { folders.contains($0) } == true
            }
        }
    }

    private static func validateShape(_ q: EvalQuestion, selectedIds: Set<String>) throws {
        switch q.caseType {
        case "answer", "exact_identifier", "scope":
            guard !q.gold.isEmpty, q.overviewDocumentIds.isEmpty, q.absentReason == nil
            else { throw EvalFailure("invalid_query") }
        case "absent", "empty_selection":
            let reason = q.caseType == "absent" ? "not_in_corpus" : "empty_scope"
            guard q.gold.isEmpty, q.overviewDocumentIds.isEmpty, q.absentReason == reason,
                  q.caseType != "empty_selection" || selectedIds.isEmpty
            else { throw EvalFailure("invalid_query") }
        case "overview":
            let overviewIds = Set(q.overviewDocumentIds)
            guard q.absentReason == nil, !overviewIds.isEmpty,
                  overviewIds.count == q.overviewDocumentIds.count,
                  overviewIds.isSubset(of: selectedIds), overviewIds == Set(q.gold.map(\.documentId))
            else { throw EvalFailure("invalid_query") }
        default:
            throw EvalFailure("invalid_query")
        }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        func alphanumeric(_ b: UInt8) -> Bool { (48...57).contains(b) || (97...122).contains(b) }
        guard let first = value.utf8.first, alphanumeric(first) else { return false }
        return value.utf8.allSatisfy { alphanumeric($0) || $0 == 45 }
    }

    private static func isId(_ value: Int64) -> Bool { (1...9_007_199_254_740_991).contains(value) }

    private static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private struct FolderPath: Hashable {
        let notebookId: Int64
        let folderId: Int64
        let path: Data
    }

    private struct GoldIdentity: Hashable {
        let documentId: Data
        let contentHash: Data
        let phrase: Data
        let occurrence: Int
    }

    private struct Manifest: Decodable {
        let contract: String
        let version: Int
        let corpusId: String
        let license: String
        let documents: [EvalDocument]
        enum CodingKeys: String, CodingKey {
            case contract, version, corpusId = "corpus_id", license, documents
        }
    }

    private struct Questions: Decodable {
        let contract: String
        let version: Int
        let corpusId: String
        let queries: [EvalQuestion]
        enum CodingKeys: String, CodingKey {
            case contract, version, corpusId = "corpus_id", queries
        }
    }
}

/// Foundation decoders can coerce fractional/exponent tokens to integers. Walk
/// the original tokens before DTO decoding, preserving that wire distinction.
/// JSONSerialization checks grammar first; every string, including ignored
/// fields and keys, is also decoded strictly to reject unpaired surrogates.
private struct EvalJSONPreflight {
    private let bytes: [UInt8]
    private var index = 0
    private static let arithmeticFields: Set<String> = [
        "version", "source_id", "notebook_id", "folder_id", "sourceIds", "folderIds", "occurrence"
    ]

    static func validate(_ data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else { throw EvalFailure("invalid_query") }
        _ = try JSONSerialization.jsonObject(with: data)
        var scanner = EvalJSONPreflight(bytes: Array(data))
        if scanner.bytes.starts(with: [0xef, 0xbb, 0xbf]) { scanner.index = 3 }
        try scanner.value(field: nil)
        scanner.whitespace()
        guard scanner.index == scanner.bytes.count else { throw EvalFailure("invalid_query") }
    }

    private mutating func whitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func string() throws -> String {
        whitespace()
        let start = index
        guard consume(0x22) else { throw EvalFailure("invalid_query") }
        while index < bytes.count {
            switch bytes[index] {
            case 0x5c: index += 2
            case 0x22:
                index += 1
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            default: index += 1
            }
        }
        throw EvalFailure("invalid_query")
    }

    private mutating func value(field: String?) throws {
        whitespace()
        guard index < bytes.count else { throw EvalFailure("invalid_query") }
        switch bytes[index] {
        case 0x7b: // object
            index += 1
            if consume(0x7d) { return }
            repeat {
                let key = try string()
                guard consume(0x3a) else { throw EvalFailure("invalid_query") }
                try value(field: key)
                if consume(0x7d) { return }
            } while consume(0x2c)
            throw EvalFailure("invalid_query")
        case 0x5b: // array, retaining the field name for scope ID elements
            index += 1
            if consume(0x5d) { return }
            repeat {
                try value(field: field)
                if consume(0x5d) { return }
            } while consume(0x2c)
            throw EvalFailure("invalid_query")
        case 0x22:
            _ = try string()
        default:
            let start = index
            while index < bytes.count, ![0x20, 0x09, 0x0a, 0x0d, 0x2c, 0x5d, 0x7d].contains(bytes[index]) {
                index += 1
            }
            guard start < index else { throw EvalFailure("invalid_query") }
            if let field, Self.arithmeticFields.contains(field),
               bytes[start] == 0x2d || (0x30...0x39).contains(bytes[start]) {
                let digits = bytes[start] == 0x2d ? (start + 1)..<index : start..<index
                guard bytes[digits].allSatisfy({ (0x30...0x39).contains($0) })
                else { throw EvalFailure("invalid_query") }
            }
        }
    }
}

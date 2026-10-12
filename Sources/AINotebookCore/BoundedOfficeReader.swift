import Foundation
import ZIPFoundation

/// One counter is shared by every expanded member, including metadata parts.
final class OfficeByteBudget {
    private(set) var used: Int64 = 0
    private let maximum: Int64

    init(declaredBytes: [Int64], maximum: Int64) throws {
        guard maximum >= 0 else { throw IngestionError(code: "officeLimit") }
        var declared: Int64 = 0
        for bytes in declaredBytes {
            guard bytes >= 0, bytes <= maximum - declared else { throw IngestionError(code: "officeLimit") }
            declared += bytes
        }
        self.maximum = maximum
    }

    func accept(_ count: Int) throws {
        guard count >= 0, let incoming = Int64(exactly: count), incoming <= maximum - used else {
            throw IngestionError(code: "officeLimit")
        }
        used += incoming
    }
}

struct OfficeXMLElement {
    let name: String
    let namespaceURI: String
    let attributes: [String: String]
    let namespaceAttributes: [String: String]

    func attribute(_ local: String, namespaceURI: String) -> String? {
        namespaceAttributes["{\(namespaceURI)}\(local)"]
    }
}

struct OfficeRelationship {
    let id: String
    let type: String
    let target: String
}

/// Archive members are extracted into private bounded spools, then parsed as
/// streams. Re-reading a part reuses its spool and never debits expansion twice.
final class BoundedOfficeReader {
    let limits: IngestionLimits
    let hooks: DocumentReadHooks
    private let archive: Archive
    private let budget: OfficeByteBudget
    private let entries: [Data: Entry]
    /// ASCII-case-folded member name -> the unique actual member name (nil when
    /// two members fold to the same name). OPC part names are case-insensitive.
    private let foldedEntries: [Data: Data?]
    private var spools: [Data: URL] = [:]
    private var temporaryDirectory: URL?
    private var relationshipCache: [Data: [String: OfficeRelationship]] = [:]

    private static let relationshipNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"
    /// Transitional and Strict (ISO 29500) relationship-type / attribute namespaces.
    static let officeRelationshipNamespaces = ["http://schemas.openxmlformats.org/officeDocument/2006/relationships",
                                               "http://purl.oclc.org/ooxml/officeDocument/relationships"]
    private static let wordNamespaces: Set<String> = ["http://schemas.openxmlformats.org/wordprocessingml/2006/main",
                                                      "http://purl.oclc.org/ooxml/wordprocessingml/main"]
    private static let presentationNamespaces: Set<String> = ["http://schemas.openxmlformats.org/presentationml/2006/main",
                                                              "http://purl.oclc.org/ooxml/presentationml/main"]
    private static let drawingNamespaces: Set<String> = ["http://schemas.openxmlformats.org/drawingml/2006/main",
                                                         "http://purl.oclc.org/ooxml/drawingml/main"]
    private static let compatibilityNamespace = "http://schemas.openxmlformats.org/markup-compatibility/2006"

    static func isOfficeRelationship(_ type: String, kind: String) -> Bool {
        officeRelationshipNamespaces.contains { type == $0 + "/" + kind }
    }

    init(url: URL, limits: IngestionLimits, hooks: DocumentReadHooks = DocumentReadHooks()) throws {
        self.limits = limits
        self.hooks = hooks
        do {
            guard url.isFileURL else { throw IngestionError(code: "corruptArchive") }
            try Task.checkCancellation()
            let preflight = try OfficeZIPPreflight.read(url: url, maximumFileBytes: limits.fileBytes)
            budget = try OfficeByteBudget(declaredBytes: preflight.sizes, maximum: limits.officeBytes)
            archive = try Archive(url: url, accessMode: .read)
            var allEntries: [Data: Entry] = [:]
            var count = 0
            for entry in archive {
                try Task.checkCancellation()
                guard count < preflight.sizes.count, entry.type != .symlink,
                      entry.uncompressedSize == UInt64(preflight.sizes[count]) else {
                    throw IngestionError(code: "corruptArchive")
                }
                let path = try Self.normalizedPath(entry.path, base: [], error: "corruptArchive")
                let key = Data(path.utf8)
                guard allEntries[key] == nil else { throw IngestionError(code: "corruptArchive") }
                allEntries[key] = entry
                count += 1
            }
            // ZIPFoundation's iterator otherwise silently stops at malformed or
            // encrypted entries, which would omit unused members from preflight.
            guard count == preflight.sizes.count else { throw IngestionError(code: "corruptArchive") }
            entries = allEntries
            var folded: [Data: Data?] = [:]
            for (key, entry) in allEntries where entry.type == .file {
                let lower = Self.asciiFolded(key)
                folded[lower] = folded[lower] == nil ? key : .some(nil)
            }
            foldedEntries = folded
        } catch let error as IngestionError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw IngestionError(code: "corruptArchive") }
    }

    deinit { close() }

    func close() {
        let urls = Array(spools.values)
        spools.removeAll()
        for url in urls {
            try? FileManager.default.removeItem(at: url)
            try? hooks.event("spoolClose", 1)
        }
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
    }

    func hasPart(_ path: String) -> Bool {
        entries[Data(path.utf8)]?.type == .file
    }

    /// The member named `path`, or the unique member equal to it ignoring ASCII case.
    func resolvePart(_ path: String) -> String? {
        if hasPart(path) { return path }
        guard let match = foldedEntries[Self.asciiFolded(Data(path.utf8))], let match else { return nil }
        return String(decoding: match, as: UTF8.self)
    }

    private static func asciiFolded(_ data: Data) -> Data {
        Data(data.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 })
    }

    /// The package's main part: the single officeDocument relationship target,
    /// else the conventional part when the package relationships are missing,
    /// malformed or name no usable target. Neither -> `missingMainPart`.
    func officeDocumentPart(conventional: String) throws -> String {
        var relationships: [String: OfficeRelationship] = [:]
        do { relationships = try self.relationships(for: "") }
        catch let error as IngestionError where ["invalidRelationship", "corruptArchive"].contains(error.code) {}
        let documents = relationships.values.filter { Self.isOfficeRelationship($0.type, kind: "officeDocument") }
        guard documents.count <= 1 else { throw IngestionError(code: "invalidRelationship") }
        if let document = documents.first, hasPart(document.target) { return document.target }
        if let part = resolvePart(conventional) { return part }
        throw IngestionError(code: "missingMainPart")
    }

    func read(kind: SourceType) throws -> CanonicalDocument {
        try Task.checkCancellation()
        let document: CanonicalDocument
        switch kind {
        case .docx: document = try readWord()
        case .pptx: document = try readPresentation()
        case .xlsx: document = try XlsxReader.read(self)
        default: throw IngestionError(code: "unsupportedSyntax")
        }
        return CanonicalDocument(text: document.text, title: try title(), kind: document.kind,
                                 pages: document.pages, sheetNames: document.sheetNames, encoding: nil)
    }

    func relationships(for part: String) throws -> [String: OfficeRelationship] {
        let key = Data(part.utf8)
        if let cached = relationshipCache[key] { return cached }
        let parts = part.split(separator: "/").map(String.init)
        let conventional = parts.isEmpty ? "_rels/.rels"
            : (parts.dropLast() + ["_rels", parts.last! + ".rels"]).joined(separator: "/")
        guard let path = resolvePart(conventional) else {
            relationshipCache[key] = [:]
            return [:]
        }
        var result: [String: OfficeRelationship] = [:]
        var rejected = Set<String>()
        var depth = 0
        var sawRoot = false
        try parse(path, onStart: { element in
            depth += 1
            if depth == 1 {
                guard element.name == "Relationships", element.namespaceURI == Self.relationshipNamespace else {
                    throw IngestionError(code: "invalidRelationship")
                }
                sawRoot = true
            } else if depth == 2, element.name == "Relationship", element.namespaceURI == Self.relationshipNamespace {
                // External targets (hyperlinks, linked files) are never followed.
                // A duplicate Id or an unusable internal target only invalidates that
                // Id: it fails extraction solely when a required part needs it.
                guard let id = element.attributes["Id"], !id.isEmpty,
                      element.attributes["TargetMode"] != "External" else { return }
                guard !rejected.contains(id), result.removeValue(forKey: id) == nil else {
                    rejected.insert(id)
                    return
                }
                guard let type = element.attributes["Type"], !type.isEmpty,
                      let target = element.attributes["Target"],
                      element.attributes["TargetMode"] == nil || element.attributes["TargetMode"] == "Internal",
                      let normalized = Self.resolvedTarget(target, base: Array(parts.dropLast())) else {
                    rejected.insert(id)
                    return
                }
                result[id] = OfficeRelationship(id: id, type: type, target: self.resolvePart(normalized) ?? normalized)
            }
        }, onText: { _ in }, onEnd: { _ in depth -= 1 })
        guard sawRoot else { throw IngestionError(code: "invalidRelationship") }
        relationshipCache[key] = result
        return result
    }

    /// Resolves an internal relationship target against its source directory.
    /// A leading "/" is package-absolute. Nil for targets that are not a plain
    /// in-package part name (traversal above the root, control characters,
    /// backslash, ':', '?', '#', bad percent-encoding).
    static func resolvedTarget(_ target: String, base: [String]) -> String? {
        guard let decoded = target.removingPercentEncoding, !decoded.isEmpty else { return nil }
        let absolute = decoded.hasPrefix("/")
        return try? normalizedPath(absolute ? String(decoded.dropFirst()) : decoded,
                                   base: absolute ? [] : base, error: "invalidRelationship")
    }

    func parse(_ path: String,
               onStart: @escaping (OfficeXMLElement) throws -> Void,
               onText: @escaping (String) throws -> Void,
               onEnd: @escaping (OfficeXMLElement) throws -> Void) throws {
        let url = try spool(for: path)
        guard let stream = InputStream(url: url) else { throw IngestionError(code: "corruptArchive") }
        stream.open()
        defer { stream.close() }
        let parser = XMLParser(stream: stream)
        let delegate = OfficeXMLDelegate(onStart: onStart, onText: onText, onEnd: onEnd)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        let success = parser.parse()
        if let error = delegate.error { throw error }
        guard success else { throw IngestionError(code: "corruptArchive") }
        try Task.checkCancellation()
    }

    private func spool(for path: String) throws -> URL {
        let key = Data(path.utf8)
        if let cached = spools[key] { return cached }
        guard let entry = entries[key], entry.type == .file else { throw IngestionError(code: "invalidRelationship") }
        if temporaryDirectory == nil {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ainotebook-office-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            temporaryDirectory = directory
        }
        let url = temporaryDirectory!.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw IngestionError(code: "corruptArchive")
        }
        spools[key] = url
        do {
            try hooks.event("spoolOpen", 1)
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            var detector = OfficeDoctypeDetector()
            var actual: UInt64 = 0
            let checksum = try archive.extract(entry, bufferSize: 65_536) { bytes in
                try Task.checkCancellation()
                try budget.accept(bytes.count)
                try hooks.event("expanded", bytes.count)
                try detector.accept(bytes)
                actual += UInt64(bytes.count)
                try file.write(contentsOf: bytes)
            }
            guard checksum == entry.checksum, actual == entry.uncompressedSize else {
                throw IngestionError(code: "corruptArchive")
            }
            return url
        } catch {
            spools.removeValue(forKey: key)
            try? FileManager.default.removeItem(at: url)
            try? hooks.event("spoolClose", 1)
            if error is CancellationError { throw CancellationError() }
            if let error = error as? IngestionError { throw error }
            throw IngestionError(code: "corruptArchive")
        }
    }

    private static func normalizedPath(_ supplied: String, base: [String], error: String) throws -> String {
        guard !supplied.isEmpty, !supplied.hasPrefix("/"),
              !supplied.unicodeScalars.contains(where: { $0.value < 0x20 || [0x5C, 0x3A, 0x3F, 0x23].contains($0.value) }) else {
            throw IngestionError(code: error)
        }
        var components = base
        for component in supplied.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { throw IngestionError(code: error) }
                components.removeLast()
            } else { components.append(String(component)) }
        }
        guard !components.isEmpty else { throw IngestionError(code: error) }
        return components.joined(separator: "/")
    }

    private func readWord() throws -> CanonicalDocument {
        let path = try officeDocumentPart(conventional: "word/document.xml")
        var output = try CanonicalTextBuilder(maxScalars: limits.textScalars)
        var flow = OfficeParagraphFlow(namespaces: Self.wordNamespaces, runs: ["r"], breakParents: ["r"], tabs: true)
        var bodyDepth: Int?
        var sawDocument = false
        try parse(path, onStart: { element in
            if flow.depth == 0 {
                guard element.name == "document", Self.wordNamespaces.contains(element.namespaceURI) else {
                    throw IngestionError(code: "corruptArchive")
                }
                sawDocument = true
            }
            if flow.depth == 1, element.name == "body", Self.wordNamespaces.contains(element.namespaceURI) { bodyDepth = 2 }
            try flow.start(element, active: bodyDepth != nil, into: &output)
        }, onText: { text in
            try flow.text(text, into: &output)
        }, onEnd: { _ in
            if bodyDepth == flow.depth { bodyDepth = nil }
            flow.end()
        })
        guard sawDocument else { throw IngestionError(code: "corruptArchive") }
        return CanonicalDocument(text: output.text, title: nil, kind: "docx", pages: [], sheetNames: [], encoding: nil)
    }

    private func readPresentation() throws -> CanonicalDocument {
        let path = try officeDocumentPart(conventional: "ppt/presentation.xml")
        let relations = try relationships(for: path)
        var slideIDs: [String] = []
        var depth = 0
        var listDepth: Int?
        try parse(path, onStart: { element in
            depth += 1
            let presentation = Self.presentationNamespaces.contains(element.namespaceURI)
            if depth == 1, element.name != "presentation" || !presentation {
                throw IngestionError(code: "corruptArchive")
            }
            if element.name == "sldIdLst", presentation { listDepth = depth }
            if let listDepth, depth == listDepth + 1, element.name == "sldId", presentation {
                guard let id = Self.officeRelationshipNamespaces.lazy
                        .compactMap({ element.attribute("id", namespaceURI: $0) }).first else {
                    throw IngestionError(code: "invalidRelationship")
                }
                // Every slide necessarily emits at least this many scalars.
                guard slideIDs.count < self.limits.textScalars / 11 + 1 else { throw IngestionError(code: "textLimit") }
                slideIDs.append(id)
            }
        }, onText: { _ in }, onEnd: { _ in
            if listDepth == depth { listDepth = nil }
            depth -= 1
        })
        var output = try CanonicalTextBuilder(maxScalars: limits.textScalars)
        for (index, id) in slideIDs.enumerated() {
            guard let relationship = relations[id], Self.isOfficeRelationship(relationship.type, kind: "slide"),
                  hasPart(relationship.target) else {
                throw IngestionError(code: "invalidRelationship")
            }
            if index > 0 { try output.append("\n\n") }
            try output.append("## Slide \(index + 1)\n")
            var flow = OfficeParagraphFlow(namespaces: Self.drawingNamespaces, runs: ["r", "fld"], breakParents: ["p"], tabs: false)
            try parse(relationship.target, onStart: { element in
                if flow.depth == 0, element.name != "sld" || !Self.presentationNamespaces.contains(element.namespaceURI) {
                    throw IngestionError(code: "corruptArchive")
                }
                try flow.start(element, active: true, into: &output)
            }, onText: { text in
                try flow.text(text, into: &output)
            }, onEnd: { _ in flow.end() })
        }
        return CanonicalDocument(text: output.text, title: nil, kind: "pptx", pages: [], sheetNames: [], encoding: nil)
    }

    /// Best effort: a missing, ambiguous or unreadable core-properties part
    /// leaves the title empty instead of failing the whole document.
    private func title() throws -> String? {
        do { return try readTitle() }
        catch let error as IngestionError where ["invalidRelationship", "corruptArchive"].contains(error.code) { return nil }
    }

    private func readTitle() throws -> String? {
        let root = (try? relationships(for: "")) ?? [:]
        let metadata = root.values.filter { $0.type == Self.relationshipNamespace + "/metadata/core-properties" }
        guard metadata.count <= 1 else { return nil }
        let path: String
        if let relation = metadata.first, hasPart(relation.target) { path = relation.target }
        else if let conventional = resolvePart("docProps/core.xml") { path = conventional }
        else { return nil }
        var title = try CanonicalTextBuilder(maxScalars: limits.textScalars)
        var depth = 0
        var titleDepth: Int?
        try parse(path, onStart: { element in
            depth += 1
            if element.name == "title", element.namespaceURI == "http://purl.org/dc/elements/1.1/" { titleDepth = depth }
        }, onText: { text in
            if titleDepth != nil { try title.append(text) }
        }, onEnd: { _ in
            if titleDepth == depth { titleDepth = nil }
            depth -= 1
        })
        return title.text.unicodeScalars.contains(where: { !ScalarChunker.isWhitespace($0.value) }) ? title.text : nil
    }
}

/// Paragraph text in document order, shared by Word bodies and slides (same
/// rules on Windows): every paragraph start after the first begins a new line,
/// including paragraphs nested in text boxes; text that continues an outer
/// paragraph after a nested one starts a new line too. Only text/tab/break
/// elements that are direct children of a run (or, for slide breaks, of the
/// paragraph) count, so tab-stop definitions in paragraph properties are not
/// text. `mc:Fallback` duplicates its `mc:Choice` and is skipped.
struct OfficeParagraphFlow {
    private let namespaces: Set<String>
    private let runs: Set<String>
    private let breakParents: Set<String>
    private let tabs: Bool
    /// Own-namespace local name per open element ("" for foreign elements).
    private var stack: [String] = []
    private var paragraphDepths: [Int] = []
    private var fallbackDepth: Int?
    private var textDepth: Int?
    private var paragraphs = 0
    private var pendingBreak = false

    init(namespaces: Set<String>, runs: Set<String>, breakParents: Set<String>, tabs: Bool) {
        self.namespaces = namespaces
        self.runs = runs
        self.breakParents = breakParents
        self.tabs = tabs
    }

    var depth: Int { stack.count }

    mutating func start(_ element: OfficeXMLElement, active: Bool, into output: inout CanonicalTextBuilder) throws {
        let parent = stack.last ?? ""
        let name = namespaces.contains(element.namespaceURI) ? element.name : ""
        stack.append(name)
        guard active, fallbackDepth == nil else { return }
        if element.name == "Fallback", element.namespaceURI == "http://schemas.openxmlformats.org/markup-compatibility/2006" {
            fallbackDepth = stack.count
            return
        }
        switch name {
        case "p":
            if paragraphs > 0 { try output.append("\n") }
            paragraphs += 1
            pendingBreak = false
            paragraphDepths.append(stack.count)
        case "t" where runs.contains(parent): textDepth = stack.count
        case "tab" where tabs && runs.contains(parent): try emit("\t", into: &output)
        case "br" where breakParents.contains(parent): try emit("\n", into: &output)
        default: break
        }
    }

    mutating func text(_ text: String, into output: inout CanonicalTextBuilder) throws {
        guard textDepth == stack.count else { return }
        try emit(text, into: &output)
    }

    mutating func end() {
        if textDepth == stack.count { textDepth = nil }
        if fallbackDepth == stack.count { fallbackDepth = nil }
        if paragraphDepths.last == stack.count {
            paragraphDepths.removeLast()
            pendingBreak = true
        }
        stack.removeLast()
    }

    private mutating func emit(_ text: String, into output: inout CanonicalTextBuilder) throws {
        if pendingBreak {
            try output.append("\n")
            pendingBreak = false
        }
        try output.append(text)
    }
}

/// The ASCII markup token is identical in supported XML byte encodings apart
/// from UTF-16/32 zero padding. Detect across decompressor block boundaries,
/// before XMLParser can expand any DTD. Delegate checks provide a second guard.
private struct OfficeDoctypeDetector {
    private enum Mode { case markup, comment, cdata, instruction }
    private var mode = Mode.markup
    private var recent: [UInt8] = []
    mutating func accept(_ bytes: Data) throws {
        for byte in bytes where byte != 0 {
            recent.append(byte)
            if recent.count > 9 { recent.removeFirst() }
            switch mode {
            case .comment:
                if recent.suffix(3).elementsEqual("-->".utf8) { mode = .markup; recent.removeAll(keepingCapacity: true) }
            case .cdata:
                if recent.suffix(3).elementsEqual("]]>".utf8) { mode = .markup; recent.removeAll(keepingCapacity: true) }
            case .instruction:
                if recent.suffix(2).elementsEqual("?>".utf8) { mode = .markup; recent.removeAll(keepingCapacity: true) }
            case .markup:
                if recent.suffix(4).elementsEqual("<!--".utf8) { mode = .comment; recent.removeAll(keepingCapacity: true) }
                else if recent.elementsEqual("<![CDATA[".utf8) { mode = .cdata; recent.removeAll(keepingCapacity: true) }
                else if recent.suffix(2).elementsEqual("<?".utf8) { mode = .instruction; recent.removeAll(keepingCapacity: true) }
                else if recent.elementsEqual("<!DOCTYPE".utf8) { throw IngestionError(code: "corruptArchive") }
            }
        }
    }
}

private final class OfficeXMLDelegate: NSObject, XMLParserDelegate {
    let onStart: (OfficeXMLElement) throws -> Void
    let onText: (String) throws -> Void
    let onEnd: (OfficeXMLElement) throws -> Void
    var error: Error?
    private var namespaces: [String: [String]] = [:]
    private var stack: [OfficeXMLElement] = []

    init(onStart: @escaping (OfficeXMLElement) throws -> Void,
         onText: @escaping (String) throws -> Void,
         onEnd: @escaping (OfficeXMLElement) throws -> Void) {
        self.onStart = onStart
        self.onText = onText
        self.onEnd = onEnd
    }

    private func perform(_ parser: XMLParser, _ action: () throws -> Void) {
        guard error == nil else { return }
        do { try Task.checkCancellation(); try action() }
        catch { self.error = error; parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        namespaces[prefix, default: []].append(namespaceURI)
    }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        _ = namespaces[prefix]?.popLast()
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        perform(parser) {
            var resolved: [String: String] = [:]
            for (name, value) in attributeDict {
                let parts = name.split(separator: ":", maxSplits: 1)
                if parts.count == 2, let uri = namespaces[String(parts[0])]?.last {
                    resolved["{\(uri)}\(parts[1])"] = value
                }
            }
            let element = OfficeXMLElement(name: elementName, namespaceURI: namespaceURI ?? "",
                                           attributes: attributeDict, namespaceAttributes: resolved)
            stack.append(element)
            try onStart(element)
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { perform(parser) { try onText(string) } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        perform(parser) {
            guard let text = String(data: CDATABlock, encoding: .utf8) else { throw IngestionError(code: "corruptArchive") }
            try onText(text)
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        perform(parser) {
            guard let element = stack.popLast() else { throw IngestionError(code: "corruptArchive") }
            try onEnd(element)
        }
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        perform(parser) { throw IngestionError(code: "corruptArchive") }
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        perform(parser) { throw IngestionError(code: "corruptArchive") }
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        perform(parser) { throw IngestionError(code: "corruptArchive") }
        return nil
    }
}

/// Inspect the complete directory independently: ZIPFoundation exposes neither
/// encryption flags nor its expected member count, and its iterator can stop
/// silently. Every read here is a bounded header/extra-field read, never a copy
/// of the complete archive. ZIP64 values are validated before library access.
private enum OfficeZIPPreflight {
    struct Result { let sizes: [Int64] }

    static func read(url: URL, maximumFileBytes: Int64) throws -> Result {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard maximumFileBytes >= 0, length <= UInt64(maximumFileBytes) else { throw IngestionError(code: "fileLimit") }
        func corrupt() -> IngestionError { IngestionError(code: "corruptArchive") }
        func bytes(at offset: UInt64, count: Int) throws -> Data {
            try Task.checkCancellation()
            guard count >= 0, offset <= length, UInt64(count) <= length - offset else { throw corrupt() }
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: count) ?? Data()
            guard data.count == count else { throw corrupt() }
            return data
        }
        guard length >= 22 else { throw corrupt() }
        let tail = try bytes(at: length - min(length, 65_557), count: Int(min(length, 65_557)))
        // Prefer a record whose comment ends the file exactly; some writers leave
        // trailing bytes, so fall back to the last record whose comment fits.
        var endOffset: Int?
        var looseOffset: Int?
        for offset in stride(from: tail.count - 22, through: 0, by: -1)
            where try integer(tail, at: offset, width: 4) == 0x06054B50 {
            let comment = try integer(tail, at: offset + 20, width: 2)
            if comment == UInt64(tail.count - offset - 22) { endOffset = offset; break }
            if looseOffset == nil, comment <= UInt64(tail.count - offset - 22) { looseOffset = offset }
        }
        guard let endOffset = endOffset ?? looseOffset else { throw corrupt() }
        let endPosition = length - UInt64(tail.count) + UInt64(endOffset)
        guard try integer(tail, at: endOffset + 4, width: 2) == 0,
              try integer(tail, at: endOffset + 6, width: 2) == 0 else { throw corrupt() }
        var count = try integer(tail, at: endOffset + 10, width: 2)
        guard try integer(tail, at: endOffset + 8, width: 2) == count else { throw corrupt() }
        var directorySize = try integer(tail, at: endOffset + 12, width: 4)
        var directoryOffset = try integer(tail, at: endOffset + 16, width: 4)
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            guard endPosition >= 20 else { throw corrupt() }
            let locator = try bytes(at: endPosition - 20, count: 20)
            guard try integer(locator, at: 0, width: 4) == 0x07064B50,
                  try integer(locator, at: 4, width: 4) == 0,
                  try integer(locator, at: 16, width: 4) == 1 else { throw corrupt() }
            let recordOffset = try integer(locator, at: 8, width: 8)
            let record = try bytes(at: recordOffset, count: 56)
            let recordSize = try integer(record, at: 4, width: 8)
            guard try integer(record, at: 0, width: 4) == 0x06064B50,
                  recordSize >= 44, recordOffset <= endPosition - 20,
                  recordSize <= endPosition - 20 - recordOffset,
                  endPosition - 20 - recordOffset - recordSize >= 12,
                  try integer(record, at: 16, width: 4) == 0,
                  try integer(record, at: 20, width: 4) == 0 else { throw corrupt() }
            count = try integer(record, at: 32, width: 8)
            guard try integer(record, at: 24, width: 8) == count else { throw corrupt() }
            directorySize = try integer(record, at: 40, width: 8)
            directoryOffset = try integer(record, at: 48, width: 8)
        }
        guard directoryOffset <= endPosition, directorySize <= endPosition - directoryOffset,
              count <= directorySize / 46 else { throw corrupt() }
        let directoryEnd = directoryOffset + directorySize
        var position = directoryOffset
        var sizes: [Int64] = []
        for _ in 0..<count {
            guard position <= directoryEnd, directoryEnd - position >= 46 else { throw corrupt() }
            let header = try bytes(at: position, count: 46)
            guard try integer(header, at: 0, width: 4) == 0x02014B50 else { throw corrupt() }
            let flags = try integer(header, at: 8, width: 2)
            let method = try integer(header, at: 10, width: 2)
            guard flags & 0x41 == 0, method == 0 || method == 8 else { throw corrupt() }
            let nameCount = Int(try integer(header, at: 28, width: 2))
            let extraCount = Int(try integer(header, at: 30, width: 2))
            let commentCount = Int(try integer(header, at: 32, width: 2))
            let additionalCount = nameCount + extraCount + commentCount
            guard nameCount > 0, UInt64(additionalCount) <= directoryEnd - position - 46 else { throw corrupt() }
            let additional = try bytes(at: position + 46, count: additionalCount)
            let name = additional.subdata(in: 0..<nameCount)
            guard !name.contains(0), flags & 0x800 == 0 || String(data: name, encoding: .utf8) != nil else { throw corrupt() }
            let extra = additional.subdata(in: nameCount..<(nameCount + extraCount))
            let zip64 = try zip64Field(extra)
            var zipOffset = 0
            func expanded(_ value: UInt64, sentinel: UInt64, width: Int) throws -> UInt64 {
                guard value == sentinel else { return value }
                guard let zip64 else { throw corrupt() }
                defer { zipOffset += width }
                return try integer(zip64, at: zipOffset, width: width)
            }
            let uncompressed = try expanded(integer(header, at: 24, width: 4), sentinel: 0xFFFF_FFFF, width: 8)
            let compressed = try expanded(integer(header, at: 20, width: 4), sentinel: 0xFFFF_FFFF, width: 8)
            let localOffset = try expanded(integer(header, at: 42, width: 4), sentinel: 0xFFFF_FFFF, width: 8)
            let disk = try expanded(integer(header, at: 34, width: 2), sentinel: 0xFFFF, width: 4)
            guard disk == 0, localOffset <= directoryOffset, directoryOffset - localOffset >= 30 else { throw corrupt() }
            let host = try integer(header, at: 4, width: 2) >> 8
            let mode = try integer(header, at: 38, width: 4) >> 16
            guard !([3, 19].contains(host) && mode & 0xF000 == 0xA000) else { throw corrupt() }
            let local = try bytes(at: localOffset, count: 30)
            // Writers disagree on non-security flag bits between the two headers; the
            // local header decides where its sizes live (bit 3: data descriptor).
            let localFlags = try integer(local, at: 6, width: 2)
            guard try integer(local, at: 0, width: 4) == 0x04034B50, localFlags & 0x41 == 0,
                  try integer(local, at: 8, width: 2) == method else { throw corrupt() }
            let localNameCount = Int(try integer(local, at: 26, width: 2))
            let localExtraCount = Int(try integer(local, at: 28, width: 2))
            let localAdditionalCount = localNameCount + localExtraCount
            guard localNameCount == nameCount,
                  UInt64(localAdditionalCount) <= directoryOffset - localOffset - 30 else { throw corrupt() }
            let localAdditional = try bytes(at: localOffset + 30, count: localAdditionalCount)
            guard localAdditional.subdata(in: 0..<localNameCount) == name else { throw corrupt() }
            let localZip64 = try zip64Field(localAdditional.subdata(in: localNameCount..<localAdditionalCount))
            let dataOffset = localOffset + 30 + UInt64(localAdditionalCount)
            guard compressed <= directoryOffset - dataOffset else { throw corrupt() }
            if method == 0, compressed != uncompressed { throw corrupt() }
            if localFlags & 8 == 0 {
                var localUncompressed = try integer(local, at: 22, width: 4)
                var localCompressed = try integer(local, at: 18, width: 4)
                var offset = 0
                if localUncompressed == 0xFFFF_FFFF {
                    guard let localZip64 else { throw corrupt() }
                    localUncompressed = try integer(localZip64, at: offset, width: 8)
                    offset += 8
                }
                if localCompressed == 0xFFFF_FFFF {
                    guard let localZip64 else { throw corrupt() }
                    localCompressed = try integer(localZip64, at: offset, width: 8)
                }
                guard localUncompressed == uncompressed, localCompressed == compressed,
                      try integer(local, at: 14, width: 4) == integer(header, at: 16, width: 4) else { throw corrupt() }
            } else {
                let descriptorOffset = dataOffset + compressed
                // Same width rule as ZIPFoundation, which reads the descriptor afterwards.
                let isZIP64 = try integer(header, at: 6, width: 2) >= 45 || zip64 != nil
                let width = isZIP64 ? 8 : 4
                let prefix = try bytes(at: descriptorOffset, count: 4)
                let signatureBytes = try integer(prefix, at: 0, width: 4) == 0x08074B50 ? 4 : 0
                let descriptorCount = signatureBytes + 4 + 2 * width
                guard UInt64(descriptorCount) <= directoryOffset - descriptorOffset else { throw corrupt() }
                let descriptor = try bytes(at: descriptorOffset, count: descriptorCount)
                guard try integer(descriptor, at: signatureBytes, width: 4) == integer(header, at: 16, width: 4),
                      try integer(descriptor, at: signatureBytes + 4, width: width) == compressed,
                      try integer(descriptor, at: signatureBytes + 4 + width, width: width) == uncompressed else { throw corrupt() }
            }
            guard let declared = Int64(exactly: uncompressed) else { throw IngestionError(code: "officeLimit") }
            sizes.append(declared)
            position += UInt64(46 + additionalCount)
        }
        guard position == directoryEnd else { throw corrupt() }
        return Result(sizes: sizes)
    }

    private static func integer(_ data: Data, at offset: Int, width: Int) throws -> UInt64 {
        guard offset >= 0, offset <= data.count, width <= data.count - offset else {
            throw IngestionError(code: "corruptArchive")
        }
        var result: UInt64 = 0
        for index in 0..<width { result |= UInt64(data[data.startIndex + offset + index]) << (8 * index) }
        return result
    }

    private static func zip64Field(_ data: Data) throws -> Data? {
        var offset = 0
        var result: Data?
        while offset < data.count {
            let type = try integer(data, at: offset, width: 2)
            let count = Int(try integer(data, at: offset + 2, width: 2))
            offset += 4
            guard count <= data.count - offset else { throw IngestionError(code: "corruptArchive") }
            if type == 1 {
                guard result == nil else { throw IngestionError(code: "corruptArchive") }
                result = data.subdata(in: offset..<(offset + count))
            }
            offset += count
        }
        return result
    }
}

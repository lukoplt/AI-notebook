import Foundation
import XCTest
import ZIPFoundation
@testable import AINotebookCore

private final class ExtractionEvents: @unchecked Sendable {
    private let gate = NSLock()
    private var counts: [String: Int] = [:]
    func record(_ event: String, _ amount: Int) { gate.lock(); defer { gate.unlock() }; counts[event, default: 0] += amount }
    func count(_ event: String) -> Int { gate.lock(); defer { gate.unlock() }; return counts[event, default: 0] }
}

final class BoundedDocumentExtractorTests: XCTestCase {
    /// Office v1 cases; XLSX text cases superseded by `ingestion-xlsx-v2` carry their v2 expectation.
    private func rows() throws -> [[String: Any]] {
        try XCTUnwrap(SharedFixtures.json("contracts/ingestion-office-v1.json")["cases"] as? [[String: Any]])
            .map { try SpreadsheetSupersession.apply($0, fixture: "ingestion-office-v1.json") }
    }

    /// Compact spreadsheet canonical text v2 (`ingestion-xlsx-v2`), shared with Windows.
    func testSpreadsheetTextV2Cases() async throws {
        let all = try XCTUnwrap(SharedFixtures.json("contracts/ingestion-xlsx-v2.json")["cases"] as? [[String: Any]])
        let cases = all.filter { $0["operation"] as? String == "extract" }
        XCTAssertGreaterThanOrEqual(cases.count, 25)
        for row in cases { try await checkExtraction(row) }
    }

    func testWorkbookRelationshipOrderAndValues() async throws {
        let row = try XCTUnwrap(rows().first { $0["name"] as? String == "workbook-order" })
        let input = row["input"] as! [String: Any], expected = row["expected"] as! [String: Any]
        let result = try await BoundedDocumentExtractor().extract(url: SharedFixtures.url(input["asset"] as! String), kind: .xlsx, rules: .defaults)
        XCTAssertEqual(Array(result.text.utf8), Array((expected["text"] as! String).utf8))
        XCTAssertEqual(result.sheetNames, ["Zeta", "Alpha"])
    }

    func testPageLimitBeforeTextRead() async throws {
        let events = ExtractionEvents()
        let rules = FolderRules(includeExts: ["pdf"], ignoreGlobs: [], limits: try IngestionLimits(json: "{\"maxPdfPages\":1}"), encodingFallback: "none")
        do {
            _ = try await BoundedDocumentExtractor(hooks: DocumentReadHooks(event: events.record))
                .extract(url: SharedFixtures.url("ingestion/pages.pdf"), kind: .pdf, rules: rules)
            XCTFail("Expected pageLimit")
        } catch { XCTAssertEqual((error as? IngestionError)?.code, "pageLimit") }
        XCTAssertEqual(events.count("pageText"), 0)
    }

    func testAllOfficeCases() async throws {
        let cases = try rows()
        var visited = Set<String>()
        for row in cases {
            let name = row["name"] as! String
            XCTAssertTrue(visited.insert(name).inserted)
            switch row["operation"] as? String {
            case "extract": try await checkExtraction(row)
            case "bounded-stream": try checkStream(row)
            default: XCTFail("Unknown office operation: \(row)")
            }
        }
        XCTAssertEqual(visited, Set(cases.map { $0["name"] as! String }))
        XCTAssertEqual(visited.count, 29)
    }

    /// Real-world OPC packaging (absolute/relative/encoded/case-folded targets,
    /// external relationships, main-part fallback, text boxes) — shared with Windows.
    func testAllOOXMLPackagingCases() async throws {
        let all = try XCTUnwrap(SharedFixtures.json("contracts/ingestion-ooxml-v1.json")["cases"] as? [[String: Any]])
            .map { try SpreadsheetSupersession.apply($0, fixture: "ingestion-ooxml-v1.json") }
        XCTAssertEqual(Set(all.map { $0["name"] as! String }).count, all.count)
        let cases = all.filter { $0["operation"] as? String == "extract" }
        XCTAssertEqual(cases.count, 20)
        for row in cases { try await checkExtraction(row) }
    }

    /// Persisted error code -> localized explanation, and its EN/CS copy (shared with Windows).
    func testOOXMLErrorTextsAndCopy() throws {
        let all = try XCTUnwrap(SharedFixtures.json("contracts/ingestion-ooxml-v1.json")["cases"] as? [[String: Any]])
        let keys = Dictionary(uniqueKeysWithValues: AppText.Key.allCases.map { (String(describing: $0), $0) })
        let texts = all.filter { $0["operation"] as? String == "error-text" }
        XCTAssertEqual(texts.count, 18)
        for row in texts {
            let code = (row["input"] as! [String: Any])["code"] as! String
            let expected = (row["expected"] as! [String: Any])["key"] as? String
            XCTAssertEqual(IngestionErrorText.key(for: code).map { String(describing: $0) }, expected, code)
        }
        XCTAssertNil(IngestionErrorText.key(for: nil))
        let copy = all.filter { $0["operation"] as? String == "localization" }
        XCTAssertEqual(copy.count, 3)
        for row in copy {
            let key = try XCTUnwrap(keys[(row["input"] as! [String: Any])["key"] as! String])
            let e = row["expected"] as! [String: String]
            XCTAssertEqual(AppText(language: .english).string(key), e["en"])
            XCTAssertEqual(AppText(language: .czech).string(key), e["cs"])
        }
    }

    /// Valid ZIP layouts produced by real writers (System.IO.Packaging, Java, .NET
    /// streaming): data descriptors with and without signature, a descriptor flag
    /// only in the local header, trailing bytes after the end-of-central-directory
    /// record. The descriptor width follows "version needed >= 4.5" exactly as
    /// ZIPFoundation reads it. The Windows reader relies on .NET here.
    func testRealWorldZIPLayoutsAreNotCorrupt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rels = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"r1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"
        let xml = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>A</w:t></w:r></w:p></w:body></w:document>"
        let parts = [("_rels/.rels", Data(rels.utf8)), ("word/document.xml", Data(xml.utf8))]
        for layout in [ZIPLayout(descriptor: 4, version: 20), ZIPLayout(descriptor: 8, version: 45),
                       ZIPLayout(descriptor: 4, version: 20, signature: false),
                       ZIPLayout(descriptor: 4, version: 20, centralDescriptorFlag: false),
                       ZIPLayout(descriptor: 0, version: 20, trailing: Data("garbage".utf8))] {
            let url = directory.appendingPathComponent(UUID().uuidString + ".docx")
            try layout.archive(parts).write(to: url)
            do {
                let reader = try BoundedOfficeReader(url: url, limits: .defaults)
                defer { reader.close() }
                XCTAssertEqual(try reader.read(kind: .docx).text, "A", "\(layout)")
            } catch { XCTFail("\(layout): \(error)") }
        }
        // A descriptor that matches neither width is still corrupt.
        let url = directory.appendingPathComponent("bad.docx")
        var bad = ZIPLayout(descriptor: 4, version: 20)
        bad.corruptDescriptor = true
        try bad.archive(parts).write(to: url)
        XCTAssertThrowsError(try BoundedOfficeReader(url: url, limits: .defaults).read(kind: .docx)) {
            XCTAssertEqual(($0 as? IngestionError)?.code, "corruptArchive")
        }
    }

    func testCanonicalTextAndPDF() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, bytes, text) in [("a.md", Data("  A😀e\u{301}\r\n".utf8), "  A😀e\u{301}\r\n"),
                                  ("b.txt", Data([80, 248, 237, 108, 105, 154]), "Příliš"), ("empty.txt", Data(), "")] {
            let url = directory.appendingPathComponent(name)
            try bytes.write(to: url)
            let doc = try await BoundedDocumentExtractor().extract(url: url, kind: SourceType.detect(filename: name)!, rules: .defaults)
            XCTAssertEqual(Array(doc.text.utf8), Array(text.utf8))
        }
        try await checkExtraction(try XCTUnwrap(rows().first { $0["name"] as? String == "pages" }))
        let namespaced = "<d:document xmlns:d=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:e=\"urn:irrelevant\"><d:body><d:p><d:r><d:t>A</d:t><d:tab/><d:t>B</d:t><d:br/><d:t>😀</d:t></d:r><e:t>ignored</e:t></d:p><d:p/></d:body></d:document>"
        try await checkExtraction(["name": "docx-namespace-and-runs", "operation": "extract",
            "input": ["asset": "ingestion/paragraphs.docx", "kind": "docx", "limits": [:],
                      "mutations": [["entry": "word/document.xml", "operation": "replace-entry", "text": namespaced]]],
            "expected": ["text": "A\tB\n😀\n"]])
        let literalDTD = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><!-- <!DOCTYPE ignored> --><w:body><w:p><w:r><w:t><![CDATA[<!DOCTYPE example>]]></w:t></w:r></w:p></w:body></w:document>"
        try await checkExtraction(["name": "doctype-literal-is-text", "operation": "extract",
            "input": ["asset": "ingestion/paragraphs.docx", "kind": "docx", "limits": [:],
                      "mutations": [["entry": "word/document.xml", "operation": "replace-entry", "text": literalDTD]]],
            "expected": ["text": "<!DOCTYPE example>"]])
    }

    func testExpandedBytesActualCount() throws {
        for row in try rows() where row["operation"] as? String == "bounded-stream" { try checkStream(row) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let xml = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>A</w:t></w:r></w:p></w:body></w:document>"
        func archive(_ entries: [(String, Data, Entry.EntryType)]) throws -> URL {
            let url = directory.appendingPathComponent(UUID().uuidString + ".docx")
            let archive = try Archive(url: url, accessMode: .create)
            let rootRelationships = Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"doc\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>".utf8)
            for (path, data, type) in [("_rels/.rels", rootRelationships, Entry.EntryType.file)] + entries {
                try archive.addEntry(with: path, type: type, uncompressedSize: Int64(data.count)) { offset, count in
                    data.subdata(in: Int(offset)..<min(Int(offset) + count, data.count))
                }
            }
            return url
        }
        let valid = ("word/document.xml", Data(xml.utf8), Entry.EntryType.file)
        for entry in [("word/./document.xml", Data(xml.utf8), Entry.EntryType.file),
                      ("../outside.xml", Data(), Entry.EntryType.file),
                      ("/absolute.xml", Data(), Entry.EntryType.file),
                      ("unused-link", Data("outside".utf8), Entry.EntryType.symlink)] {
            let url = try archive([valid, entry])
            XCTAssertThrowsError(try BoundedOfficeReader(url: url, limits: .defaults).read(kind: .docx)) {
                XCTAssertEqual(($0 as? IngestionError)?.code, "corruptArchive")
            }
        }
        // An unused encrypted member must not silently truncate public ZIP iteration.
        let encrypted = try archive([valid, ("unused", Data([65]), .file)])
        var bytes = try Data(contentsOf: encrypted)
        for index in 0..<(bytes.count - 10) where Array(bytes[index..<index + 4]) == [0x50, 0x4B, 0x01, 0x02] {
            let nameLength = Int(bytes[index + 28]) | Int(bytes[index + 29]) << 8
            if String(data: bytes[(index + 46)..<(index + 46 + nameLength)], encoding: .utf8) == "unused" { bytes[index + 8] |= 1 }
        }
        try bytes.write(to: encrypted)
        XCTAssertThrowsError(try BoundedOfficeReader(url: encrypted, limits: .defaults).read(kind: .docx)) {
            XCTAssertEqual(($0 as? IngestionError)?.code, "corruptArchive")
        }
        let dtd = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE x [<!ENTITY a \"boom\">]>" + xml
        let utf16DTD = try archive([("word/document.xml", try XCTUnwrap(dtd.data(using: .utf16)), .file)])
        XCTAssertThrowsError(try BoundedOfficeReader(url: utf16DTD, limits: .defaults).read(kind: .docx)) {
            XCTAssertEqual(($0 as? IngestionError)?.code, "corruptArchive")
        }
    }

    func testCellAndScalarBounds() async throws {
        for row in try rows() where ["cell-limit", "text-limit"].contains(row["name"] as! String) { try await checkExtraction(row) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.txt")
        try Data([65, 66, 67]).write(to: url)
        let rules = FolderRules(includeExts: ["txt"], ignoreGlobs: [], limits: try IngestionLimits(json: "{\"maxFileBytes\":2}"), encodingFallback: "none")
        do {
            _ = try await BoundedDocumentExtractor().extract(url: url, kind: .text, rules: rules)
            XCTFail("Expected fileLimit")
        } catch { XCTAssertEqual((error as? IngestionError)?.code, "fileLimit") }
    }

    func testCancellationClosesReaders() async throws {
        let events = ExtractionEvents()
        let hooks = DocumentReadHooks { event, amount in
            events.record(event, amount)
            if event == "expanded" { throw CancellationError() }
        }
        do {
            _ = try await BoundedDocumentExtractor(hooks: hooks).extract(url: SharedFixtures.url("ingestion/workbook.xlsx"), kind: .xlsx, rules: .defaults)
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertGreaterThan(events.count("spoolOpen"), 0)
        XCTAssertEqual(events.count("spoolOpen"), events.count("spoolClose"))
        // A cancelled parse leaves no archive/stream state affecting the next extraction.
        let next = try await BoundedDocumentExtractor().extract(url: SharedFixtures.url("ingestion/paragraphs.docx"), kind: .docx, rules: .defaults)
        XCTAssertEqual(next.text, "A\nB😀\n")
    }

    private func checkStream(_ row: [String: Any]) throws {
        let i = row["input"] as! [String: Any], e = row["expected"] as! [String: Any]
        var reads = 0, accepted: Int64 = 0
        do {
            let budget = try OfficeByteBudget(declaredBytes: (i["declaredBytes"] as! [NSNumber]).map(\.int64Value), maximum: (i["maxOfficeDecompressedBytes"] as! NSNumber).int64Value)
            for block in i["blocks"] as! [[Int]] {
                reads += 1
                try budget.accept(block.count)
                accepted = budget.used
            }
            XCTAssertNil(e["error"], row["name"] as! String)
        } catch {
            guard let code = e["error"] as? String else { return XCTFail("Unexpected stream error: \(error)") }
            XCTAssertEqual((error as? IngestionError)?.code, code, row["name"] as! String)
        }
        XCTAssertEqual(reads, e["readCalls"] as? Int)
        XCTAssertEqual(accepted, (e["acceptedBytes"] as! NSNumber).int64Value)
    }

    private func checkExtraction(_ row: [String: Any]) async throws {
        let i = row["input"] as! [String: Any], e = row["expected"] as! [String: Any], name = row["name"] as! String
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mutations = i["mutations"] as! [[String: Any]]
        let original = SharedFixtures.url(i["asset"] as! String)
        let url: URL
        if mutations.isEmpty { url = original } else {
            url = directory.appendingPathComponent(original.lastPathComponent)
            let source = try Archive(url: original, accessMode: .read)
            let target = try Archive(url: url, accessMode: .create)
            for entry in source {
                let mutation = mutations.first { $0["entry"] as? String == entry.path }
                if mutation?["operation"] as? String == "remove-entry" { continue }
                var data = Data()
                if let mutation {
                    guard mutation["operation"] as? String == "replace-entry" else { return XCTFail("Unknown mutation") }
                    data = Data((mutation["text"] as! String).utf8)
                } else { _ = try source.extract(entry) { data.append($0) } }
                let bytes = data
                try target.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(bytes.count)) { offset, count in
                    bytes.subdata(in: Int(offset)..<min(Int(offset) + count, bytes.count))
                }
            }
        }
        let limitsJSON = String(decoding: try JSONSerialization.data(withJSONObject: i["limits"]!), as: UTF8.self)
        let rules = FolderRules(includeExts: FolderRules.defaults.includeExts, ignoreGlobs: [], limits: try IngestionLimits(json: limitsJSON), encodingFallback: "cp1250")
        let events = ExtractionEvents()
        do {
            let got = try await BoundedDocumentExtractor(hooks: DocumentReadHooks(event: events.record))
                .extract(url: url, kind: SourceType(rawValue: i["kind"] as! String)!, rules: rules)
            XCTAssertNil(e["error"], name)
            XCTAssertEqual(Array(got.text.utf8), Array((e["text"] as? String ?? "").utf8), name)
            if let names = e["sheetNames"] as? [String] { XCTAssertEqual(got.sheetNames, names, name) }
            if let pages = e["pages"] as? [[String: Int]] {
                XCTAssertEqual(got.pages, pages.map { PageBoundary(page: $0["page"]!, start: $0["start"]!, end: $0["end"]!) }, name)
            }
        } catch {
            guard let code = e["error"] as? String else { return XCTFail("\(name): unexpected \(error)") }
            XCTAssertEqual((error as? IngestionError)?.code, code, "\(name): \(error)")
        }
        if let cells = e["cellsMaterialized"] as? Int { XCTAssertEqual(events.count("cell"), cells, name) }
        if let pages = e["pageTextReads"] as? Int { XCTAssertEqual(events.count("pageText"), pages, name) }
        XCTAssertEqual(events.count("spoolOpen"), events.count("spoolClose"), name)
    }
}

/// Minimal stored-ZIP writer for layout variants ZIPFoundation cannot produce.
private struct ZIPLayout: CustomStringConvertible {
    var descriptor: Int          // 0 = sizes in the local header; 4/8 = data descriptor width
    var version: UInt16
    var signature = true
    var centralDescriptorFlag = true
    var trailing = Data()
    var corruptDescriptor = false

    var description: String { "descriptor=\(descriptor) version=\(version) signature=\(signature) central8=\(centralDescriptorFlag) trailing=\(trailing.count)" }

    func archive(_ parts: [(String, Data)]) -> Data {
        var out = Data(), central = Data()
        func le(_ value: UInt64, _ width: Int, into data: inout Data) {
            for i in 0..<width { data.append(UInt8((value >> (8 * UInt64(i))) & 0xFF)) }
        }
        for (name, body) in parts {
            let crc = UInt64(body.crc32(checksum: 0))
            let offset = UInt64(out.count)
            let flags: UInt64 = descriptor > 0 ? 8 : 0
            let size = UInt64(body.count)
            le(0x04034B50, 4, into: &out); le(UInt64(version), 2, into: &out); le(flags, 2, into: &out)
            le(0, 2, into: &out); le(0, 2, into: &out); le(0x21, 2, into: &out)
            le(descriptor > 0 ? 0 : crc, 4, into: &out)
            le(descriptor > 0 ? 0 : size, 4, into: &out); le(descriptor > 0 ? 0 : size, 4, into: &out)
            le(UInt64(name.utf8.count), 2, into: &out); le(0, 2, into: &out)
            out.append(contentsOf: name.utf8); out.append(body)
            if descriptor > 0 {
                if signature { le(0x08074B50, 4, into: &out) }
                le(crc, 4, into: &out)
                le(size + (corruptDescriptor ? 1 : 0), descriptor, into: &out); le(size, descriptor, into: &out)
            }
            le(0x02014B50, 4, into: &central); le(20, 2, into: &central); le(UInt64(version), 2, into: &central)
            le(centralDescriptorFlag ? flags : 0, 2, into: &central); le(0, 2, into: &central)
            le(0, 2, into: &central); le(0x21, 2, into: &central); le(crc, 4, into: &central)
            le(size, 4, into: &central); le(size, 4, into: &central)
            le(UInt64(name.utf8.count), 2, into: &central); le(0, 2, into: &central); le(0, 2, into: &central)
            le(0, 2, into: &central); le(0, 2, into: &central); le(0, 4, into: &central); le(offset, 4, into: &central)
            central.append(contentsOf: name.utf8)
        }
        let directoryOffset = UInt64(out.count)
        out.append(central)
        le(0x06054B50, 4, into: &out); le(0, 2, into: &out); le(0, 2, into: &out)
        le(UInt64(parts.count), 2, into: &out); le(UInt64(parts.count), 2, into: &out)
        le(UInt64(central.count), 4, into: &out); le(directoryOffset, 4, into: &out); le(0, 2, into: &out)
        out.append(trailing)
        return out
    }
}

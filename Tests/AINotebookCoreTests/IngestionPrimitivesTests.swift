import Foundation
import XCTest
@testable import AINotebookCore

final class IngestionPrimitivesTests: XCTestCase {
    private func cases(_ name: String) throws -> [[String: Any]] {
        try XCTUnwrap(SharedFixtures.json("contracts/\(name)-v1.json")["cases"] as? [[String: Any]])
    }

    func testStrictEncodingFixtures() throws {
        let rows = try cases("ingestion-encoding")
        var visited = Set<String>()
        for c in rows {
            let name = try XCTUnwrap(c["name"] as? String)
            XCTAssertTrue(visited.insert(name).inserted)
            guard c["operation"] as? String == "decode" else { return XCTFail("Unknown operation: \(c)") }
            let i = c["input"] as! [String: Any], e = c["expected"] as! [String: Any]
            let bytes = Data((i["bytes"] as! [Int]).map { UInt8($0) })
            func stream() throws -> DecodedText {
                var offset = 0
                return try TextDecoding.decode(read: {
                    guard offset < bytes.count else { return nil }
                    defer { offset += 1 }
                    return Data([bytes[offset]])
                }, rewind: { offset = 0 }, fallback: i["fallback"] as! String, maxScalars: 100)
            }
            if let code = e["error"] as? String {
                XCTAssertThrowsError(try TextDecoding.decode(bytes, fallback: i["fallback"] as! String, maxScalars: 100), name) {
                    XCTAssertEqual(($0 as? IngestionError)?.code, code, name)
                }
                XCTAssertThrowsError(try stream(), name) { XCTAssertEqual(($0 as? IngestionError)?.code, code, name) }
            } else {
                let got = try TextDecoding.decode(bytes, fallback: i["fallback"] as! String, maxScalars: 100)
                XCTAssertEqual(Array(got.text.utf8), Array((e["text"] as! String).utf8), name)
                XCTAssertEqual(got.encoding, e["encoding"] as? String, name)
                let streamed = try stream()
                XCTAssertEqual(Array(streamed.text.utf8), Array((e["text"] as! String).utf8), name)
                XCTAssertEqual(streamed.encoding, e["encoding"] as? String, name)
            }
        }
        XCTAssertEqual(visited, Set(rows.map { $0["name"] as! String }))
    }

    func testGlobUsesPinnedSimpleLowercase() throws {
        let tables = try UnicodeTables.bundled()
        XCTAssertTrue(try FolderGlob("/İ/**/𐐀?.md/", caseSensitive: false, tables: tables).matches("i/𐐨😀.md"))
        XCTAssertThrowsError(try FolderGlob("///", caseSensitive: true, tables: tables))
        XCTAssertFalse(try FolderGlob("é", caseSensitive: true, tables: tables).matches("e\u{301}"))
        XCTAssertFalse(try FolderGlob("?", caseSensitive: true, tables: tables).matches("e\u{301}"))
    }

    func testAllGlobFixtures() throws {
        let tables = try UnicodeTables.bundled(), rows = try cases("glob")
        XCTAssertEqual(rows.count, 53)
        var visited = Set<String>()
        for c in rows {
            let name = c["name"] as! String
            XCTAssertTrue(visited.insert(name).inserted)
            if let code = c["expectedError"] as? String {
                XCTAssertThrowsError(try FolderGlob(c["pattern"] as! String, caseSensitive: c["caseSensitive"] as! Bool, tables: tables)) {
                    XCTAssertEqual(($0 as? IngestionError)?.code, code, name)
                }
            } else {
                XCTAssertEqual(try FolderGlob(c["pattern"] as! String, caseSensitive: c["caseSensitive"] as! Bool, tables: tables)
                    .matches(c["path"] as! String), c["matches"] as! Bool, name)
            }
        }
        XCTAssertEqual(visited, Set(rows.map { $0["name"] as! String }))
    }

    func testCanonicalAndSpans() throws {
        let rows = try cases("ingestion-canonical")
        var visited = Set<String>()
        for c in rows {
            let name = c["name"] as! String
            XCTAssertTrue(visited.insert(name).inserted)
            guard c["operation"] as? String == "canonical" else { return XCTFail("Unknown operation: \(c)") }
            let i = c["input"] as! [String: Any], e = c["expected"] as! [String: Any]
            func run() throws -> (CanonicalDocument, [RevisionChunkDraft]) {
                let doc = try CanonicalText.assemble(kind: i["kind"] as! String, parts: i["parts"] as! [String],
                    names: i["names"] as! [String], maxScalars: i["maxScalars"] as! Int)
                return (doc, try ScalarChunker.bounded(doc.text, pages: doc.pages, window: i["window"] as! Int,
                    overlap: i["overlap"] as! Int, maxChunks: i["maxChunks"] as! Int))
            }
            if let code = e["error"] as? String {
                XCTAssertThrowsError(try run(), name) { XCTAssertEqual(($0 as? IngestionError)?.code, code, name) }
                continue
            }
            let (doc, chunks) = try run()
            XCTAssertEqual(Array(doc.text.utf8), Array((e["text"] as! String).utf8), name)
            let pages = (e["pages"] as! [[String: Int]]).map { PageBoundary(page: $0["page"]!, start: $0["start"]!, end: $0["end"]!) }
            XCTAssertEqual(doc.pages, pages, name)
            let expected = e["chunks"] as! [[String: Any]]
            XCTAssertEqual(chunks.count, expected.count, name)
            for (chunk, value) in zip(chunks, expected) {
                XCTAssertEqual(Array(chunk.text.utf8), Array((value["text"] as! String).utf8), name)
                XCTAssertEqual(chunk.charStart, value["start"] as? Int, name)
                XCTAssertEqual(chunk.charEnd, value["end"] as? Int, name)
                XCTAssertEqual(chunk.tokenCount, value["tokens"] as? Int, name)
                let intersects = pages.filter { $0.start < $0.end && $0.start < chunk.charEnd! && $0.end > chunk.charStart! }
                XCTAssertEqual(chunk.pageHint, value["pageFrom"] as? Int, name)
                XCTAssertEqual(intersects.first?.page, value["pageFrom"] as? Int, name)
                XCTAssertEqual(intersects.last?.page, value["pageTo"] as? Int, name)
            }
        }
        XCTAssertEqual(visited, Set(rows.map { $0["name"] as! String }))
    }

    func testLimitsBeforeAppend() throws {
        for bytes in [Data("😀e\u{301}".utf8), Data([255, 254, 61, 216, 0, 222, 101, 0, 1, 3]), Data([0xF8, 0xED, 0x9A])] {
            XCTAssertThrowsError(try TextDecoding.decode(bytes, fallback: "cp1250", maxScalars: 2)) {
                XCTAssertEqual(($0 as? IngestionError)?.code, "textLimit")
            }
            XCTAssertEqual(try TextDecoding.decode(bytes, fallback: "cp1250", maxScalars: 3).text.unicodeScalars.count, 3)
        }
        XCTAssertThrowsError(try CanonicalText.assemble(kind: "pdf", parts: ["a", "b"], maxScalars: 3)) {
            XCTAssertEqual(($0 as? IngestionError)?.code, "textLimit")
        }
        XCTAssertEqual(try CanonicalText.assemble(kind: "pdf", parts: ["a", "b"], maxScalars: 4).text, "a\n\nb")
        XCTAssertThrowsError(try ScalarChunker.bounded("abcdef", pages: [], window: 2, overlap: 0, maxChunks: 2)) {
            XCTAssertEqual(($0 as? IngestionError)?.code, "chunkLimit")
        }
        XCTAssertNil(try ScalarChunker.bounded("x", pages: [PageBoundary(page: 1, start: 0, end: 0)], maxChunks: 1).first?.pageHint)
        for b: UInt8 in [0x81, 0x83, 0x88, 0x90, 0x98] {
            XCTAssertThrowsError(try TextDecoding.decode(Data([b]), fallback: "cp1250", maxScalars: 10))
        }
        for bytes: [UInt8] in [[0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82], [0xFF, 0xFE, 0, 0xDC]] {
            XCTAssertThrowsError(try TextDecoding.decode(Data(bytes), fallback: "none", maxScalars: 10))
        }
    }

    func testRuleValidation() throws {
        let tables = try UnicodeTables.bundled()
        let normalized = try FolderRules(includeExts: [".MD", "TXT"], ignoreGlobs: [], limits: .defaults, encodingFallback: "none")
            .validated(caseSensitive: true, tables: tables)
        XCTAssertEqual(normalized.includeExts, ["md", "txt"])
        for ext in ["*.md", "m?d", "md/x", "", ".", "png"] {
            XCTAssertThrowsError(try FolderRules(includeExts: [ext], ignoreGlobs: [], limits: .defaults, encodingFallback: "none")
                .validated(caseSensitive: true, tables: tables))
        }
        for pattern in ["!x", "[ab]", "///"] {
            XCTAssertThrowsError(try FolderRules(includeExts: ["md"], ignoreGlobs: [pattern], limits: .defaults, encodingFallback: "none")
                .validated(caseSensitive: true, tables: tables))
        }
        for (key, maximum) in [("maxFileBytes", 52_428_800), ("maxOfficeDecompressedBytes", 209_715_200),
            ("maxExtractedChars", 5_000_000), ("maxPdfPages", 2_000), ("maxChunksPerFile", 5_000), ("maxCells", 1_000_000)] {
            for value in [0, -1, maximum + 1] {
                XCTAssertThrowsError(try IngestionLimits(json: "{\"\(key)\":\(value)}").validate())
            }
        }
        XCTAssertEqual(try IngestionLimits(json: "{}"), .defaults)
        XCTAssertEqual(try IngestionLimits(json: "{\"maxCells\":2}").cells, 2)
        XCTAssertThrowsError(try FolderRules(includeExts: ["md"], ignoreGlobs: [], limits: .defaults, encodingFallback: "latin1")
            .validated(caseSensitive: true, tables: tables))
    }
}

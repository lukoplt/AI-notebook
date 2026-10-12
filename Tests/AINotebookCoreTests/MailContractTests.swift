import Foundation
import XCTest
@testable import AINotebookCore

/// Shared `ingestion-mail-v1` and `ingestion-formats-v1` fixtures (same cases as
/// Windows `MailContractTests`). Every expected text is compared as UTF-8 bytes.
final class MailContractTests: XCTestCase {
    private func cases(_ file: String) throws -> [[String: Any]] {
        try XCTUnwrap(SharedFixtures.json("contracts/\(file)")["cases"] as? [[String: Any]])
    }

    private func limitsJSON(_ value: Any?) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value ?? [:], options: [.sortedKeys]), as: UTF8.self)
    }

    private func extract(asset: String, fallback: String, limits: Any?) async throws -> CanonicalDocument {
        let url = SharedFixtures.url(asset)
        let kind = try XCTUnwrap(SourceType.detect(filename: url.lastPathComponent))
        let rules = FolderRules(includeExts: FolderRules.defaults.includeExts, ignoreGlobs: [],
                                limits: try IngestionLimits(json: limitsJSON(limits)), encodingFallback: fallback)
        return try await BoundedDocumentExtractor().extract(url: url, kind: kind, rules: rules)
    }

    func testAllMailCases() async throws {
        let all = try cases("ingestion-mail-v1.json")
        XCTAssertEqual(Set(all.map { $0["name"] as! String }).count, all.count)
        var operations: [String: Int] = [:]
        for row in all {
            let name = row["name"] as! String
            let input = row["input"] as! [String: Any], expected = row["expected"] as! [String: Any]
            let operation = row["operation"] as! String
            operations[operation, default: 0] += 1
            switch operation {
            case "extract":
                do {
                    let document = try await extract(asset: input["asset"] as! String, fallback: input["fallback"] as! String,
                                                      limits: input["limits"])
                    XCTAssertNil(expected["error"], name)
                    XCTAssertEqual(Array(document.text.utf8), Array((expected["text"] as? String ?? "").utf8), name)
                    XCTAssertEqual(document.title, expected["title"] as? String, name)
                    XCTAssertEqual(document.kind, "email", name)
                } catch let error as IngestionError {
                    XCTAssertEqual(error.code, expected["error"] as? String, name)
                }
            case "decode-header":
                let text = MailText.decodeHeader(input["text"] as! String, fallback: input["fallback"] as! String)
                XCTAssertEqual(Array(text.utf8), Array((expected["text"] as! String).utf8), name)
            case "html-to-text":
                XCTAssertEqual(Array(MailText.htmlToText(input["html"] as! String).utf8),
                               Array((expected["text"] as! String).utf8), name)
            case "decode-charset":
                let bytes = (input["bytes"] as! [Int]).map(UInt8.init)
                let text = MailText.decode(bytes, codec: MailText.codec(label: input["charset"] as! String),
                                           fallback: input["fallback"] as! String)
                XCTAssertEqual(Array(text.utf8), Array((expected["text"] as! String).utf8), name)
            case "filetime":
                let value = (input["value"] as! NSNumber).uint64Value
                XCTAssertEqual(MailReader.filetime(value), expected["text"] as? String, name)
            default:
                XCTFail("Unknown mail operation \(operation)")
            }
        }
        XCTAssertEqual(operations, ["extract": 27, "decode-header": 7, "html-to-text": 7, "decode-charset": 10, "filetime": 4])
    }

    func testFormatDetectionAndMacroEnabledOOXML() async throws {
        let all = try cases("ingestion-formats-v1.json").map { try SpreadsheetSupersession.apply($0, fixture: "ingestion-formats-v1.json") }
        XCTAssertEqual(Set(all.map { $0["name"] as! String }).count, all.count)
        var counts: [String: Int] = [:]
        for row in all {
            let name = row["name"] as! String
            let input = row["input"] as! [String: Any], expected = row["expected"] as! [String: Any]
            let operation = row["operation"] as! String
            counts[operation, default: 0] += 1
            switch operation {
            case "detect":
                XCTAssertEqual(SourceType.detect(filename: input["filename"] as! String)?.rawValue,
                               expected["kind"] as? String, name)
            case "extract":
                let document = try await extract(asset: input["asset"] as! String, fallback: "cp1250", limits: nil)
                XCTAssertEqual(document.kind, expected["kind"] as? String, name)
                XCTAssertEqual(Array(document.text.utf8), Array((expected["text"] as! String).utf8), name)
            case "upgrade":
                continue
            default:
                XCTFail("Unknown formats operation \(operation)")
            }
        }
        XCTAssertEqual(counts["detect"], 18)
        XCTAssertEqual(counts["extract"], 3)
    }

    /// Deterministic byte mutations of every mail asset: the readers either
    /// produce text or fail with an ingestion error — never crash or hang.
    func testMutatedMessagesFailCleanly() throws {
        let directory = SharedFixtures.url("ingestion/formats")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".msg") || $0.hasSuffix(".eml") }.sorted()
        XCTAssertGreaterThanOrEqual(names.count, 10)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33)
        }
        var outcomes = [true: 0, false: 0]
        for name in names {
            let original = [UInt8](try Data(contentsOf: directory.appendingPathComponent(name)))
            for _ in 0..<150 {
                var bytes = original
                for _ in 0..<(1 + next() % 8) {
                    let index = next() % bytes.count
                    bytes[index] = next() % 3 == 0 ? 0xFF : UInt8(truncatingIfNeeded: next())
                }
                if next() % 10 == 0 { bytes = Array(bytes.prefix(next() % bytes.count)) }
                do {
                    _ = try MailReader.read(data: bytes, fileExtension: (name as NSString).pathExtension, fallback: "cp1250",
                                            limits: .defaults)
                    outcomes[true]! += 1
                } catch let error as IngestionError {
                    XCTAssertTrue(["corruptArchive", "officeLimit", "textLimit"].contains(error.code), "\(name): \(error.code)")
                    outcomes[false]! += 1
                }
            }
        }
        XCTAssertGreaterThan(outcomes[true]!, 0)
        XCTAssertGreaterThan(outcomes[false]!, 0)
    }

    /// The legacy injectable Office extractor accepts macro-enabled packages too.
    func testOfficeExtractorReadsMacroEnabledWorkbook() async throws {
        let url = SharedFixtures.url("ingestion/formats/macro.xlsm")
        let kind = try XCTUnwrap(SourceType.detect(filename: url.lastPathComponent))
        let extracted = try await OfficeExtractor().extract(from: url, kind: kind)
        // ingestion-xlsx-v2 supersedes the v1 `extract-xlsm` text.
        let expected = try XCTUnwrap(SpreadsheetSupersession.map()["ingestion-formats-v1.json"]?["extract-xlsm"]?["text"] as? String)
        XCTAssertEqual(extracted.text, expected)
        XCTAssertEqual(expected, "## Data\nR1: Položka | 12")
    }
}

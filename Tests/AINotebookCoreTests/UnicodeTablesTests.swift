import CryptoKit
import Foundation
import XCTest
@testable import AINotebookCore

final class UnicodeTablesTests: XCTestCase {
    func testSimpleLowerAndFullFoldAreDifferent() throws {
        let u = try UnicodeTables.bundled()
        XCTAssertEqual(u.simpleLowercase(0x0130), 0x0069)
        XCTAssertEqual(u.simpleLowercase(0x10400), 0x10428)
        XCTAssertEqual(u.fullCaseFold([0x0130, 0x1E9E]), [105, 775, 115, 115])
        XCTAssertEqual(u.generalCategory(0x11F02), "Lo")
    }

    func testAllNormalizationRows() throws {
        let u = try UnicodeTables.bundled()
        let raw = try SharedFixtures.data("unicode/NormalizationTest-15.1.0.txt")
        let hash = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        let sidecar = try SharedFixtures.data("unicode/NormalizationTest-15.1.0.txt.sha256")
        XCTAssertEqual(String(decoding: sidecar, as: UTF8.self), hash + "\n")
        XCTAssertEqual(hash, "871238e37e3be0696ec2bd0891119a041b052da1a84485eda05a5438724b223e")
        let provenanceURL = SharedFixtures.root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AINotebookCore/Resources/Language/unicode-sources-v1.json")
        let provenance = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: provenanceURL)) as? [String: Any])
        let text = try XCTUnwrap(String(data: raw, encoding: .utf8))
        var rows = 0
        for line in text.components(separatedBy: .newlines) {
            let body = line.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            if body.isEmpty || body.hasPrefix("@") { continue }
            let columns = body.components(separatedBy: ";").prefix(5)
            XCTAssertEqual(columns.count, 5)
            let c = try columns.map { field in
                try field.split(whereSeparator: { $0 == " " || $0 == "\t" }).map {
                    try XCTUnwrap(UInt32($0, radix: 16))
                }
            }
            for i in 0..<3 { XCTAssertEqual(u.nfc(c[i]), c[1], "row \(rows), c\(i+1)") }
            for i in 3..<5 { XCTAssertEqual(u.nfc(c[i]), c[3], "row \(rows), c\(i+1)") }
            for i in 0..<3 { XCTAssertEqual(u.nfd(c[i]), c[2], "NFD row \(rows), c\(i+1)") }
            for i in 3..<5 { XCTAssertEqual(u.nfd(c[i]), c[4], "NFD row \(rows), c\(i+1)") }
            rows += 1
        }
        XCTAssertEqual(rows, 19_074)
        XCTAssertEqual(rows, provenance["normalizationRows"] as? Int)
    }

    func testBadResourceHashThrows() {
        XCTAssertThrowsError(try UnicodeTables(data: Data("{}\n".utf8), expectedSHA256: String(repeating: "0", count: 64)))
    }

    func testEverySharedOperation() throws {
        let u = try UnicodeTables.bundled()
        let root = try SharedFixtures.json("contracts/unicode-tables-v1.json")
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 8)
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            let input = try XCTUnwrap(c["input"] as? [UInt32])
            switch c["operation"] as? String {
            case "category": XCTAssertEqual(input.map(u.generalCategory), c["expected"] as? [String], name)
            case "lower": XCTAssertEqual(input.map(u.simpleLowercase), c["expected"] as? [UInt32], name)
            case "fold": XCTAssertEqual(u.fullCaseFold(input), c["expected"] as? [UInt32], name)
            case "nfc": XCTAssertEqual(u.nfc(input), c["expected"] as? [UInt32], name)
            default: XCTFail("unknown operation: \(name)")
            }
        }
    }
}

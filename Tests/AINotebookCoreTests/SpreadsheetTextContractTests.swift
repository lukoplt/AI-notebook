import Foundation
import XCTest
@testable import AINotebookCore

/// Frozen v1 fixture cases whose expected XLSX canonical text is replaced by
/// `ingestion-xlsx-v2` (its `supersedes` map). The v1 files stay byte-identical;
/// consumers swap in the v2 expectation for exactly the listed cases.
enum SpreadsheetSupersession {
    static func map() throws -> [String: [String: [String: Any]]] {
        try XCTUnwrap(SharedFixtures.json("contracts/ingestion-xlsx-v2.json")["supersedes"] as? [String: [String: [String: Any]]])
    }

    /// The case row with its `expected` replaced when v2 supersedes it.
    static func apply(_ row: [String: Any], fixture: String) throws -> [String: Any] {
        guard let name = row["name"] as? String, let replacement = try map()[fixture]?[name] else { return row }
        var copy = row
        copy["expected"] = replacement
        return copy
    }
}

/// Shared `ingestion-xlsx-v2` value renderers (same cases as Windows SpreadsheetTextContractTests).
final class SpreadsheetTextContractTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let fixture = try SharedFixtures.json("contracts/ingestion-xlsx-v2.json")
        XCTAssertEqual(fixture["contract"] as? String, "ingestion-xlsx")
        XCTAssertEqual(fixture["version"] as? Int, 2)
        return fixture
    }

    func testConstants() throws {
        let fixture = try fixture()
        XCTAssertEqual(fixture["textFormatVersion"] as? Int, SpreadsheetText.formatVersion)
        XCTAssertEqual(fixture["significantDigits"] as? Int, SpreadsheetText.significantDigits)
        XCTAssertEqual(fixture["cellSeparator"] as? String, SpreadsheetText.cellSeparator)
    }

    func testValueRenderers() throws {
        let cases = try XCTUnwrap(fixture()["cases"] as? [[String: Any]])
        var counts: [String: Int] = [:]
        for row in cases {
            let name = row["name"] as! String, operation = row["operation"] as! String
            let input = row["input"] as! [String: Any], expected = (row["expected"] as! [String: Any])["text"] as? String
            counts[operation, default: 0] += 1
            switch operation {
            case "number":
                XCTAssertEqual(SpreadsheetText.number(input["raw"] as! String).map { Array($0.utf8) }, expected.map { Array($0.utf8) }, name)
            case "date":
                XCTAssertEqual(SpreadsheetText.date(input["raw"] as! String, date1904: input["date1904"] as! Bool), expected, name)
            case "value":
                XCTAssertEqual(Array(SpreadsheetText.normalize(input["raw"] as! String).utf8), Array((expected ?? "").utf8), name)
            case "extract":
                continue
            default:
                XCTFail("unknown operation \(operation)")
            }
        }
        XCTAssertGreaterThanOrEqual(counts["number"] ?? 0, 30)
        XCTAssertGreaterThanOrEqual(counts["date"] ?? 0, 20)
        XCTAssertGreaterThanOrEqual(counts["value"] ?? 0, 8)
        XCTAssertGreaterThanOrEqual(counts["extract"] ?? 0, 25)
    }

    func testColumnNamesAndCivilDays() {
        XCTAssertEqual([1, 26, 27, 52, 53, 702, 703, 16_384].map(SpreadsheetText.columnName),
                       ["A", "Z", "AA", "AZ", "BA", "ZZ", "AAA", "XFD"])
        XCTAssertEqual(SpreadsheetText.daysFromCivil(1970, 1, 1), 0)
        XCTAssertTrue(SpreadsheetText.civilFromDays(SpreadsheetText.daysFromCivil(2024, 2, 29)) == (2024, 2, 29))
    }

    func testSupersessionCoversOnlyListedCases() throws {
        let map = try SpreadsheetSupersession.map()
        XCTAssertEqual(Set(map.keys), ["ingestion-office-v1.json", "ingestion-ooxml-v1.json", "ingestion-formats-v1.json",
                                       "release-integration-v1.json"])
        XCTAssertEqual(map["ingestion-office-v1.json"]?.count, 9)
        XCTAssertEqual(map["ingestion-ooxml-v1.json"]?.count, 3)
    }
}

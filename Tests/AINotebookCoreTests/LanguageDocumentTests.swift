import Foundation
import XCTest
@testable import AINotebookCore

final class LanguageDocumentTests: XCTestCase {
    func testEveryDocumentIntermediate() throws {
        let fixture = try SharedFixtures.json("contracts/lang-score-v1.json")
        let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(fixture["model"])) + Data([10])
        let detector = try LanguageDetector(testModelData: data, tables: UnicodeTables.bundled())
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
            .filter { $0["mode"] as? String == "document" }
        XCTAssertEqual(cases.count, 9)
        for c in cases {
            let input = try XCTUnwrap(c["input"] as? String)
            let name = try XCTUnwrap(c["name"] as? String)
            let result = try XCTUnwrap(detector.detectDocument(input))
            try assertLanguageJSON(result, equals: XCTUnwrap(c["expected"]), name)
            XCTAssertEqual(detector.detectDocument(utf16Units: Array(input.utf16)), result, name)
        }
    }

    func testEverySupplementalWindowRange() throws {
        let fixture = try SharedFixtures.json("contracts/lang-runtime-v1.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
            .filter { $0["operation"] as? String == "windows" }
        XCTAssertEqual(cases.count, 3)
        for c in cases {
            let input = try XCTUnwrap(c["input"] as? [String: Any])
            let length = try XCTUnwrap(input["length"] as? Int)
            let ranges = LanguageDocument.ranges(length: length,
                count: try XCTUnwrap(input["count"] as? Int),
                size: try XCTUnwrap(input["size"] as? Int))
            let name = try XCTUnwrap(c["name"] as? String)
            try assertLanguageJSON(ranges.map { [$0.lowerBound, $0.upperBound] },
                                   equals: XCTUnwrap(c["expected"]), name)
            if let first = ranges.first, let last = ranges.last {
                XCTAssertEqual(first.lowerBound, 0, name)
                XCTAssertEqual(last.upperBound, length, name)
                for range in ranges { XCTAssertEqual(range.count, first.count, name) }
                for (previous, next) in zip(ranges, ranges.dropFirst()) {
                    XCTAssertLessThanOrEqual(previous.upperBound, next.lowerBound, name)
                }
            }
        }
    }

    func testDocumentSamplingRetainsTextBeyondTextModeCap() throws {
        let fixture = try SharedFixtures.json("contracts/lang-score-v1.json")
        var model = try XCTUnwrap(fixture["model"] as? [String: Any])
        var parameters = try XCTUnwrap(model["parameters"] as? [String: Any])
        let textCap = try XCTUnwrap(parameters["windowScalars"] as? Int)
        parameters["textCapScalars"] = textCap
        model["parameters"] = parameters
        let data = try JSONSerialization.data(withJSONObject: model) + Data([10])
        let detector = try LanguageDetector(testModelData: data, tables: UnicodeTables.bundled())
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
            .filter { $0["mode"] as? String == "document" }
        XCTAssertEqual(cases.count, 9)
        for c in cases {
            let input = try XCTUnwrap(c["input"] as? String)
            let name = try XCTUnwrap(c["name"] as? String)
            let result = try XCTUnwrap(detector.detectDocument(input))
            try assertLanguageJSON(result, equals: XCTUnwrap(c["expected"]), name)
            XCTAssertEqual(detector.detectDocument(utf16Units: Array(input.utf16)), result, name)
            if result.normalizedScalarCount > textCap {
                XCTAssertEqual(result.windows.last?.end, result.normalizedScalarCount, name)
            }
        }
    }

    func testEverySupplementalAggregateIntermediate() throws {
        let fixture = try SharedFixtures.json("contracts/lang-runtime-v1.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
            .filter { $0["operation"] as? String == "aggregate" }
        XCTAssertEqual(cases.count, 5)
        for c in cases {
            let input = try XCTUnwrap(c["input"] as? [String: Any])
            let result = LanguageDocument.aggregate(
                targets: try XCTUnwrap(input["targets"] as? [String]),
                labels: try XCTUnwrap(input["labels"] as? [String]),
                letters: try XCTUnwrap(input["letters"] as? [Int]).map(Int64.init))
            try assertLanguageJSON(result, equals: XCTUnwrap(c["expected"]),
                                   try XCTUnwrap(c["name"] as? String))
        }
    }
}

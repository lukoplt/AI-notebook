import CryptoKit
import Foundation
import XCTest
@testable import AINotebookCore

/// WP4 release gate: the real production detector must reproduce every field of the Python
/// reference result on the committed held-out replay (and, when `tools/lang/evaluate_detector.py
/// --native-parity` supplies `AINOTEBOOK_LANG_RELEASE_INPUT`, on every held-out example).
/// `features`, `wordScalars` and `words` are compared through the fixture's canonical SHA-256 digests.
final class LanguageReleaseTests: XCTestCase {
    func testProductionReleaseCases() throws {
        let detector = LanguageDetector.bundled()
        XCTAssertTrue(detector.isAvailable, "production artifact must load")
        let environment = ProcessInfo.processInfo.environment
        var urls = [SharedFixtures.url("contracts/lang-release-v1.json")]
        if let path = environment["AINOTEBOOK_LANG_RELEASE_INPUT"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            urls += try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            XCTAssertGreaterThan(urls.count, 1, "full replay must not be empty")
        }
        var evaluated = 0
        var mismatches: [String] = []
        for url in urls {
            try drain {
                let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                XCTAssertEqual(root["contract"] as? String, "lang-release", url.lastPathComponent)
                for c in try XCTUnwrap(root["cases"] as? [[String: Any]]) {
                    let name = try XCTUnwrap(c["name"] as? String)
                    let input = try XCTUnwrap(c["input"] as? String)
                    let actual: Any
                    if try XCTUnwrap(c["mode"] as? String) == "text" {
                        actual = try releaseCompactText(jsonObject(try XCTUnwrap(detector.detectText(input), name)))
                    } else {
                        actual = try releaseCompactDocument(jsonObject(try XCTUnwrap(detector.detectDocument(input), name)))
                    }
                    let expected = try XCTUnwrap(c["expected"], name)
                    if try canonical(actual) != canonical(expected) {
                        if mismatches.count < 5 {
                            XCTFail("\(name)\nexpected: \(String(decoding: try canonical(expected), as: UTF8.self).prefix(4000))"
                                    + "\nactual: \(String(decoding: try canonical(actual), as: UTF8.self).prefix(4000))")
                        }
                        mismatches.append(name)
                    }
                    evaluated += 1
                }
            }
        }
        if let path = environment["AINOTEBOOK_LANG_RELEASE_SUMMARY"] {
            let summary: [String: Any] = ["files": urls.count, "cases": evaluated, "mismatches": mismatches.count,
                                          "firstMismatches": Array(mismatches.prefix(20))]
            try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: path))
        }
        XCTAssertGreaterThan(evaluated, 0)
        XCTAssertEqual(mismatches.count, 0, "release replay mismatches: \(mismatches.prefix(20))")
    }

    func testCompactionDigestsMatchTheCanonicalDefinition() throws {
        let text: [String: Any] = [
            "features": [[["symbols": [-2], "count": 3], ["symbols": [97], "count": 12]],
                         [["symbols": [-1, 97], "count": 3]], [[String: Any]]()],
            "wordScalars": [[97, 98], [269]], "words": ["ab", "č"], "label": "und"]
        let compact = try XCTUnwrap(releaseCompactText(text) as? [String: Any])
        XCTAssertEqual(compact["features"] as? String, "sha256:" + sha256Hex("-2:3;97:12|-1,97:3|"))
        XCTAssertEqual(compact["wordScalars"] as? String, "sha256:" + sha256Hex("97,98;269"))
        XCTAssertEqual(compact["words"] as? String, "sha256:" + sha256Hex("ab\u{0}č"))
        XCTAssertEqual(compact["label"] as? String, "und")
    }
}

private struct ReleaseShapeError: Error {}

private func drain(_ body: () throws -> Void) rethrows {
    #if canImport(ObjectiveC)
    try autoreleasepool(invoking: body)
    #else
    try body()
    #endif
}

private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}

private func canonical(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
}

private func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func integers(_ value: Any?) throws -> [String] {
    guard let numbers = value as? [NSNumber] else { throw ReleaseShapeError() }
    return numbers.map { String($0.int64Value) }
}

func releaseCompactText(_ value: Any) throws -> Any {
    guard var object = value as? [String: Any],
          let features = object["features"] as? [[[String: Any]]],
          let words = object["wordScalars"] as? [Any],
          let strings = object["words"] as? [String] else { throw ReleaseShapeError() }
    let featureText = try features.map { order in
        try order.map { entry -> String in
            guard let count = entry["count"] as? NSNumber else { throw ReleaseShapeError() }
            return try integers(entry["symbols"]).joined(separator: ",") + ":" + String(count.int64Value)
        }.joined(separator: ";")
    }.joined(separator: "|")
    object["features"] = "sha256:" + sha256Hex(featureText)
    object["wordScalars"] = "sha256:" + sha256Hex(try words.map { try integers($0).joined(separator: ",") }
        .joined(separator: ";"))
    object["words"] = "sha256:" + sha256Hex(strings.joined(separator: "\u{0}"))
    return object
}

func releaseCompactDocument(_ value: Any) throws -> Any {
    guard var object = value as? [String: Any], let windows = object["windows"] as? [[String: Any]] else {
        throw ReleaseShapeError()
    }
    object["windows"] = try windows.map { window -> [String: Any] in
        var copy = window
        copy["expected"] = try releaseCompactText(window["expected"] as Any)
        return copy
    }
    return object
}

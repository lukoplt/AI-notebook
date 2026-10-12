import Foundation
import XCTest
@testable import AINotebookCore

final class LanguageModelTests: XCTestCase {
    func testEveryArtifactValidationCase() throws {
        let u = try UnicodeTables.bundled()
        struct FixtureCase: Decodable {
            let name: String
            let rawArtifact: String?
            let rawBytesBase64: String?
            let rawManifestProperties: String?
            let valid: Bool
        }
        struct Fixture: Decodable { let cases: [FixtureCase] }
        // JSONSerialization strips a leading U+FEFF inside decoded string values.
        // JSONDecoder preserves the exact rawArtifact bytes, including the BOM probe.
        let cases = try JSONDecoder().decode(Fixture.self,
            from: SharedFixtures.data("contracts/lang-artifact-validation-v1.json")).cases
        XCTAssertEqual(cases.filter { $0.rawManifestProperties == nil }.count, 40)
        XCTAssertEqual(cases.filter { $0.rawManifestProperties != nil }.count, 64)
        let bundle = try SharedFixtures.json("lang/loading-bundle-v1.json")
        var original = try XCTUnwrap(bundle["resources"] as? [String: String]).mapValues {
            try XCTUnwrap(Data(base64Encoded: $0))
        }
        for name in try XCTUnwrap(bundle["sharedUnicodeResources"] as? [String]) {
            original[name] = try LanguageDetector.bundledResourceData(name)
        }
        for c in cases {
            if let properties = c.rawManifestProperties {
                XCTAssertNil(c.rawArtifact, c.name)
                XCTAssertNil(c.rawBytesBase64, c.name)
                let name = "lang-detector-v1.manifest.json"
                let manifest = try XCTUnwrap(original[name])
                XCTAssertEqual(manifest.first, 123)
                var resources = original
                // Preserve raw number spellings and duplicate keys for the strict parser.
                resources[name] = Data(("{" + properties).utf8) + manifest.dropFirst()
                let snapshot = resources
                XCTAssertEqual(LanguageDetector.load { try XCTUnwrap(snapshot[$0]) }.isAvailable, c.valid, c.name)
                continue
            }
            let data: Data
            if let raw = c.rawArtifact {
                XCTAssertNil(c.rawBytesBase64, c.name)
                data = Data(raw.utf8)
                if c.name == "bom" { XCTAssertEqual(Array(data.prefix(3)), [239, 187, 191]) }
            } else {
                data = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(c.rawBytesBase64)))
            }
            if c.valid {
                XCTAssertNoThrow(try LanguageModel.parse(data, tables: u, allowSynthetic: true), c.name)
            } else {
                XCTAssertThrowsError(try LanguageModel.parse(data, tables: u, allowSynthetic: true), c.name)
            }
        }
    }

    func testEverySharedJSONValidationCase() throws {
        struct FixtureCase: Decodable {
            let name: String
            let rawJson: String
            let valid: Bool
        }
        struct Fixture: Decodable { let cases: [FixtureCase] }
        let cases = try JSONDecoder().decode(Fixture.self,
            from: SharedFixtures.data("contracts/lang-json-validation-v1.json")).cases
        XCTAssertEqual(cases.count, 18)
        for c in cases {
            let data = Data(c.rawJson.utf8)
            if c.valid { XCTAssertNoThrow(try LanguageJSON.validate(data), c.name) }
            else { XCTAssertThrowsError(try LanguageJSON.validate(data), c.name) }
        }
    }

    func testProductionRejectsSynthetic() throws {
        let fixture = try SharedFixtures.json("contracts/lang-score-v1.json")
        let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(fixture["model"])) + Data([10])
        XCTAssertThrowsError(try LanguageModel.parse(data, tables: UnicodeTables.bundled(), allowSynthetic: false))
    }

    func testSchemaKeysUseExactScalarSpelling() throws {
        let fixture = try SharedFixtures.json("contracts/lang-score-v1.json")
        let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(fixture["model"]))
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8)) + "\n"
        let tables = try UnicodeTables.bundled()
        let variants = [
            raw.replacingOccurrences(of: "\"minKnownCoverageBp\":", with: "\"minKnownCoverageBp\":"),
            raw.replacingOccurrences(of: "\"minKnownCoverageBp\":", with: "\"minKnownCoverageBp\":9000,\"minKnownCoverageBp\":")
        ]
        for variant in variants {
            XCTAssertThrowsError(try LanguageModel.parse(Data(variant.utf8), tables: tables, allowSynthetic: true))
        }
    }

    func testRawScannerValidatesAllTokensAndDecodedKeys() throws {
        let valid = ["{}\n", "{\"a\":-9223372036854775808,\"b\":9223372036854775807}\n",
                     "{\"a\":true,\"b\":false,\"c\":null,\"d\":\"\\uD801\\uDC00\"}\n"]
        for raw in valid { XCTAssertNoThrow(try LanguageJSON.validate(Data(raw.utf8)), raw) }
        let invalid = ["{\"a\":9223372036854775808}\n", "{\"a\":-9223372036854775809}\n",
                       "{\"a\":01}\n", "{\"a\":1e0}\n", "{\"a\":1.0}\n",
                       "{\"a\":{\"x\":1,\"\\u0078\":2}}\n", "{\"a\":\"\\ud800\"}\n",
                       "{\"a\":\"\\udc00\"}\n", "{\"a\":\"\\ud800A\"}\n", "{}{}\n", "[]\n",
                       "{\"a\":1,}\n", "{\"a\":[1,]}\n", "{\"a\":\"\u{001f}\"}\n",
                       "{\"a\":" + String(repeating: "[", count: 64) + "0" + String(repeating: "]", count: 64) + "}\n"]
        for raw in invalid { XCTAssertThrowsError(try LanguageJSON.validate(Data(raw.utf8)), raw) }
    }
}

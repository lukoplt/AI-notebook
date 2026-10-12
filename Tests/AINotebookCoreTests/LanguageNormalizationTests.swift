import Foundation
import XCTest
@testable import AINotebookCore

final class LanguageNormalizationTests: XCTestCase {
    func testEveryNormalizationField() throws {
        let tables = try UnicodeTables.bundled()
        let fixture = try SharedFixtures.json("contracts/lang-normalize-v1.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 44)
        for fixtureCase in cases {
            let name = try XCTUnwrap(fixtureCase["name"] as? String)
            let stream: [UInt32]
            if let text = fixtureCase["input"] as? String {
                XCTAssertNil(fixtureCase["utf16Units"], name)
                stream = LanguageNormalization.stream(text, tables: tables, cap: 5_000_000)
            } else {
                let units = try XCTUnwrap(fixtureCase["utf16Units"] as? [UInt16], name)
                stream = LanguageNormalization.stream(utf16Units: units, tables: tables, cap: 5_000_000)
            }
            try assertLanguageJSON(LanguageNormalization.classify(stream, tables: tables),
                                   equals: try XCTUnwrap(fixtureCase["expected"]), name)
        }
    }

    func testEveryRuntimeNormalizationField() throws {
        let tables = try UnicodeTables.bundled()
        let fixture = try SharedFixtures.json("contracts/lang-runtime-v1.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
            .filter { $0["operation"] as? String == "normalize" }
        XCTAssertEqual(cases.count, 5)
        for fixtureCase in cases {
            let name = try XCTUnwrap(fixtureCase["name"] as? String)
            let input = try XCTUnwrap(fixtureCase["input"] as? [String: Any], name)
            let units = try XCTUnwrap(input["utf16Units"] as? [UInt16], name)
            let inputCap = try XCTUnwrap(input["inputCap"] as? Int, name)
            let textCap = try XCTUnwrap(input["textCap"] as? Int, name)
            let mode = try XCTUnwrap(input["mode"] as? String, name)
            XCTAssertTrue(["text", "document"].contains(mode), name)
            let stream = LanguageNormalization.stream(utf16Units: units, tables: tables, cap: inputCap)
            let scalars = mode == "text" ? Array(stream.prefix(textCap)) : stream
            let words = LanguageNormalization.classify(scalars, tables: tables)
            let actual = RuntimeNormalizationResult(stream: stream, scalars: scalars,
                words: words.words, wordScalars: words.wordScalars, boundaryWords: words.boundaryWords,
                letterCount: words.letterCount, wordCount: words.wordCount)
            try assertLanguageJSON(actual, equals: try XCTUnwrap(fixtureCase["expected"]), name)
        }
    }

    private struct RuntimeNormalizationResult: Encodable {
        let stream: [UInt32]
        let scalars: [UInt32]
        let words: [String]
        let wordScalars: [[UInt32]]
        let boundaryWords: [[Int32]]
        let letterCount: Int64
        let wordCount: Int64
    }
}

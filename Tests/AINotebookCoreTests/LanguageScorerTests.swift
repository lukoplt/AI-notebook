import Foundation
import XCTest
@testable import AINotebookCore

final class LanguageScorerTests: XCTestCase {
    func testEveryTextIntermediate() throws {
        let fixture = try SharedFixtures.json("contracts/lang-score-v1.json")
        let tables = try UnicodeTables.bundled()
        let bytes = try JSONSerialization.data(withJSONObject: XCTUnwrap(fixture["model"])) + Data([10])
        let model = try LanguageModel.parse(bytes, tables: tables, allowSynthetic: true)
        let scorer = LanguageScorer(model: model, tables: tables)
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
            .filter { $0["mode"] as? String == "text" }
        XCTAssertEqual(cases.count, 23)
        for c in cases {
            let stream = LanguageNormalization.stream(try XCTUnwrap(c["input"] as? String), tables: tables,
                                                      cap: model.parameters.inputCapScalars)
            let result = scorer.score(Array(stream.prefix(model.parameters.textCapScalars)))
            try assertLanguageJSON(result, equals: XCTUnwrap(c["expected"]), try XCTUnwrap(c["name"] as? String))
        }
    }

    func testSignedFloorDivision() {
        XCTAssertEqual(LanguageScorer.floorDiv(-7, 3), -3)
        XCTAssertEqual(LanguageScorer.floorDiv(-6, 3), -2)
        XCTAssertEqual(LanguageScorer.floorDiv(7, 3), 2)
        XCTAssertEqual(LanguageScorer.floorDiv(Int64.min, 3), -3_074_457_345_618_258_603)
    }

    func testEverySupplementalScoreIntermediate() throws {
        let fixture = try SharedFixtures.json("contracts/lang-runtime-v1.json")
        let original = try XCTUnwrap(SharedFixtures.json("contracts/lang-score-v1.json")["model"] as? [String: Any])
        let tables = try UnicodeTables.bundled()
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
            .filter { $0["operation"] as? String == "score" }
        XCTAssertEqual(cases.count, 6)
        for c in cases {
            var object = original
            let overrides = try XCTUnwrap(c["modelOverrides"] as? [String: Any])
            for (key, value) in overrides {
                if key == "parameters" {
                    var parameters = try XCTUnwrap(object[key] as? [String: Any])
                    for (name, replacement) in try XCTUnwrap(value as? [String: Any]) { parameters[name] = replacement }
                    object[key] = parameters
                } else { object[key] = value }
            }
            let bytes = try JSONSerialization.data(withJSONObject: object) + Data([10])
            let model = try LanguageModel.parse(bytes, tables: tables, allowSynthetic: true)
            let scorer = LanguageScorer(model: model, tables: tables)
            let stream = LanguageNormalization.stream(try XCTUnwrap(c["input"] as? String), tables: tables,
                                                      cap: model.parameters.inputCapScalars)
            try assertLanguageJSON(scorer.score(Array(stream.prefix(model.parameters.textCapScalars))),
                                   equals: XCTUnwrap(c["expected"]), try XCTUnwrap(c["name"] as? String))
        }
    }
}

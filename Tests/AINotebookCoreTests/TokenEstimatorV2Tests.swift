import XCTest
@testable import AINotebookCore

final class TokenEstimatorV2Tests: XCTestCase {
    private let file = "token-estimate-v2.json"

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any?) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value!, options: .fragmentsAllowed))
    }

    private func code(_ body: () throws -> Void) -> String? {
        do { try body(); return nil }
        catch let e as BenchmarkError { return e.code }
        catch { return "unexpected:\(error)" }
    }

    func testEveryCaseKindIsOwned() throws {
        let root = try SharedFixtures.json("contracts/" + file)
        let kinds = Set((root["cases"] as! [[String: Any]]).map { $0["kind"] as! String })
        XCTAssertEqual(kinds, ["fit", "estimate", "estimator", "estimatorBound", "undercount", "constructor", "binding",
                               "calibration-observations", "sample-plan", "calibration-report", "resource"])
    }

    func testSharedCalibrationAndEstimator() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "estimate")
        XCTAssertEqual(rows.count, 6)
        for c in rows {
            let rate = TokenRate(family: "fixture-only", language: c["language"] as! String,
                                 tokensPerScalarBp: c["rateBp"] as! Int)
            let e = try TokenEstimatorV2(family: "fixture-only", rates: [rate])
            XCTAssertEqual(e.estimate(c["text"] as! String, language: c["language"] as! String), c["expected"] as? Int,
                           c["name"] as! String)
            XCTAssertEqual(e.version, 2)
        }
    }

    func testSharedFit() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "fit")
        XCTAssertEqual(rows.count, 12)
        for c in rows {
            let name = c["name"] as! String
            let samples = try decode([TokenSample].self, c["samples"])
            if let error = c["error"] as? String {
                XCTAssertEqual(code { _ = try TokenCalibration.fit(samples) }, error, name)
            } else {
                XCTAssertEqual(try TokenCalibration.fit(samples), try decode([TokenRate].self, c["expected"]), name)
            }
        }
    }

    func testFitNeverUsesHoldout() throws {
        let sample = TokenSample(id: "a", family: "fixture-only", language: "cs", split: "holdout", scalars: 3, tokens: 2)
        XCTAssertThrowsError(try TokenCalibration.fit([sample]))
    }

    func testSharedEstimatorFamilies() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "estimator")
        XCTAssertEqual(rows.count, 5)
        for c in rows {
            let e = try TokenEstimatorV2(family: c["family"] as! String, rates: try decode([TokenRate].self, c["rates"]))
            XCTAssertEqual(e.estimate(c["text"] as! String, language: c["language"] as! String), c["expected"] as? Int,
                           c["name"] as! String)
        }
    }

    func testSharedEstimatorBoundSaturates() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "estimatorBound")
        XCTAssertEqual(rows.count, 1)
        for c in rows {
            let e = try TokenEstimatorV2(family: c["family"] as! String, rates: try decode([TokenRate].self, c["rates"]))
            let text = String(repeating: "a", count: c["scalars"] as! Int)
            XCTAssertEqual(e.estimate(text, language: c["language"] as! String), c["expected"] as? Int)
        }
    }

    func testSharedUndercounts() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "undercount")
        XCTAssertEqual(rows.count, 2)
        for c in rows {
            let name = c["name"] as! String
            let samples = try decode([TokenSample].self, c["samples"])
            let rates = try decode([TokenRate].self, c["rates"])
            if let error = c["error"] as? String {
                XCTAssertEqual(code { _ = try TokenCalibration.undercounts(samples, rates: rates) }, error, name)
            } else {
                XCTAssertEqual(try TokenCalibration.undercountRows(samples, rates: rates),
                               try decode([TokenUndercountRow].self, c["rows"]), name)
                XCTAssertEqual(try TokenCalibration.undercounts(samples, rates: rates), c["undercounts"] as? Int, name)
            }
        }
    }

    func testSharedConstructorValidation() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "constructor")
        XCTAssertEqual(rows.count, 6)
        for c in rows {
            let rates = try decode([TokenRate].self, c["rates"])
            XCTAssertEqual(code { _ = try TokenEstimatorV2(family: c["family"] as! String, rates: rates) },
                           c["error"] as? String, c["name"] as! String)
        }
    }

    func testSharedBindingsAndMutableAlias() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "binding")
        XCTAssertEqual(rows.count, 5)
        for c in rows {
            XCTAssertEqual(TokenEstimatorV2.resolveFamily(model: c["model"] as! String,
                                                          modelDigest: c["modelDigest"] as? String,
                                                          bindings: try decode([TokenFamilyBinding].self, c["bindings"])),
                           c["expected"] as? String, c["name"] as! String)
        }
        let bindings = [TokenFamilyBinding(model: "llama3.2:3b", modelDigest: "sha256:" + String(repeating: "a", count: 64),
                                           family: "fixture-only")]
        XCTAssertNil(TokenEstimatorV2.resolveFamily(model: "llama3.2:3b", modelDigest: nil, bindings: bindings))
        let fallback = try TokenEstimatorV2(family: "unverified", rates: [])
        XCTAssertEqual(fallback.estimate("a😀b", language: "cs"), 7) // 6 UTF-8 bytes +15%, ceil
    }

    func testSharedCalibrationObservationsExcludeEmbeddingAndPromptCounts() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "calibration-observations")
        XCTAssertEqual(rows.count, 1)
        for c in rows {
            let observations = try decode([TokenObservation].self, c["observations"])
            let expected = c["expected"] as! [String: Any]
            let result = try TokenCalibration.fitObservations(observations)
            XCTAssertEqual(result.trainingIds, expected["trainingIds"] as? [String])
            XCTAssertEqual(result.rates, try decode([TokenRate].self, expected["rates"]))
        }
    }

    func testSharedSamplePlan() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "sample-plan")
        XCTAssertEqual(rows.count, 1)
        for c in rows {
            let docs = try decode([CalibrationDocument].self, c["documents"])
            let queries = try decode([CalibrationQuery].self, c["queries"])
            let plan = TokenCalibration.samplePlan(documents: docs, queries: queries)
            let expected = c["expected"] as! [[String: Any]]
            XCTAssertEqual(plan.count, expected.count)
            for (p, e) in zip(plan, expected) {
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
                let text = object.removeValue(forKey: "text") as! String
                for key in ["documentId", "start", "end", "sources"] where object[key] == nil { object[key] = NSNull() }
                XCTAssertEqual(object as NSDictionary, e as NSDictionary, p.id)
                XCTAssertEqual(text.unicodeScalars.count, p.scalars, p.id)
                XCTAssertEqual(text.utf8.count, p.utf8Bytes, p.id)
            }
        }
    }

    func testSharedCalibrationReports() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "calibration-report")
        XCTAssertEqual(rows.count, 7)
        for c in rows {
            let name = c["name"] as! String
            let report = try decode(TokenCalibrationReportV1.self, c["input"])
            if let error = c["error"] as? String {
                XCTAssertEqual(code { try report.validate() }, error, name)
                continue
            }
            try report.validate()
            XCTAssertEqual(try JSONSerialization.jsonObject(with: report.jsonData()) as? NSDictionary,
                           c["expectedJson"] as? NSDictionary, name)
            XCTAssertEqual(report.markdown(), c["expectedMarkdown"] as? String, name)
        }
    }

    func testSharedResources() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "resource")
        XCTAssertEqual(rows.count, 6)
        for c in rows {
            let name = c["name"] as! String
            let resource = try decode(TokenEstimateResource.self, c["input"])
            let production = c["production"] as! Bool
            if let error = c["error"] as? String {
                XCTAssertEqual(code { try resource.validate(production: production) }, error, name)
            } else {
                try resource.validate(production: production)
                let expected = c["expected"] as! [String: String]
                XCTAssertEqual(resource.payloadHash, expected["payloadHash"], name)
                XCTAssertEqual(resource.status, expected["status"], name)
            }
        }
    }

    func testBundledPendingResourceIsTheUncalibratedFallback() throws {
        let fixture = try SharedFixtures.json("contracts/" + file)
        let bundled = try TokenEstimateResource.bundled()
        XCTAssertEqual(bundled.status, "pending")
        XCTAssertEqual(bundled.payloadHash, fixture["payloadHash"] as? String)
        let e = try TokenEstimatorV2.bundled(model: "llama3.2:3b", modelDigest: "sha256:" + String(repeating: "a", count: 64))
        XCTAssertEqual(e.family, "unverified")
        XCTAssertTrue(e.rates.isEmpty)
        XCTAssertEqual(e.estimate("Záruka", language: "cs"), TokenEstimatorV2.ceilDiv(7 * 11_500, 10_000).asInt)
    }
}

private extension Int64 { var asInt: Int { Int(self) } }

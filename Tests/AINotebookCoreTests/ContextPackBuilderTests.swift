import XCTest
@testable import AINotebookCore

final class ContextPackBuilderTests: XCTestCase {
    func testMandatoryTotalsUseWideArithmeticBeforeContextComparison() throws {
        struct LargeEstimator: ContextTokenEstimating {
            let version = 1
            func estimate(_ text: String, language: String) -> Int { Int(Int32.max) / 2 }
        }
        XCTAssertThrowsError(try ContextPackBuilder.build(ContextPackFixtures.input("basic-cs"), estimator: LargeEstimator())) {
            XCTAssertEqual($0 as? ContextPackError, .contextTooSmall)
        }
    }

    func testOlderVectorHitDoesNotBlockPublishedRevisionNeighbour() throws {
        var input = try ContextPackFixtures.input("basic-cs")
        var older = input.candidates[0]
        older.revisionId = 10; older.text = "A"; older.end = 1
        var published = older
        published.chunkId = 102; published.revisionId = 11; published.text = "B"; published.rrfMicro = 29_000
        var neighbour = published
        neighbour.chunkId = 103; neighbour.ordinal = 1; neighbour.start = 1; neighbour.end = 2; neighbour.text = "C"
        input.candidates = [older, published]; input.neighbours = [neighbour]
        let output = try ContextPackBuilder.build(input, estimator: PlaceholderTokenEstimatorV1(), tuning: .v1)
        XCTAssertEqual(output.citationMap.first { $0.revisionId == 11 }?.text, "BC")
        XCTAssertTrue(output.included.contains(PackItem(kind: "neighbour", id: "103")))
        XCTAssertFalse(output.omitted.contains { $0.kind == "neighbour" && $0.id == "103" })
    }

    func testCanonicalJSONUsesExactUTF8AndScalarKeyOrder() throws {
        let value: [String: Any] = ["\u{10000}": "č😀\u{2028}/<>&", "\u{e000}": "\u{1}\u{8}\u{c}\n\r\t\"\\"]
        let expected = "{\"\u{e000}\":\"\\u0001\\b\\f\\n\\r\\t\\\"\\\\\",\"\u{10000}\":\"č😀\u{2028}/<>&\"}"
        XCTAssertEqual(try PreparedContextRequestJSON.canonicalData(value), Data(expected.utf8))
        XCTAssertThrowsError(try PreparedContextRequestJSON.canonicalData(["invalid": Double.infinity]))
    }

    func testScalarMergeSharedCases() throws {
        let seed = try ContextPackFixtures.input("basic-cs").candidates[0]
        for row in try ContextPackFixtures.cases("merge") {
            let input = row["input"] as! [String: Any]
            let expected = row["expected"] as! [String: Any]
            let parts = (input["parts"] as! [[String: Any]]).enumerated().map { index, part in
                var passage = seed
                passage.chunkId = Int64(index + 1); passage.ordinal = index
                passage.start = part["start"] as? Int; passage.end = part["end"] as? Int
                passage.text = part["text"] as! String
                return passage
            }
            if expected["error"] as? String == "inconsistent overlap" {
                XCTAssertThrowsError(try ContextPackRendering.merge(parts), row["name"] as! String)
            } else if expected["error"] as? String == "disjoint" {
                let blocks = try ContextPackRendering.merge(parts)
                XCTAssertEqual(blocks.map { $0.passage.text }, parts.map(\.text))
                XCTAssertEqual(blocks.count, 2)
            } else {
                let blocks = try ContextPackRendering.merge(parts)
                XCTAssertEqual(blocks.count, 1, row["name"] as! String)
                XCTAssertEqual(blocks.first?.passage.text.utf8.map { $0 }, (expected["text"] as! String).utf8.map { $0 })
                XCTAssertEqual(blocks.first?.passage.start, expected["start"] as? Int)
                XCTAssertEqual(blocks.first?.passage.end, expected["end"] as? Int)
            }
        }
    }

    func testWireOrderSharedCases() throws {
        let rows = try SharedFixtures.json("contracts/wire-order-v1.json")["cases"] as! [[String: Any]]
        for row in rows {
            let input = row["input"] as! [String: Any]
            var request = try ContextPackFixtures.decode(
                ContextPackFixtures.cases("build").first!["expected"]!, as: PreparedContextRequest.self)
            var sections = [PackSection(kind: "rules", text: input["rulesText"] as! String, tokens: 0)]
            let instructions = input["userInstructions"] as! String
            if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(PackSection(kind: "instructions", text: instructions, tokens: 0))
            }
            request.messages = [PackMessage(role: "system", sections: sections)]
            request.messages += (input["history"] as! [[String: String]]).map {
                PackMessage(role: $0["role"]!, sections: [PackSection(kind: "history", text: $0["content"]!, tokens: 0)])
            }
            request.messages.append(PackMessage(role: "user", sections: [PackSection(kind: "question", text: input["finalUserContent"] as! String, tokens: 0)]))
            request.options = PackOptions()
            XCTAssertEqual(try ContextPackRendering.wireObject(request, providerType: row["provider"] as! String),
                           row["expected"] as! NSDictionary, row["name"] as! String)
            XCTAssertEqual(ContextPackRendering.logicalTurns(request).map(\.content),
                           request.messages.map { $0.sections.map(\.text).joined(separator: "\n\n") })
        }
    }

    func testCanonicalRequestRoundTrip() throws {
        for row in try ContextPackFixtures.cases("build") {
            let expected = row["expected"] as! [String: Any]
            guard expected["error"] == nil else { continue }
            let request = try ContextPackFixtures.decode(expected, as: PreparedContextRequest.self)
            let bytes = try PreparedContextRequestJSON.encode(request)
            XCTAssertEqual(try PreparedContextRequestJSON.decode(bytes), request, row["name"] as! String)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: bytes) as! NSDictionary, expected as NSDictionary)
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("\\u010d"))
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("\\/"))
        }
    }
    /// The adapter hands the builder a raw descriptor; the renderer is the only escaper.
    func testEveryMapDescriptorGolden() throws {
        let rows = try ContextPackFixtures.cases("descriptor")
        XCTAssertEqual(rows.count, 8)
        for row in rows {
            let name = row["name"] as! String
            let input = row["input"] as! [String: Any]
            let detail = ContextSourceDetail(sourceId: 1, notebookId: 1,
                type: SourceType(rawValue: input["type"] as! String)!, title: "t", folderId: 1,
                relPath: "a/t.pdf", lang: nil, descriptor: input["descriptor"] as? String)
            XCTAssertEqual(ContextPackLabels.descriptor(detail), row["expected"] as! String, name)
        }
        XCTAssertEqual(ContextPackLabels.descriptor(nil), "")
    }

    func testEveryBuildGolden() throws {
        let rows = try ContextPackFixtures.cases("build")
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let name = row["name"] as! String
            let input = try ContextPackFixtures.decode(row["input"]!, as: ContextPackInput.self)
            let expected = row["expected"] as! [String: Any]
            if let error = expected["error"] as? String {
                XCTAssertThrowsError(try ContextPackBuilder.build(input, estimator: PlaceholderTokenEstimatorV1(), tuning: .v1), name) {
                    XCTAssertEqual(($0 as? ContextPackError)?.rawValue, error, name)
                }
                continue
            }
            let request = try ContextPackBuilder.build(input, estimator: PlaceholderTokenEstimatorV1(), tuning: .v1)
            XCTAssertEqual(try PreparedContextRequestJSON.object(request), expected as NSDictionary, name)
            XCTAssertEqual(try ContextPackRendering.wireObject(request,providerType: input.model.providerType),
                row["expectedWire"] as! NSDictionary,name)
            let total = request.messages.reduce(0) { sum, message in
                sum + 4 + message.sections.reduce(0) { $0 + $1.tokens }
            }
            XCTAssertLessThanOrEqual(total, input.model.runtimeContext-input.model.maxOutputTokens, name)
            XCTAssertEqual(request.citationMap.map(\.marker), Array(1..<(request.citationMap.count+1)), name)
            XCTAssertEqual(request.messages.last?.sections.filter { $0.kind == "question" }.count, 1, name)
            XCTAssertEqual(request.messages.last?.sections.last?.kind, "question", name)
            for citation in request.citationMap {
                XCTAssertEqual(citation.chunkId, citation.chunkIds.first, name)
                XCTAssertNotNil(citation.text, name)
            }
        }
    }
    func testScalarOverlapHasOneSnapshotAndNoRepeatedText() throws {
        let request = try ContextPackBuilder.build(ContextPackFixtures.input("merge-overlap"), estimator: PlaceholderTokenEstimatorV1(), tuning: .v1)
        XCTAssertEqual(request.citationMap.count, 1)
        XCTAssertEqual(request.citationMap[0].text, "A😀. Bč!")
        XCTAssertEqual(request.citationMap[0].spans.map { [$0.start,$0.end] }, [[0,7]])
        XCTAssertEqual(request.citationMap[0].chunkIds, [101,102])
    }
    func testRulesAreEnglishAndDataIsOnlyInUser() throws {
        let request = try ContextPackBuilder.build(ContextPackFixtures.input("external-labelled"), estimator: PlaceholderTokenEstimatorV1(), tuning: .v1)
        let system = request.messages[0]
        XCTAssertEqual(system.role, "system")
        XCTAssertEqual(system.sections.map(\.kind), ["rules","instructions"])
        XCTAssertTrue(system.sections[0].text.hasPrefix("The application has already searched"))
        let last = try XCTUnwrap(request.messages.last)
        XCTAssertTrue(last.sections.contains { $0.kind == "note" && $0.text.contains("NOT CONTENT OF THE SELECTED FOLDER") })
        XCTAssertTrue(last.sections.contains { $0.kind == "web" && $0.text.contains("NOT CONTENT OF THE SELECTED FOLDER") })
    }

    func testProductionDefaultUsesVersionTwoAndExplicitV1RemainsAvailable() throws {
        let input = try ContextPackFixtures.input("basic-cs")
        let actual = try ContextPackBuilder.build(input)
        let expected = try ContextPackBuilder.build(input, estimator: TokenEstimatorV2.bundled(model: input.model.model),
                                                    tuning: RagRuntimeTuning.bundled())
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.estimatorVersion, 2)
        XCTAssertEqual(try ContextPackBuilder.build(input, estimator: PlaceholderTokenEstimatorV1(), tuning: .v1).estimatorVersion, 1)
    }
}

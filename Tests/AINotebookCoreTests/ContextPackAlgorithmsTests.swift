import XCTest
@testable import AINotebookCore

final class ContextPackAlgorithmsTests: XCTestCase {
    func testEstimatorSharedCases() throws {
        let estimator = PlaceholderTokenEstimatorV1()
        let rows = try ContextPackFixtures.cases("estimate")
        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(estimator.version, 1)
        for row in rows {
            let input = row["input"] as! [String: Any]
            XCTAssertEqual(estimator.estimate(input["text"] as! String,
                language: input["language"] as! String), row["expected"] as! Int,
                row["name"] as! String)
        }
    }

    func testCorrectedBudgetSharedCases() throws {
        let root = try SharedFixtures.json("contracts/budget-v1.json")
        for row in root["cases"] as! [[String: Any]] {
            let name = row["name"] as! String
            let expected = row["expected"] as! [String: Any]
            let input = try ContextPackFixtures.decode(row["input"]!, as: PackBudgetInput.self)
            if let error = expected["error"] as? String {
                XCTAssertThrowsError(try ContextPackAlgorithms.budget(input), name) {
                    XCTAssertEqual(($0 as? ContextPackError)?.rawValue, error, name)
                }
            } else {
                let actual = try ContextPackAlgorithms.budget(input)
                XCTAssertEqual(actual, try ContextPackFixtures.decode(expected, as: PackBudgetResult.self), name)
                let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(actual)) as! NSDictionary
                XCTAssertEqual(encoded, expected as NSDictionary, name)
                XCTAssertEqual(actual.evidenceTokens + actual.mapTokens + actual.noteWebTokens
                    + actual.historyTokens + actual.unusedTokens, actual.remainder, name)
            }
        }
    }

    func testActualCostTruncationContinues() throws {
        let input = PackBudgetInput(runtimeContext: 200, maxOutputTokens: 20,
            mandatoryTokens: 80, evidenceBudgetCap: 60, topK: 3,
            passages: [PackBudgetPassage(id: 1, tokens: 90,
                truncationCandidates: [.init(endScalar: 12, tokens: 35), .init(endScalar: 25, tokens: 65)]),
                PackBudgetPassage(id: 2, tokens: 20, truncationCandidates: []),
                PackBudgetPassage(id: 3, tokens: 70, truncationCandidates: [])],
            mapTokensDesired: 0, noteWebTokensDesired: 0, historyTurnTokensNewestFirst: [])
        let output = try ContextPackAlgorithms.budget(input)
        XCTAssertEqual(output.includedPassageIds, [1, 2])
        XCTAssertEqual(output.truncatedPassageEndScalar, 12)
        XCTAssertEqual(output.truncatedPassageTokens, 35)
        XCTAssertEqual(output.evidenceTokens, 55)
        XCTAssertEqual(output.unusedTokens, 45)
    }

    func testDiversitySharedCases() throws {
        let root = try SharedFixtures.json("contracts/diversity-v1.json")
        for row in root["cases"] as! [[String: Any]] {
            let name = row["name"] as! String
            let k = row["rrfK"] as! Int
            let passages = (row["candidates"] as! [[String: Any]]).map { candidate in
                let score = ["vectorRank", "ftsRank"].compactMap { candidate[$0] as? Int }
                    .reduce(Int64(0)) { $0 + Int64(1_000_000 / (k + $1)) }
                XCTAssertEqual(score, (candidate["rrfMicro"] as! NSNumber).int64Value, name)
                return passage(chunkId: (candidate["chunkId"] as! NSNumber).int64Value,
                    sourceId: (candidate["sourceId"] as! NSNumber).int64Value, score: score)
            }
            let ordered = ContextPackAlgorithms.diversity(passages, singleSource: row["singleSourceScope"] as! Bool)
            XCTAssertEqual(ordered.map(\.chunkId), (row["expectedOrder"] as! [NSNumber]).map(\.int64Value), name)
        }
    }

    func testOverviewSharedCases() throws {
        let root = try SharedFixtures.json("contracts/overview-v1.json")
        for row in root["cases"] as! [[String: Any]] {
            let name = row["name"] as! String
            let files = row["files"] as! [[String: Any]]
            let expected = row["expected"] as! [String: Any]
            let published = files.filter { $0["firstChunkId"] is NSNumber }
            let passages = published.map { file in
                passage(chunkId: (file["firstChunkId"] as! NSNumber).int64Value,
                    sourceId: (file["sourceId"] as! NSNumber).int64Value,
                    folderId: (file["folderId"] as? NSNumber)?.int64Value, path: file["relPath"] as! String)
            }
            let ordered = ContextPackAlgorithms.overviewOrder(passages)
            XCTAssertEqual(ordered.map(\.sourceId), (expected["visitOrder"] as! [NSNumber]).map(\.int64Value), name)
            XCTAssertEqual(ContextPackAlgorithms.overviewOrder(Array(passages.reversed())), ordered, name)
            let costs = Dictionary(uniqueKeysWithValues: published.map {
                (($0["sourceId"] as! NSNumber).int64Value, $0["firstChunkTokens"] as! Int)
            })
            var used = 0
            var included: [Int64] = []
            for p in ordered where included.count < row["maxPassages"] as! Int {
                let cost = costs[p.sourceId]!
                if cost <= row["evidenceBudget"] as! Int - used { used += cost; included.append(p.sourceId) }
            }
            XCTAssertEqual(included, (expected["includedSourceIds"] as! [NSNumber]).map(\.int64Value), name)
            XCTAssertEqual(included.count, expected["filesIncluded"] as? Int, name)
            XCTAssertEqual(published.count, expected["filesWithPublishedChunks"] as? Int, name)
            XCTAssertEqual(row["filesInScope"] as? Int ?? files.count, expected["filesInScope"] as? Int, name)
            XCTAssertEqual(used, expected["evidenceTokens"] as? Int, name)
        }
    }

    func testInvalidBudgetInputsThrowBeforeArithmetic() throws {
        let base: [String: Any] = ["runtimeContext": 200, "maxOutputTokens": 20,
            "mandatoryTokens": 80, "evidenceBudgetCap": 60, "topK": 3,
            "passages": [["id": 1, "tokens": 20]], "mapTokensDesired": 0,
            "noteWebTokensDesired": 0, "historyTurnTokensNewestFirst": []]
        for (key, value) in [("runtimeContext", 0), ("maxOutputTokens", -1),
                             ("mandatoryTokens", -1), ("topK", -1), ("evidenceBudgetCap", -1),
                             ("mapTokensDesired", Int.max)] {
            var invalid = base
            invalid[key] = value
            let input = try ContextPackFixtures.decode(invalid, as: PackBudgetInput.self)
            XCTAssertThrowsError(try ContextPackAlgorithms.budget(input), key) {
                XCTAssertEqual($0 as? ContextPackError, .invalidInput)
            }
        }
    }

    func testOverviewDirectoryIdentityUsesExactScalars() {
        let passages = [passage(chunkId: 1, sourceId: 1, path: "é/a"),
                        passage(chunkId: 2, sourceId: 2, path: "e\u{301}/a"),
                        passage(chunkId: 3, sourceId: 3, path: "e\u{301}/b")]
        XCTAssertEqual(ContextPackAlgorithms.overviewOrder(passages).map(\.sourceId), [2, 1, 3])
    }

    func testOverviewSplitsDirectoryAtSlashScalar() {
        let passages = [passage(chunkId: 1, sourceId: 1, path: "a/\u{301}x"),
                        passage(chunkId: 2, sourceId: 2, path: "a/z"),
                        passage(chunkId: 3, sourceId: 3, path: "b/x")]
        XCTAssertEqual(ContextPackAlgorithms.overviewOrder(passages).map(\.sourceId), [2, 3, 1])
    }

    func testPreparedDTOsPreserveContractRevisionPairsAndNullGeneration() throws {
        for row in try ContextPackFixtures.cases("build") {
            let expected = row["expected"] as! [String: Any]
            guard expected["error"] == nil else { continue }
            let request = try ContextPackFixtures.decode(expected, as: PreparedContextRequest.self)
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! NSDictionary
            XCTAssertEqual(encoded, expected as NSDictionary, row["name"] as! String)
        }
    }

    private func passage(chunkId: Int64, sourceId: Int64, folderId: Int64? = nil,
                         path: String = "a.txt", score: Int64 = 0) -> PackPassage {
        PackPassage(chunkId: chunkId, sourceId: sourceId, revisionId: 1, folderId: folderId,
            relPath: path, displayName: "a.txt", language: "und", text: "A", ordinal: 0,
            start: 0, end: 1, pageFrom: nil, pageTo: nil, rrfMicro: score, truncationCandidates: [])
    }
}

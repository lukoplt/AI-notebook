import Foundation
import XCTest
@testable import AINotebookCore

final class EvalMetricsTests: XCTestCase {
    func testOccurrenceIdentityOverlapAndTruncatedPack() throws {
        let hash = String(repeating: "a", count: 64)
        let first = EvalSpan(documentId: "d", contentHash: hash, start: 0, end: 3)
        let second = EvalSpan(documentId: "d", contentHash: hash, start: 4, end: 7)
        let full = EvalSpan(documentId: "d", contentHash: hash, start: 0, end: 8)
        XCTAssertEqual(EvalMetrics.recall(gold: [second], evidence: [first]).recallBp, 0)
        XCTAssertEqual(EvalMetrics.recall(gold: [second], evidence: [full, full]).found, 1)
        let scores = try EvalMetrics.measure(gold: [second], lexical: [first],
            fused: [first, full], topK: 1, includeVectors: true, packed: [first])
        XCTAssertEqual(scores["hybrid_recall_at_top_k"]?.recallBp, 0)
        XCTAssertEqual(scores["candidate_recall_at_fetch_k"]?.recallBp, 10000)
        XCTAssertEqual(scores["packed_evidence_recall"]?.recallBp, 0)
        let absent = EvalMetrics.recall(gold: [], evidence: [full])
        XCTAssertEqual(absent.status, "not_applicable")
        XCTAssertNil(absent.recallBp)
        XCTAssertEqual(EvalMetrics.aggregate([absent, scores["candidate_recall_at_fetch_k"]!]).total, 1)
        XCTAssertThrowsError(try EvalMetrics.measure(gold: [], lexical: [], fused: [], topK: 0, includeVectors: false, packed: nil)) {
            XCTAssertEqual($0 as? EvalFailure, EvalFailure("invalid_top_k"))
        }
    }

    func testSharedMetricCases() throws {
        let cases = try EvalRetrievalFixtures.cases().filter { $0["kind"] as? String == "metrics" }
        XCTAssertEqual(cases.count, 10)
        for c in cases {
            let input = c["input"] as! [String: Any]
            func spans(_ key: String) throws -> [EvalSpan] {
                try JSONDecoder().decode([EvalSpan].self, from: JSONSerialization.data(withJSONObject: input[key]!))
            }
            let result = try EvalMetrics.measure(gold: spans("gold"), lexical: spans("lexical"),
                fused: spans("fused"), topK: input["top_k"] as! Int, includeVectors: input["include_vectors"] as! Bool,
                packed: input["packed"] is NSNull ? nil : spans("packed"))
            let expected = try JSONDecoder().decode([String: EvalMetric].self,
                from: JSONSerialization.data(withJSONObject: c["expected"]!))
            XCTAssertEqual(result, expected, c["name"] as! String)
        }
    }

    func testAggregatePoolsEvidenceAndPreservesUnavailable() {
        let positive = EvalMetric(status: "measured", found: 1, total: 3, recallBp: 3333)
        let missed = EvalMetric(status: "measured", found: 0, total: 1, recallBp: 0)
        XCTAssertEqual(EvalMetrics.aggregate([positive, missed]),
            EvalMetric(status: "measured", found: 1, total: 4, recallBp: 2500))
        let empty = EvalMetrics.recall(gold: [], evidence: [])
        XCTAssertEqual(EvalMetrics.aggregate([empty, .unavailable]), .unavailable)
        XCTAssertEqual(EvalMetrics.aggregate([]), empty)
    }
}

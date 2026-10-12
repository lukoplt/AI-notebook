import Foundation
import XCTest
@testable import AINotebookCore

final class EvalReportV1Tests: XCTestCase {
    func testSharedReports() throws {
        let cases = try XCTUnwrap(SharedFixtures.json("contracts/eval-report-v1.json")["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 2)
        for c in cases {
            let report = try JSONDecoder().decode(EvalReportV1.self,
                from: JSONSerialization.data(withJSONObject: c["input"]!))
            let actual = try JSONSerialization.jsonObject(with: report.jsonData()) as! NSDictionary
            XCTAssertEqual(actual, c["expected_json"] as? NSDictionary, c["name"] as! String)
            XCTAssertEqual(report.markdown(), c["expected_markdown"] as? String, c["name"] as! String)
        }
    }

    func testAssemblyMatchesSharedGoldIncludingEmptyGroups() throws {
        let cases = try XCTUnwrap(SharedFixtures.json("contracts/eval-report-v1.json")["cases"] as? [[String: Any]])
        for c in cases {
            let expected = try JSONDecoder().decode(EvalReportV1.self,
                from: JSONSerialization.data(withJSONObject: c["input"]!))
            let documents = (1...2).map { n in
                LoadedEvalDocument(metadata: EvalDocument(documentId: "document-\(n)", sourceId: Int64(n),
                    notebookId: 1, folderId: nil, path: "d\(n).txt", relPath: "d\(n).txt", language: "en", encoding: "utf-8",
                    rawSha256: expected.corpusHash, contentHash: expected.corpusHash), text: "evidence")
            }
            let questions = expected.queries.map { row in
                EvalQuestion(queryId: row.queryId, text: row.text, language: row.language, caseType: row.caseType,
                    tags: [], notebookId: 1, scope: .all, gold: [], absentReason: nil, overviewDocumentIds: [])
            }
            let corpus = EvalCorpus(corpusId: expected.corpusId, documents: documents, questions: questions, gold: [:])
            let assembled = EvalReportV1.assemble(corpus: corpus, corpusHash: expected.corpusHash, platform: "macos",
                mode: expected.mode, model: expected.model, dimensions: expected.dimensions, topK: expected.topK,
                fetchK: expected.fetchK, rows: expected.queries, hasPackingHook: expected.mode == "ollama")
            XCTAssertEqual(try JSONSerialization.jsonObject(with: assembled.jsonData()) as! NSDictionary,
                c["expected_json"] as? NSDictionary, c["name"] as! String)
        }
    }
}

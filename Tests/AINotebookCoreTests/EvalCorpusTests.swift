import Foundation
import XCTest
@testable import AINotebookCore

final class EvalCorpusTests: XCTestCase {
    private func bytes(_ key: String, in c: [String: Any]) throws -> Data {
        if let raw = c[key + "_json"] as? String { return Data(raw.utf8) }
        return try JSONSerialization.data(withJSONObject: XCTUnwrap(c[key]))
    }

    private func cases() throws -> [[String: Any]] {
        let roots = try XCTUnwrap(try SharedFixtures.json("contracts/eval-assets-v1.json")["cases"] as? [[String: Any]])
        func flatten(_ c: [String: Any]) -> [[String: Any]] {
            [c] + (c["subcases"] as? [[String: Any]] ?? []).flatMap(flatten)
        }
        XCTAssertEqual(roots.count, 27)
        return roots.flatMap(flatten)
    }

    private func check(_ c: [String: Any]) throws {
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        let files = try XCTUnwrap(c["files"] as? [String: [Int]])
        let name = try XCTUnwrap(c["name"] as? String)
        do {
            let corpus = try EvalCorpus.load(
                manifest: bytes("manifest", in: c), queries: bytes("queries", in: c),
                readFile: { path in
                    guard let bytes = files[path] else { throw EvalFailure("missing_file") }
                    return Data(bytes.map { UInt8($0) })
                })
            XCTAssertTrue(expected["error"] is NSNull, name)
            let wanted = try XCTUnwrap(expected["spans"] as? [[String: Any]])
            XCTAssertEqual(corpus.gold.values.reduce(0) { $0 + $1.count }, wanted.count, name)
            for s in wanted {
                let g = EvalSpan(documentId: s["document_id"] as! String,
                    contentHash: s["content_hash"] as! String,
                    start: s["start"] as! Int, end: s["end"] as! Int)
                XCTAssertTrue(corpus.gold[s["query_id"] as! String, default: []].contains(g), name)
            }
        } catch let error as EvalFailure {
            XCTAssertEqual(error.code, expected["error"] as? String, name)
        } catch {
            XCTFail("\(name): unexpected error \(error)")
        }
    }

    func testSharedValidatorCases() throws {
        let all = try cases()
        XCTAssertEqual(all.count, 156)
        XCTAssertEqual(Set(all.compactMap { $0["name"] as? String }).count, all.count)
        for c in all { try check(c) }
    }

    func testEntireCorpusAndEveryGoldReference() throws {
        let root = SharedFixtures.root.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("eval/multilingual")
        let corpus = try EvalCorpus.load(
            manifest: Data(contentsOf: root.appendingPathComponent("manifest.json")),
            queries: Data(contentsOf: root.appendingPathComponent("queries.json")),
            readFile: { try Data(contentsOf: root.appendingPathComponent($0)) })
        XCTAssertEqual(corpus.corpusId, "multilingual-v1")
        XCTAssertEqual(corpus.documents.count, 44)
        XCTAssertEqual(corpus.questions.count, 144)
        XCTAssertEqual(corpus.gold.count, 144)
        for q in corpus.questions {
            let spans = try XCTUnwrap(corpus.gold[q.queryId], q.queryId)
            XCTAssertEqual(spans.count, q.gold.count, q.queryId)
            let selected = corpus.selectedDocuments(for: q)
            XCTAssertTrue(selected.allSatisfy { $0.metadata.notebookId == q.notebookId }, q.queryId)
            if q.caseType == "empty_selection" { XCTAssertTrue(selected.isEmpty, q.queryId) }
            for (span, gold) in zip(spans, q.gold) {
                let doc = try XCTUnwrap(selected.first { $0.metadata.documentId == span.documentId })
                let scalars = Array(doc.text.unicodeScalars)
                XCTAssertEqual(span.documentId, gold.documentId)
                XCTAssertEqual(span.contentHash, doc.metadata.contentHash)
                XCTAssertGreaterThanOrEqual(span.start, 0)
                XCTAssertLessThanOrEqual(span.end, scalars.count)
                XCTAssertEqual(Array(scalars[span.start..<span.end]), Array(gold.phrase.unicodeScalars))
            }
        }
    }

    func testScalarWindowsRetainExactTextAndOverlap() throws {
        let text = "😀abcdéf"
        let windows = try EvalCorpus.windows(text, size: 4, overlap: 1)
        XCTAssertEqual(windows.map(\.start), [0, 3, 6])
        XCTAssertEqual(windows.map(\.end), [4, 7, 8])
        XCTAssertEqual(windows.map(\.text), ["😀abc", "cdé", "́f"])
        XCTAssertThrowsError(try EvalCorpus.windows(text, size: 4, overlap: 4)) {
            XCTAssertEqual($0 as? EvalFailure, EvalFailure("invalid_window"))
        }
    }

    func testSharedWindowCases() throws {
        let cases = try XCTUnwrap(try SharedFixtures.json("contracts/eval-assets-v1.json")["window_cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 3)
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            let input = try XCTUnwrap(c["input"] as? [String: Any])
            let expected = try XCTUnwrap(c["expected"] as? [String: Any])
            do {
                let windows = try EvalCorpus.windows(input["text"] as! String,
                    size: input["size"] as! Int, overlap: input["overlap"] as! Int)
                XCTAssertTrue(expected["error"] is NSNull, name)
                let wanted = try XCTUnwrap(expected["windows"] as? [[String: Any]])
                XCTAssertEqual(windows.map(\.start), wanted.map { $0["start"] as! Int }, name)
                XCTAssertEqual(windows.map(\.end), wanted.map { $0["end"] as! Int }, name)
                XCTAssertEqual(windows.map { Array($0.text.unicodeScalars) },
                    wanted.map { Array(($0["text"] as! String).unicodeScalars) }, name)
            } catch let error as EvalFailure {
                XCTAssertEqual(error.code, expected["error"] as? String, name)
            }
        }
    }

    func testUnsafeFixturePathsAreRejectedBeforeReading() throws {
        for c in try cases() where (c["expected"] as? [String: Any])?["error"] as? String == "invalid_path" {
            var reads = 0
            XCTAssertThrowsError(try EvalCorpus.load(
                manifest: bytes("manifest", in: c), queries: bytes("queries", in: c),
                readFile: { _ in reads += 1; return Data() })) {
                XCTAssertEqual($0 as? EvalFailure, EvalFailure("invalid_path"), c["name"] as! String)
            }
            XCTAssertEqual(reads, 0, c["name"] as! String)
        }
    }
}

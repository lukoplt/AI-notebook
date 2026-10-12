import CryptoKit
import Foundation
import XCTest
@testable import AINotebookCore

@MainActor
final class EvalRunnerTests: XCTestCase {
    private func corpusURL() -> URL {
        SharedFixtures.root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("eval/multilingual")
    }

    func testSharedOptions() throws {
        let roots = try XCTUnwrap(SharedFixtures.json("contracts/eval-cli-v1.json")["cases"] as? [[String: Any]])
        func flatten(_ rows: [[String: Any]]) -> [[String: Any]] {
            rows.flatMap { [$0] + flatten($0["subcases"] as? [[String: Any]] ?? []) }
        }
        let cases = flatten(roots)
        XCTAssertEqual(cases.count, 107)
        XCTAssertEqual(Set(cases.map { $0["name"] as! String }).count, 107)
        for c in cases {
            let name = c["name"] as! String, args = c["args"] as! [String]
            let expected = c["expected"] as! [String: Any]
            // The shared eval fixture predates the binding folder-rag-v1 §5
            // numeric-final-label rule. The contract rejects 1234 as a host;
            // keep this explicit override until the shared-assets owner updates it.
            let error = name == "host-single-numeric-label" ? "usage" : expected["error"] as? String
            do {
                let options = try EvalOptions.parse(args)
                XCTAssertNil(error, name)
                XCTAssertEqual(options.root, expected["root"] as? String, name)
                XCTAssertEqual(options.mode, expected["mode"] as? String, name)
                XCTAssertEqual(options.model, expected["model"] as? String, name)
                XCTAssertEqual(options.host, expected["host"] as? String, name)
                XCTAssertEqual(options.topK, expected["top_k"] as? Int, name)
                XCTAssertEqual(options.fetchK, expected["fetch_k"] as? Int, name)
                XCTAssertEqual(options.jsonPath, expected["json_path"] as? String, name)
                XCTAssertEqual(options.markdownPath, expected["markdown_path"] as? String, name)
                XCTAssertEqual(options.validateOnly, expected["validate_only"] as? Bool, name)
            } catch let failure as EvalFailure {
                XCTAssertNotNil(error, name)
                XCTAssertEqual(failure.code, error, name)
            } catch {
                XCTFail("\(name): unexpected error \(error)")
            }
        }
    }

    func testOfflineRunHasAllRowsAndNoInventedHybridOrPackingScore() async throws {
        let loaded = try EvalRunner.load(root: corpusURL())
        let options = try EvalOptions.parse(["--dataset", "multilingual", "--mode", "lexical"])
        let embedder = EvalRunnerTestEmbedder { _, _ in [] }
        let report = try await EvalRunner.run(corpus: loaded.corpus, corpusHash: loaded.hash,
            options: options, embedder: embedder)
        XCTAssertEqual(report.documents, 44)
        XCTAssertEqual(report.queriesTotal, 144)
        XCTAssertEqual(report.queries.count, 144)
        XCTAssertEqual(report.queries.map(\.queryId), loaded.corpus.questions.map(\.queryId))
        XCTAssertEqual(report.absentQueries, 4)
        XCTAssertEqual(report.emptySelectionQueries, 4)
        XCTAssertEqual(report.overviewQueries, 4)
        XCTAssertEqual(report.metrics["hybrid_recall_at_top_k"], .unavailable)
        XCTAssertEqual(report.metrics["packed_evidence_recall"], .unavailable)
        XCTAssertNil(report.model)
        XCTAssertNil(report.dimensions)
        XCTAssertEqual(report.capabilities, ["packed_evidence": "not_available", "overview": "not_available"])
        for row in report.queries where row.caseType == "empty_selection" {
            XCTAssertEqual(row.filesInScope, 0)
            XCTAssertEqual(row.candidatesWithChunks, 0)
            XCTAssertTrue(row.lexical.isEmpty && row.vector.isEmpty && row.fused.isEmpty)
        }
        let overview = report.queries.filter { $0.status == "deferred_overview_wp8" }
        XCTAssertEqual(overview.count, 4)
        XCTAssertTrue(overview.allSatisfy { $0.metrics.values.allSatisfy { $0.status == "not_applicable" } })
        let calls = await embedder.batches
        XCTAssertTrue(calls.isEmpty, "Lexical mode must make no embedding call, including ingestion")
    }

    func testInjectedEmptyPackIsMeasuredZeroAndSkipsOverviewAndEmptySelection() async throws {
        let loaded = try EvalRunner.load(root: corpusURL())
        let options = try EvalOptions.parse(["--dataset", "multilingual"])
        let calls = EvalRunnerPackCalls()
        let report = try await EvalRunner.run(corpus: loaded.corpus, corpusHash: loaded.hash,
            options: options, pack: { question, _ in
                await calls.record(question.queryId)
                return []
            })
        XCTAssertEqual(report.metrics["packed_evidence_recall"]?.status, "measured")
        XCTAssertEqual(report.metrics["packed_evidence_recall"]?.recallBp, 0)
        XCTAssertGreaterThan(report.metrics["packed_evidence_recall"]?.total ?? 0, 0)
        XCTAssertEqual(report.capabilities["packed_evidence"], "measured")
        let called = await calls.queryIds
        XCTAssertEqual(called, loaded.corpus.questions.filter {
            $0.caseType != "overview" && !loaded.corpus.selectedDocuments(for: $0).isEmpty
        }.map(\.queryId))
    }

    func testOptionsRejectIntegersOutsidePortableRange() throws {
        for flag in ["--top-k", "--fetch-k"] {
            XCTAssertThrowsError(try EvalOptions.parse(["--dataset", "multilingual", flag, "2147483648"])) {
                XCTAssertEqual($0 as? EvalFailure, EvalFailure("usage"))
            }
        }
    }

    func testOfflineReportsAreDeterministicAndGroupTotalsMatchGlobal() async throws {
        let loaded = try EvalRunner.load(root: corpusURL())
        let manifest = try Data(contentsOf: corpusURL().appendingPathComponent("manifest.json"))
        let queries = try Data(contentsOf: corpusURL().appendingPathComponent("queries.json"))
        XCTAssertEqual(loaded.hash, hash(manifest + Data([0]) + queries))
        let options = try EvalOptions.parse(["--dataset", "multilingual"])
        let first = try await EvalRunner.run(corpus: loaded.corpus, corpusHash: loaded.hash, options: options)
        let second = try await EvalRunner.run(corpus: loaded.corpus, corpusHash: loaded.hash, options: options)
        XCTAssertEqual(try first.jsonData(), try second.jsonData())
        for (name, metric) in first.metrics where metric.status == "measured" {
            for groups in [first.byLanguage, first.byCaseType] {
                XCTAssertEqual(groups.values.reduce(0) { $0 + ($1[name]?.found ?? 0) }, metric.found, name)
                XCTAssertEqual(groups.values.reduce(0) { $0 + ($1[name]?.total ?? 0) }, metric.total, name)
            }
        }
    }

    func testSharedScopesFilterBothBranchesBeforeLimits() async throws {
        let names: Set<String> = ["disjoint-branches", "folder-before-limit", "other-notebook-exclusion", "empty-selection"]
        let cases = try EvalRetrievalFixtures.cases().filter { names.contains($0["name"] as! String) }
        XCTAssertEqual(cases.count, names.count)
        for c in cases {
            let name = c["name"] as! String, input = c["input"] as! [String: Any]
            let expected = c["expected"] as! [String: Any]
            var frozen: [String: [Float]] = [:]
            let documents = (input["documents"] as! [[String: Any]]).map { d in
                let chunks = d["chunks"] as! [[String: Any]]
                XCTAssertEqual(chunks.count, 1, name)
                let text = chunks[0]["text"] as! String
                frozen[text] = EvalRetrievalFixtures.vector(chunks[0]["vector"] as! [Any])
                return document(d["document_id"] as! String, sourceId: Int64(d["source_id"] as! Int),
                    notebookId: Int64(d["notebook_id"] as! Int), folderId: (d["folder_id"] as? Int).map(Int64.init), text: text)
            }
            let scope = try JSONDecoder().decode(RetrievalScope.self,
                from: JSONSerialization.data(withJSONObject: input["scope"]!))
            let notebook = Int64(input["notebook_id"] as! Int)
            let corpus = makeCorpus(documents, notebookId: notebook, scope: scope, text: input["query"] as! String)
            let queryVector = EvalRetrievalFixtures.vector(input["query_vector"] as! [Any])
            let documentVectors = frozen
            let embedder = EvalRunnerTestEmbedder { call, texts in
                call == 1 ? texts.map { documentVectors[$0]! } : texts.map { _ in queryVector }
            }
            let options = try EvalOptions.parse(["--dataset", "multilingual", "--mode", "ollama", "--model", "fixture-model",
                "--top-k", String(input["top_k"] as! Int), "--fetch-k", String(input["fetch_k"] as! Int)])
            let report = try await EvalRunner.run(corpus: corpus, corpusHash: "fixture", options: options, embedder: embedder)
            let row = try XCTUnwrap(report.queries.first)
            for (branch, spans) in [("lexical", row.lexical), ("vector", row.vector), ("fused", row.fused)] {
                let identities = expected[branch] as! [[String: Any]]
                XCTAssertEqual(spans.map(\.documentId), identities.map { $0["document_id"] as! String }, name + ": " + branch)
                for span in spans {
                    let d = try XCTUnwrap(documents.first { $0.metadata.documentId == span.documentId })
                    XCTAssertEqual(span.contentHash, d.metadata.contentHash, name)
                    XCTAssertEqual(span.start, 0, name)
                    XCTAssertEqual(span.end, d.text.unicodeScalars.count, name)
                }
            }
            XCTAssertEqual(row.filesInScope, corpus.selectedDocuments(for: corpus.questions[0]).count, name)
            XCTAssertEqual(report.dimensions, 2, name)
            let batches = await embedder.batches
            XCTAssertEqual(batches.count, 1 + (expected["embedding_calls"] as! Int), name)
        }
    }

    func testInvalidDocumentEmbeddingBatchesFailBeforeQuerying() async throws {
        let documents = (1...17).map { document(String(format: "d%02d", $0), sourceId: Int64(100 + $0), text: "fox document \($0)") }
        let corpus = makeCorpus(documents)
        let options = try EvalOptions.parse(["--dataset", "multilingual", "--mode", "ollama", "--model", "fixture-model"])
        for fault in EvalRunnerEmbeddingFault.allCases {
            let embedder = EvalRunnerTestEmbedder { call, inputs in
                var vectors = inputs.map { _ in [Float(1), 0] }
                switch fault {
                case .tooFew: vectors.removeLast()
                case .tooMany: vectors.append([1, 0])
                case .empty: vectors[0] = []
                case .nonfinite: vectors[0] = [.infinity, 0]
                case .zero: vectors[0] = [0, 0]
                case .mixedDimensions: vectors[0] = [1]
                case .changedBatchDimensions:
                    if call > 1 { vectors = inputs.map { _ in [1] } }
                }
                return vectors
            }
            do {
                _ = try await EvalRunner.run(corpus: corpus, corpusHash: "fixture", options: options, embedder: embedder)
                XCTFail("Accepted invalid embedding: \(fault)")
            } catch {
                XCTAssertEqual(error as? EvalFailure, EvalFailure("invalid_embedding"), String(describing: fault))
            }
            let batches = await embedder.batches
            XCTAssertEqual(batches.count, fault == .changedBatchDimensions ? 2 : 1, String(describing: fault))
            XCTAssertEqual(batches.first?.count, 16)
        }
    }

    func testEmbeddingBatchesPreserveCanonicalTextAndModel() async throws {
        let documents = (1...17).reversed().map {
            document(String(format: "d%02d", $0), sourceId: Int64(100 + $0), text: "😀 fox document \($0)\n")
        }
        let corpus = makeCorpus(documents)
        let options = try EvalOptions.parse(["--dataset", "multilingual", "--mode", "ollama", "--model", "fixture-model"])
        let embedder = EvalRunnerTestEmbedder { _, inputs in inputs.map { _ in [1, 0] } }
        let report = try await EvalRunner.run(corpus: corpus, corpusHash: "fixture", options: options, embedder: embedder)
        let batches = await embedder.batches, models = await embedder.models
        XCTAssertEqual(batches.map(\.count), [16, 1, 1])
        XCTAssertEqual(Array(batches.prefix(2)).flatMap { $0 }, documents.sorted { $0.metadata.documentId < $1.metadata.documentId }.map(\.text))
        XCTAssertEqual(models, ["fixture-model", "fixture-model", "fixture-model"])
        XCTAssertEqual(report.dimensions, 2)
    }

    func testLoaderRejectsLeafAndDirectorySymlinksAndReportsMissingFiles() throws {
        for path in ["documents", "documents/en/customer/contracts/master.md", "missing"] {
            let owned = FileManager.default.temporaryDirectory.appendingPathComponent("eval-runner-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: owned) }
            let root = owned.appendingPathComponent("root")
            try FileManager.default.copyItem(at: corpusURL(), to: root)
            if path == "missing" {
                try FileManager.default.removeItem(at: root.appendingPathComponent("documents/en/customer/contracts/master.md"))
            } else {
                let original = root.appendingPathComponent(path), outside = owned.appendingPathComponent("outside")
                try FileManager.default.moveItem(at: original, to: outside)
                try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
            }
            XCTAssertThrowsError(try EvalRunner.load(root: root)) {
                XCTAssertEqual($0 as? EvalFailure, EvalFailure(path == "missing" ? "missing_file" : "invalid_path"), path)
            }
        }
    }

    func testPackingRejectsUnselectedHashAndInvalidScalarBounds() async throws {
        let selected = document("selected", sourceId: 101, text: "😀fox gap target")
        let outside = document("outside", sourceId: 102, text: "outside fox")
        let corpus = makeCorpus([selected, outside], scope: .selection(sourceIds: [101], folderIds: []))
        let options = try EvalOptions.parse(["--dataset", "multilingual"])
        let hash = selected.metadata.contentHash, count = selected.text.unicodeScalars.count
        let invalid = [
            EvalSpan(documentId: "missing", contentHash: hash, start: 0, end: 1),
            EvalSpan(documentId: "outside", contentHash: outside.metadata.contentHash, start: 0, end: 1),
            EvalSpan(documentId: "selected", contentHash: String(repeating: "0", count: 64), start: 0, end: 1),
            EvalSpan(documentId: "selected", contentHash: hash, start: -1, end: 1),
            EvalSpan(documentId: "selected", contentHash: hash, start: 1, end: 1),
            EvalSpan(documentId: "selected", contentHash: hash, start: 3, end: 2),
            EvalSpan(documentId: "selected", contentHash: hash, start: 0, end: count + 1)
        ]
        for span in invalid {
            do {
                _ = try await EvalRunner.run(corpus: corpus, corpusHash: "fixture", options: options, pack: { _, _ in [span] })
                XCTFail("Accepted invalid packed span: \(span)")
            } catch {
                XCTAssertEqual(error as? EvalFailure, EvalFailure("invalid_packed_span"))
            }
        }
    }

    func testPackingPreservesSeparateRangesAndCanonicalScalarOffsets() async throws {
        let d = document("selected", sourceId: 101, text: "😀fox gap target")
        let gold = EvalSpan(documentId: "selected", contentHash: d.metadata.contentHash, start: 5, end: 8)
        let corpus = makeCorpus([d], gold: [gold])
        let options = try EvalOptions.parse(["--dataset", "multilingual"])
        let report = try await EvalRunner.run(corpus: corpus, corpusHash: "fixture", options: options, pack: { _, evidence in
            XCTAssertEqual(evidence.map(\.text), [d.text])
            XCTAssertEqual(evidence.map(\.span), [EvalSpan(documentId: "selected", contentHash: d.metadata.contentHash,
                start: 0, end: d.text.unicodeScalars.count)])
            return [EvalSpan(documentId: "selected", contentHash: d.metadata.contentHash, start: 0, end: 5),
                    EvalSpan(documentId: "selected", contentHash: d.metadata.contentHash, start: 8, end: d.text.unicodeScalars.count)]
        })
        XCTAssertEqual(report.metrics["candidate_recall_at_fetch_k"]?.recallBp, 10000)
        XCTAssertEqual(report.metrics["packed_evidence_recall"]?.recallBp, 0)
    }

    func testFilesInScopeIncludesDocumentsWithoutScalarWindows() async throws {
        let corpus = makeCorpus([document("empty", sourceId: 101, text: ""), document("full", sourceId: 102, text: "fox")])
        let options = try EvalOptions.parse(["--dataset", "multilingual"])
        let report = try await EvalRunner.run(corpus: corpus, corpusHash: "fixture", options: options)
        let row = try XCTUnwrap(report.queries.first)
        XCTAssertEqual(row.filesInScope, 2)
        XCTAssertEqual(row.candidatesWithChunks, 1)
        XCTAssertEqual(row.fused.map(\.documentId), ["full"])
    }

    private func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func document(_ id: String, sourceId: Int64, notebookId: Int64 = 77,
                          folderId: Int64? = nil, text: String) -> LoadedEvalDocument {
        let digest = hash(Data(text.utf8))
        return LoadedEvalDocument(metadata: EvalDocument(documentId: id, sourceId: sourceId, notebookId: notebookId,
            folderId: folderId, path: "documents/\(id).txt", relPath: "\(id).txt", language: "en", encoding: "utf-8",
            rawSha256: digest, contentHash: digest), text: text)
    }

    private func makeCorpus(_ documents: [LoadedEvalDocument], notebookId: Int64 = 77,
                            scope: RetrievalScope = .all, text: String = "fox", gold: [EvalSpan]? = nil) -> EvalCorpus {
        let selected = documents.filter { d in
            guard d.metadata.notebookId == notebookId else { return false }
            switch scope {
            case .all: return true
            case let .selection(sources, folders):
                return sources.contains(d.metadata.sourceId) || d.metadata.folderId.map(folders.contains) == true
            }
        }
        let spans = gold ?? selected.filter { !$0.text.isEmpty }.prefix(1).map {
            EvalSpan(documentId: $0.metadata.documentId, contentHash: $0.metadata.contentHash, start: 0, end: $0.text.unicodeScalars.count)
        }
        let question = EvalQuestion(queryId: "q", text: text, language: "en",
            caseType: scope.isEmptySelection ? "empty_selection" : (spans.isEmpty ? "absent" : "answer"), tags: [],
            notebookId: notebookId, scope: scope, gold: spans.map { span in
                let d = documents.first { $0.metadata.documentId == span.documentId }!
                let phrase = String(String.UnicodeScalarView(Array(d.text.unicodeScalars)[span.start..<span.end]))
                return EvalGold(documentId: span.documentId, contentHash: span.contentHash, phrase: phrase, occurrence: 1)
            }, absentReason: scope.isEmptySelection ? "empty_scope" : (spans.isEmpty ? "not_in_corpus" : nil), overviewDocumentIds: [])
        return EvalCorpus(corpusId: "runner-fixture", documents: documents, questions: [question], gold: ["q": spans])
    }
}

private actor EvalRunnerTestEmbedder: EmbeddingProducing {
    private(set) var batches: [[String]] = []
    private(set) var models: [String] = []
    let reply: @Sendable (Int, [String]) -> [[Float]]

    init(reply: @escaping @Sendable (Int, [String]) -> [[Float]]) { self.reply = reply }

    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        batches.append(inputs)
        models.append(model)
        return reply(batches.count, inputs)
    }
}

private enum EvalRunnerEmbeddingFault: CaseIterable, Sendable {
    case tooFew, tooMany, empty, nonfinite, zero, mixedDimensions, changedBatchDimensions
}

private actor EvalRunnerPackCalls {
    private(set) var queryIds: [String] = []
    func record(_ queryId: String) { queryIds.append(queryId) }
}

import CryptoKit
import Foundation
import XCTest
@testable import AINotebookCore

@MainActor final class BenchmarkRunnerTests: XCTestCase {
    private let file = "benchmark-run-v1.json"

    private func corpusURL() -> URL {
        SharedFixtures.root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("eval/multilingual")
    }

    private func code(_ body: () throws -> Void) -> String? {
        do { try body(); return nil }
        catch let e as BenchmarkError { return e.code }
        catch { return "unexpected:\(error)" }
    }

    private func with(_ o: BenchmarkOptions, chunkCounts: [Int]) -> BenchmarkOptions {
        BenchmarkOptions(command: o.command, mode: o.mode, root: o.root, host: o.host, profileIds: o.profileIds,
                         chunkCounts: chunkCounts, chatModel: o.chatModel, calibration: o.calibration,
                         tokenizerRoot: o.tokenizerRoot, embeddingCounts: o.embeddingCounts, queries: o.queries,
                         warmup: o.warmup, concurrent: o.concurrent, seed: o.seed, fetchK: o.fetchK, topK: o.topK,
                         evidenceShareBp: o.evidenceShareBp, runtimeContext: o.runtimeContext, maxOutput: o.maxOutput,
                         ollamaPid: o.ollamaPid, json: o.json, out: o.out)
    }

    // MARK: - CLI

    func testParserRejectsRepeatedFlagsAndKeepsContractDefaults() throws {
        let options = try BenchmarkOptions.parse(["--benchmark", "--mode", "fixture", "--json", "a.json", "--out", "a.md"])
        XCTAssertEqual(options.topK, 16); XCTAssertEqual(options.fetchK, 32)
        XCTAssertEqual(options.chunkCounts, [100000, 200000]); XCTAssertEqual(options.profileIds.count, 7)
        XCTAssertThrowsError(try BenchmarkOptions.parse(["--benchmark", "--mode", "fixture",
                                                         "--queries", "200", "--queries", "1", "--json", "a", "--out", "b"]))
    }

    func testSharedCliCases() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "cli")
        XCTAssertEqual(rows.count, 24)
        for c in rows {
            let name = c["name"] as! String
            let args = c["args"] as! [String]
            if let error = c["error"] as? String {
                XCTAssertEqual(code { _ = try BenchmarkOptions.parse(args) }, error, name)
                XCTAssertEqual(c["exitCode"] as? Int, 2)
                continue
            }
            let o = try BenchmarkOptions.parse(args)
            let actual: [String: Any] = [
                "calibration": o.calibration ?? NSNull(), "chatModel": o.chatModel, "chunkCounts": o.chunkCounts,
                "command": o.command, "concurrent": o.concurrent, "embeddingCounts": o.embeddingCounts ?? NSNull(),
                "evidenceShareBp": o.evidenceShareBp, "fetchK": o.fetchK, "host": o.host, "json": o.json,
                "maxOutput": o.maxOutput, "mode": o.mode, "ollamaPid": o.ollamaPid.map { Int($0) as Any } ?? NSNull(),
                "out": o.out, "profileIds": o.profileIds, "queries": o.queries, "root": o.root,
                "runtimeContext": o.runtimeContext, "seed": o.seed, "tokenizerRoot": o.tokenizerRoot ?? NSNull(),
                "topK": o.topK, "warmup": o.warmup,
            ]
            XCTAssertEqual(actual as NSDictionary, c["expected"] as? NSDictionary, name)
        }
    }

    // MARK: - Citation audit

    func testPackedRecallUsesExactRetainedSpanAndRevision() throws {
        let text = "prefix gold", hash = EvalCorpus.sha256(Data(text.utf8))
        let revision = BenchmarkRevision(sourceId: 1, revisionId: 10, documentId: "d", contentHash: hash, text: text,
                                         chunks: [ChunkReference(chunkId: 100, sourceId: 1, revisionId: 10, ord: 0)])
        var citation = Citation(marker: 1, chunkId: 100, sourceId: 1, snippet: "prefix")
        citation.revisionId = 10; citation.text = "prefix"
        citation.spans = [CitationSpan(start: 0, end: 6, pageFrom: nil, pageTo: nil)]; citation.chunkIds = [100]
        let gold = [EvalSpan(documentId: "d", contentHash: hash, start: 7, end: 11)]
        let audit = try BenchmarkRunner.audit(citations: [citation], answer: "Claim [1] [99]", revisions: [revision], gold: gold)
        XCTAssertEqual(audit.snapshotsCorrect, 1); XCTAssertEqual(audit.answerMarkersCorrect, 1)
        XCTAssertEqual(audit.answerMarkersTotal, 2); XCTAssertEqual(audit.answerGoldSupported, 0)
        XCTAssertEqual(EvalMetrics.recall(gold: gold, evidence: audit.packed).found, 0)
        citation.revisionId = 11
        let stale = try BenchmarkRunner.audit(citations: [citation], answer: "[1]", revisions: [revision], gold: gold)
        XCTAssertEqual(stale.snapshotsCorrect, 0); XCTAssertTrue(stale.packed.isEmpty)
    }

    private func spans(_ value: Any?) throws -> [EvalSpan] {
        try JSONDecoder().decode([EvalSpan].self, from: JSONSerialization.data(withJSONObject: value!))
    }

    func testSharedAuditCases() throws {
        let rows = try BenchmarkFixture.cases(file, kind: "audit")
        XCTAssertEqual(rows.count, 8)
        for c in rows {
            let name = c["name"] as! String
            let revisions = (c["revisions"] as! [[String: Any]]).map { r in
                BenchmarkRevision(sourceId: (r["sourceId"] as! NSNumber).int64Value,
                                  revisionId: (r["revisionId"] as! NSNumber).int64Value,
                                  documentId: r["documentId"] as! String, contentHash: r["contentHash"] as! String,
                                  text: r["text"] as! String, chunks: (r["chunks"] as! [[String: NSNumber]]).map {
                                      ChunkReference(chunkId: $0["chunkId"]!.int64Value, sourceId: $0["sourceId"]!.int64Value,
                                                     revisionId: $0["revisionId"]!.int64Value, ord: $0["ord"]!.intValue)
                                  })
            }
            let citations = try JSONDecoder().decode([Citation].self,
                                                     from: JSONSerialization.data(withJSONObject: c["citations"]!))
            let gold = try spans(c["gold"])
            let audit = try BenchmarkRunner.audit(citations: citations, answer: c["answer"] as! String,
                                                  revisions: revisions, gold: gold)
            let e = c["expected"] as! [String: Any]
            XCTAssertEqual(audit.packed, try spans(e["packed"]), name)
            XCTAssertEqual(audit.snapshotsCorrect, e["snapshotsCorrect"] as? Int, name)
            XCTAssertEqual(audit.snapshotsTotal, e["snapshotsTotal"] as? Int, name)
            XCTAssertEqual(audit.answerMarkersCorrect, e["answerMarkersCorrect"] as? Int, name)
            XCTAssertEqual(audit.answerMarkersTotal, e["answerMarkersTotal"] as? Int, name)
            XCTAssertEqual(audit.answerGoldSupported, e["answerGoldSupported"] as? Int, name)
            XCTAssertEqual(audit.answerMarkersJudged, e["answerMarkersJudged"] as? Int, name)
            let recall = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EvalMetrics.recall(gold: gold, evidence: audit.packed)))
            XCTAssertEqual(recall as? NSDictionary, e["packedRecall"] as? NSDictionary, name)
        }
    }

    // MARK: - Query cases (mini corpus)

    /// Three-document corpus; `answer` adds one positive-gold answer question.
    private func miniCorpus(answer: Bool = false) throws -> EvalCorpus {
        func hash(_ t: String) -> String { EvalCorpus.sha256(Data(t.utf8)) }
        let texts = ["documents/x.txt": "Alpha text.", "documents/y.txt": "Beta text.", "documents/z.txt": ""]
        func doc(_ id: String, _ source: Int, _ path: String, _ rel: String) -> [String: Any] {
            ["content_hash": hash(texts[path]!), "document_id": id, "encoding": "utf-8", "folder_id": 1, "language": "en",
             "notebook_id": 1, "path": path, "raw_sha256": hash(texts[path]!), "rel_path": rel, "source_id": source]
        }
        let manifest: [String: Any] = ["contract": "eval-corpus", "corpus_id": "mini", "license": "MIT", "version": 1,
                                       "documents": [doc("x", 1, "documents/x.txt", "a/x.txt"),
                                                     doc("y", 2, "documents/y.txt", "b/y.txt"),
                                                     doc("z", 3, "documents/z.txt", "c/z.txt")]]
        let queries: [String: Any] = ["contract": "eval-queries", "corpus_id": "mini", "version": 1, "queries": [
            ["absent_reason": NSNull(), "case_type": "overview", "language": "en", "notebook_id": 1, "query_id": "overview",
             "overview_document_ids": ["x", "y"], "scope": ["kind": "all"], "tags": [String](), "text": "Summarize",
             "gold": [["content_hash": hash(texts["documents/x.txt"]!), "document_id": "x", "occurrence": 1, "phrase": "Alpha"],
                      ["content_hash": hash(texts["documents/y.txt"]!), "document_id": "y", "occurrence": 1, "phrase": "Beta"]]],
            ["absent_reason": "empty_scope", "case_type": "empty_selection", "language": "en", "notebook_id": 1,
             "query_id": "empty", "overview_document_ids": [String](),
             "scope": ["kind": "selection", "sourceIds": [Int](), "folderIds": [Int]()], "tags": [String](),
             "text": "Anything?", "gold": [[String: Any]]()],
        ] + (answer ? [
            ["absent_reason": NSNull(), "case_type": "answer", "language": "en", "notebook_id": 1, "query_id": "answer",
             "overview_document_ids": [String](), "scope": ["kind": "all"], "tags": [String](), "text": "Alpha?",
             "gold": [["content_hash": hash(texts["documents/x.txt"]!), "document_id": "x", "occurrence": 1, "phrase": "Alpha"]]],
        ] : [])]
        return try EvalCorpus.load(manifest: JSONSerialization.data(withJSONObject: manifest),
                                   queries: JSONSerialization.data(withJSONObject: queries),
                                   readFile: { Data(texts[$0]!.utf8) })
    }

    func testSharedQueryCases() async throws {
        let corpus = try miniCorpus()
        let options = with(try BenchmarkOptions.parse(["--benchmark", "--mode", "fixture", "--profiles", "nomic-v2-256",
                                                       "--queries", "3", "--warmup", "1", "--json", "a", "--out", "b"]),
                           chunkCounts: [])
        let env = BenchmarkRunner.fixtureEnvironment(options)
        let report = try await BenchmarkRunner.run(options: options, corpus: corpus, corpusHash: String(repeating: "0", count: 64),
                                                   env: env)
        let rows = Dictionary(uniqueKeysWithValues: try XCTUnwrap(report.candidates.first).quality.queries.map { ($0.eval.queryId, $0) })
        let cases = try BenchmarkFixture.cases(file, kind: "query")
        XCTAssertEqual(cases.count, 3)
        for c in cases {
            let name = c["name"] as! String
            let e = c["expected"] as! [String: Any]
            switch name {
            case "empty-selection":
                let row = try XCTUnwrap(rows["empty"])
                XCTAssertEqual(row.citationMap.count, e["citations"] as? Int)
                XCTAssertNil(row.preparedHash); XCTAssertNil(row.answerText)
                XCTAssertTrue(row.eval.metrics.values.allSatisfy { $0.status == "not_applicable" })
            case "overview":
                let row = try XCTUnwrap(rows["overview"])
                let o = e["overview"] as! [String: Int]
                XCTAssertEqual(row.overview, BenchmarkOverview(filesInScope: o["filesInScope"]!,
                                                               publishedCandidateFiles: o["publishedCandidateFiles"]!,
                                                               filesIncluded: o["filesIncluded"]!))
                XCTAssertEqual(row.eval.metrics["packed_evidence_recall"]?.status, "not_applicable")
                XCTAssertNil(row.timing)
            case "hit-own-revision":
                let input = c["input"] as! [String: Any]
                var revisions: [PackSourceRevision: BenchmarkRevision] = [:]
                for r in input["revisions"] as! [[String: Any]] {
                    let s = (r["sourceId"] as! NSNumber).int64Value, rev = (r["revisionId"] as! NSNumber).int64Value
                    revisions[PackSourceRevision(sourceId: s, revisionId: rev)] = BenchmarkRevision(
                        sourceId: s, revisionId: rev, documentId: r["documentId"] as! String,
                        contentHash: r["contentHash"] as! String, text: "", chunks: [])
                }
                let actual = try (input["hits"] as! [[String: Any]]).map { h in
                    try BenchmarkRunner.span(for: ChunkReference(chunkId: (h["chunkId"] as! NSNumber).int64Value,
                                                                 sourceId: (h["sourceId"] as! NSNumber).int64Value,
                                                                 revisionId: (h["revisionId"] as! NSNumber).int64Value, ord: 0),
                                             start: h["start"] as! Int, end: h["end"] as! Int, revisions: revisions)
                }
                XCTAssertEqual(actual, try spans(e["spans"]))
            default: XCTFail(name)
            }
        }
        // Only the overview question reached the provider.
        XCTAssertEqual(env.counters.chatCalls, 1)
        XCTAssertEqual(env.counters.embeddingCalls, 0)
        XCTAssertEqual(env.counters.retrievalCalls, 0)
        XCTAssertEqual(env.counters.neighbourCalls, 0)
        XCTAssertEqual(env.counters.leakedPins, 0)
    }

    // MARK: - Phases and end-to-end fixture runs

    /// Phase traces do not depend on corpus size; a small corpus with an answer, an overview and
    /// an empty selection keeps these four fixture runs fast. The full 144-query corpus runs below.
    func testSharedPhaseCases() async throws {
        let loaded = (corpus: try miniCorpus(answer: true), hash: String(repeating: "0", count: 64))
        let rows = try BenchmarkFixture.cases(file, kind: "phase")
        XCTAssertEqual(rows.count, 3)
        for c in rows {
            let name = c["name"] as! String
            let input = c["input"] as! [String: Any]
            let expected = c["expected"] as! [String: Any]
            let options = try BenchmarkOptions.parse([
                "--benchmark", "--mode", "fixture", "--profiles", (input["profiles"] as! [String]).joined(separator: ","),
                "--chunks", (input["chunkCounts"] as! [Int]).map(String.init).joined(separator: ","),
                "--concurrent", input["concurrent"] as! String, "--queries", String(input["queries"] as! Int),
                "--warmup", String(input["warmup"] as! Int), "--json", "a", "--out", "b"])
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("wp7-phase-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: work) }
            let env = BenchmarkRunner.fixtureEnvironment(options, workDirectory: work)
            var trace: [BenchmarkPhaseEvent] = []
            env.trace = { trace.append($0) }
            if let cancelAt = input["cancelAt"] as? [String: Any] {
                env.beforeMeasuredQuery = { phase, chunks, index in
                    if phase == cancelAt["phase"] as? String, chunks == cancelAt["chunks"] as? Int,
                       index == cancelAt["measuredQuery"] as? Int {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }
            let task = Task { @MainActor in
                try await BenchmarkRunner.run(options: options, corpus: loaded.corpus, corpusHash: loaded.hash, env: env)
            }
            var report: BenchmarkReportV1?
            var error: String?
            do { report = try await task.value } catch is CancellationError { error = "cancelled" }
            let expectedTrace = (expected["trace"] as! [[String: Any]]).map {
                BenchmarkPhaseEvent(phase: $0["phase"] as! String, profileId: $0["profileId"] as! String, chunks: $0["chunks"] as? Int)
            }
            XCTAssertEqual(trace, expectedTrace, name)
            let counters = expected["counters"] as! [String: Any]
            XCTAssertEqual(env.counters.leakedPins, 0, name)
            if let e = expected["error"] as? String {
                XCTAssertEqual(error, e, name)
                XCTAssertNil(report, name)
                XCTAssertEqual(env.counters.completedMeasuredQueries, counters["completedMeasuredQueries"] as? Int, name)
                XCTAssertEqual(env.counters.writerAwaited, counters["writerAwaited"] as? Bool, name)
                XCTAssertEqual(env.counters.samplerAwaited, counters["samplerAwaited"] as? Bool, name)
                XCTAssertEqual(env.counters.privateDatabasesRemoved, counters["privateDatabasesRemoved"] as? Bool, name)
                XCTAssertEqual(counters["successArtifact"] as? Bool, false)
            } else {
                XCTAssertNil(error, name)
                let report = try XCTUnwrap(report)
                XCTAssertEqual(report.candidates.count, counters["candidates"] as? Int, name)
                XCTAssertEqual(report.candidates.reduce(0) { $0 + $1.performance.count }, counters["performanceRows"] as? Int, name)
                XCTAssertEqual(env.counters.httpCalls, counters["httpCalls"] as? Int, name)
                for p in report.candidates.flatMap(\.performance) {
                    XCTAssertEqual(p.samples.count, counters["measuredQueriesPerRow"] as? Int, name)
                    XCTAssertEqual(p.warmupQueries, counters["warmupQueriesPerRow"] as? Int, name)
                }
                XCTAssertTrue(report.candidates.allSatisfy { $0.status == "complete" }, name)
                XCTAssertTrue(report.candidates.allSatisfy { $0.quality.queries.count == loaded.corpus.questions.count }, name)
                XCTAssertTrue(env.counters.privateDatabasesRemoved, name)
                try report.validate()
            }
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: work.path))?.filter { $0.hasSuffix(".sqlite") } ?? []
            XCTAssertTrue(leftovers.isEmpty, name)
        }
    }

    func testFixtureRunIsDeterministicAndMeasuresRealPackedEvidence() async throws {
        let loaded = try EvalRunner.load(root: corpusURL())
        let options = try BenchmarkOptions.parse(["--benchmark", "--mode", "fixture", "--profiles", "nomic-v2-256",
                                                  "--chunks", "1000", "--queries", "3", "--warmup", "1",
                                                  "--concurrent", "off", "--json", "a", "--out", "b"])
        let first = try await BenchmarkRunner.run(options: options, corpus: loaded.corpus, corpusHash: loaded.hash,
                                                  env: BenchmarkRunner.fixtureEnvironment(options))
        let second = try await BenchmarkRunner.run(options: options, corpus: loaded.corpus, corpusHash: loaded.hash,
                                                   env: BenchmarkRunner.fixtureEnvironment(options))
        XCTAssertEqual(try first.jsonData(), try second.jsonData())
        XCTAssertEqual(first.markdown(), second.markdown())
        XCTAssertEqual(first.mode, "fixture")
        let candidate = try XCTUnwrap(first.candidates.first)
        XCTAssertEqual(first.candidates.count, 1)
        XCTAssertEqual(candidate.status, "complete", candidate.errorCode ?? "")
        XCTAssertEqual(candidate.quality.queries.count, 144)
        XCTAssertEqual(candidate.quality.metrics["packed_evidence_recall"]?.status, "measured")
        XCTAssertGreaterThan(candidate.ingest.successfulTokens ?? 0, 0)
        XCTAssertEqual(candidate.ingest.serviceTokenStatus, "measured")
        XCTAssertEqual(candidate.performance.count, 1)
        XCTAssertTrue(candidate.quality.queries.contains { !$0.citationMap.isEmpty })
        try first.validate()
    }

    func testFixtureCalibrationFitsTrainBodiesAndChecksRenderedPrompts() async throws {
        let loaded = try EvalRunner.load(root: corpusURL())
        let options = try BenchmarkOptions.parse(["--calibrate", "--mode", "fixture", "--json", "c.json", "--out", "c.md"])
        let env = BenchmarkRunner.fixtureEnvironment(options)
        let report = try await BenchmarkRunner.calibrate(options: options, corpus: loaded.corpus, corpusHash: loaded.hash,
                                                         env: env)
        try report.validate()
        XCTAssertEqual(report.status, "complete")
        XCTAssertEqual(report.family, "ollama:" + env.chatDigest!)
        XCTAssertEqual(report.method, "ollama-raw-prompt")
        XCTAssertEqual(report.corpusHash, loaded.hash)
        XCTAssertFalse(report.rates.isEmpty)
        XCTAssertTrue(report.samples.contains { $0.split == "holdout" })
        XCTAssertTrue(report.promptChecks.contains { $0.split == "holdout" })
        XCTAssertTrue(report.promptChecks.allSatisfy { $0.actualTokens != nil })
        let train = report.samples.filter { $0.split == "train" }.map {
            TokenSample(id: $0.id, family: report.family, language: $0.language, split: "train", scalars: $0.scalars,
                        tokens: $0.tokens!)
        }
        XCTAssertEqual(try TokenCalibration.fit(train), report.rates)
        XCTAssertTrue(report.markdown().hasPrefix("# Token calibration report v1\n"))
    }
}

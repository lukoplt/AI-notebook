import XCTest
@testable import AINotebookCore

final class PathMatcherTests: XCTestCase {
    private struct V1Match: Equatable {
        let sourceId: Int64, matched: Int, weight: Int, date: Int
    }

    private static func files(_ c: [String: Any]) -> [PathMatchFile] {
        (c["files"] as! [[String: Any]]).map {
            PathMatchFile(sourceId: ($0["sourceId"] as! NSNumber).int64Value, relPath: $0["relPath"] as? String,
                          title: $0["title"] as! String, mtime: ($0["mtime"] as? NSNumber)?.int64Value)
        }
    }

    /// v1 cases, with the v2 fixture's `supersedes` replacing the cases whose order changed.
    func testSharedCases() throws {
        let fixture = try SharedFixtures.json("contracts/retrieval-paths-v1.json")
        let v2 = try SharedFixtures.json("contracts/retrieval-paths-v2.json")
        let supersedes = ((v2["supersedes"] as! [String: Any])["retrieval-paths-v1.json"] as! [String: Any])["cases"] as! [String: Any]
        XCTAssertEqual((fixture["maxMatchingFiles"] as? NSNumber)?.intValue, PathMatcher.maxMatchingFiles)
        let matcher = PathMatcher(tables: try UnicodeTables.bundled())
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 10)
        XCTAssertEqual(Set(supersedes.keys).subtracting(cases.map { $0["name"] as! String }), [])
        for c in cases {
            let name = c["name"] as! String
            let expected = ((supersedes[name] ?? c["expected"]) as! [[String: NSNumber]]).map {
                V1Match(sourceId: $0["sourceId"]!.int64Value, matched: $0["matched"]!.intValue,
                        weight: $0["weight"]!.intValue, date: $0["date"]!.intValue)
            }
            let actual = matcher.rank(query: c["query"] as! String, files: Self.files(c))
                .map { V1Match(sourceId: $0.sourceId, matched: $0.matched, weight: $0.weight, date: $0.date) }
            XCTAssertEqual(actual, expected, name)
        }
    }

    /// retrieval-paths v2 (§6): strengths, project directories and the inventory signal.
    func testSharedV2Cases() throws {
        let fixture = try SharedFixtures.json("contracts/retrieval-paths-v2.json")
        let classes = (fixture["typeClasses"] as! [[String: Any]]).map { ($0["name"] as! String, $0["stems"] as! [String]) }
        XCTAssertEqual(classes.map(\.0), PathMatcher.typeClasses.map(\.name))
        XCTAssertEqual(classes.map(\.1), PathMatcher.typeClasses.map(\.stems))
        let inventory = fixture["inventory"] as! [String: NSNumber]
        XCTAssertEqual(inventory["mapShareBp"]?.intValue, ContextPackRendering.Inventory.mapShareBp)
        XCTAssertEqual(inventory["floorEntries"]?.intValue, ContextPackRendering.Inventory.floorEntries)
        XCTAssertEqual(inventory["floorMaxShareBp"]?.intValue, ContextPackRendering.Inventory.floorMaxShareBp)
        XCTAssertEqual(inventory["fileLevelMax"]?.intValue, ContextPackRendering.Inventory.fileLevelMax)
        let matcher = PathMatcher(tables: try UnicodeTables.bundled())
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 18)
        for c in cases {
            let name = c["name"] as! String
            let expected = c["expected"] as! [String: Any]
            let matches = (expected["matches"] as! [[String: Any]]).map {
                PathMatch(sourceId: ($0["sourceId"] as! NSNumber).int64Value, matched: ($0["matched"] as! NSNumber).intValue,
                          score: ($0["score"] as! NSNumber).intValue, weight: ($0["weight"] as! NSNumber).intValue,
                          date: ($0["date"] as! NSNumber).intValue, project: $0["project"] as! String)
            }
            let actual = matcher.ranking(query: c["query"] as! String, files: Self.files(c))
            XCTAssertEqual(actual.matches, matches, name)
            XCTAssertEqual(actual.inventory, expected["inventory"] as? Bool, name)
        }
    }

    func testSharedV2MapCases() throws {
        let fixture = try SharedFixtures.json("contracts/retrieval-paths-v2.json")
        let cases = try XCTUnwrap(fixture["mapCases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 6)
        var input = try ContextPackFixtures.input("basic-cs")
        for c in cases {
            let name = c["name"] as! String
            input.folderMap = try ContextPackFixtures.decode(c["folderMap"]!, as: [PackFile].self)
            let budget = (c["matchingBudget"] as? [String: NSNumber]).map {
                ContextPackRendering.MatchingBudget(ceiling: $0["ceiling"]!.intValue, floorLimit: $0["floorLimit"]!.intValue)
            }
            let result = try ContextPackRendering.map(input, ceiling: (c["ceiling"] as! NSNumber).intValue, direct: [],
                                                      estimator: PlaceholderTokenEstimatorV1(), matchingBudget: budget)
            let expected = c["expected"] as! [String: Any]
            XCTAssertEqual(result.section?.text, expected["text"] as? String, name)
            XCTAssertEqual(result.included, expected["included"] as? [String], name)
            XCTAssertEqual(result.omitted, expected["omitted"] as? [String], name)
        }
    }

    /// The coordinator swaps in hydrated evidence after the adapter set the inventory signal; the
    /// copy must keep it (the real-folder eval caught a field-by-field copy dropping it).
    func testReplacingEvidenceKeepsInventorySignal() throws {
        var input = try ContextPackFixtures.input("basic-cs")
        input.pathInventory = true
        input.evidenceBudgetCap = 77
        let replaced = input.replacingEvidence(candidates: [], neighbours: [], overviewCandidates: [], folderMap: [])
        XCTAssertEqual(replaced.pathInventory, true)
        XCTAssertEqual(replaced.evidenceBudgetCap, 77)
        XCTAssertTrue(replaced.candidates.isEmpty && replaced.folderMap.isEmpty)
        var expected = input
        expected.candidates = []; expected.neighbours = []; expected.overviewCandidates = []; expected.folderMap = []
        XCTAssertEqual(replaced, expected)
    }

    /// Whole packs: an inventory question keeps every project in the map even at 8 192 tokens.
    func testSharedV2PackCases() throws {
        let fixture = try SharedFixtures.json("contracts/retrieval-paths-v2.json")
        let cases = try XCTUnwrap(fixture["packCases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 4)
        for c in cases {
            let name = c["name"] as! String
            let input = try ContextPackFixtures.decode(c["input"]!, as: ContextPackInput.self)
            let request = try ContextPackBuilder.build(input, estimator: PlaceholderTokenEstimatorV1(), tuning: .v1)
            XCTAssertEqual(try PreparedContextRequestJSON.object(request), c["expected"] as! NSDictionary, name)
        }
    }
}

extension PathMatcherTests {
    /// retrieval-paths-v1 §5: the map lists the question's path matches first.
    func testSharedMapCases() throws {
        let fixture = try SharedFixtures.json("contracts/retrieval-paths-v1.json")
        let cases = try XCTUnwrap(fixture["mapCases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 5)
        let template = try ContextPackFixtures.input("basic-cs")
        let passage = template.candidates[0]
        for c in cases {
            let name = c["name"] as! String
            var input = template
            input.folderMap = try ContextPackFixtures.decode(c["folderMap"]!, as: [PackFile].self)
            let direct = (c["directSourceIds"] as! [NSNumber]).map { id -> PackPassage in
                var p = passage
                p.sourceId = id.int64Value
                return p
            }
            let result = try ContextPackRendering.map(input, ceiling: (c["ceiling"] as! NSNumber).intValue, direct: direct,
                                                      estimator: PlaceholderTokenEstimatorV1())
            let expected = c["expected"] as! [String: Any]
            XCTAssertEqual(result.section?.text, expected["text"] as? String, name)
            XCTAssertEqual(result.included, expected["included"] as? [String], name)
            XCTAssertEqual(result.omitted, expected["omitted"] as? [String], name)
        }
    }
}

@MainActor final class PathBranchRetrievalTests: XCTestCase {
    /// retrieval-paths-v1 §4: the best path-matching files' first chunks form a third RRF branch.
    func testPathBranchFusesFirstChunksOfMatchingFiles() async throws {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebookId = try XCTUnwrap(store.createNotebook(name: "paths").id)
        let files = [
            "ACME/2026/P-0001 Portal/Nabidky/20260617_Migrace.xlsx",
            "ACME/2026/P-0001 Portal/Objednavky/objednavka.pdf",
            "ACMER/2026/P-0004 Cloud/Nabidky/20260201_Cloud.pdf",
            "ACME/2026/P-0002 Helpdesk/Nabidky/RE_ potvrzeni.msg",
        ]
        let firstChunks: [Int64] = try store.runOnDatabase { db in
            try db.execute(sql: """
                INSERT INTO folder_sources(notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,created_at)
                VALUES (?,'/r','{}','Archive','[]','[]','{}','2026-10-11')
                """, arguments: [notebookId])
            let folder = db.lastInsertedRowID
            var heads: [Int64] = []
            for (index, path) in files.enumerated() {
                try db.execute(sql: """
                    INSERT INTO sources(notebook_id,type,title,status,ingested_at,folder_id,rel_path) VALUES (?,'text',?,'ready','2026-10-11 00:00:00.000',?,?)
                    """, arguments: [notebookId, String(path.split(separator: "/").last!), folder, path])
                let source = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES (?,1,?,'',1,2,'2026-10-11 00:00:00.000')
                    """, arguments: [source, "h\(index)"])
                let revision = db.lastInsertedRowID
                try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?", arguments: [revision, revision, source])
                for ord in 0..<2 {
                    try db.execute(sql: "INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id) VALUES (?,?,?,2,?)",
                                   arguments: [source, ord, "cell \(index) \(ord)", revision])
                    if ord == 0 { heads.append(db.lastInsertedRowID) }
                }
            }
            return heads
        }
        let retriever = Retriever(store: store, client: NoPathEmbedding(), modelKey: { "none" }, cache: VectorMatrixCache())
        let pool = try await retriever.search(notebookId: notebookId, query: "jaké nabídky jsme poslali v 2026 pro ACME?",
                                              scope: .all, fetchK: 8, includeVectors: false)
        // Files 1 and 4 match nabídky + 2026 + ACME; ACMER and the order folder do not reach the best tier.
        XCTAssertEqual(pool.pathMatches.map(\.sourceId).sorted(), [1, 4])
        XCTAssertEqual(Set(pool.path.map(\.reference.chunkId)), Set([firstChunks[0], firstChunks[3]]))
        XCTAssertTrue(pool.lexical.isEmpty)
        XCTAssertEqual(pool.fused.map(\.reference.chunkId), pool.path.map(\.reference.chunkId))
        await pool.close()
    }
}

private struct NoPathEmbedding: EmbeddingProducing {
    func embed(model: String, inputs: [String]) async throws -> [[Float]] { throw CancellationError() }
}

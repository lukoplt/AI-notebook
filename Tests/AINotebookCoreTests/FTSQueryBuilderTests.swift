import XCTest
import GRDB
@testable import AINotebookCore

final class FTSQueryBuilderTests: XCTestCase {
    private func run(_ fixture: String, count: Int, _ build: (FTSQueryBuilder, String) -> String?) throws {
        let builder = FTSQueryBuilder(tables: try UnicodeTables.bundled())
        let queue = try DatabaseQueue()
        let cases = try XCTUnwrap(SharedFixtures.json(fixture)["cases"] as? [[String: Any]])
        try queue.write { db in
            print("FTS provider=GRDB-system platform=macOS sqlite=\(try String.fetchOne(db, sql: "SELECT sqlite_version()")!)")
            try db.execute(sql: "CREATE VIRTUAL TABLE probe USING fts5(text, tokenize='unicode61 remove_diacritics 2')")
            for c in cases {
                let name = c["name"] as! String
                let expression = build(builder, c["query"] as! String)
                XCTAssertEqual(expression, c["expectedMatchExpr"] as? String, name)
                try db.execute(sql: "DELETE FROM probe")
                try db.execute(sql: "INSERT INTO probe(text) VALUES(?)", arguments: [c["documentText"] as! String])
                if let expression {
                    let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM probe WHERE probe MATCH ?", arguments: [expression])!
                    XCTAssertEqual(count == 1, c["shouldMatchDocument"] as? Bool, name)
                } else {
                    XCTAssertTrue(c["shouldMatchDocument"] is NSNull, name)
                }
            }
            XCTAssertEqual(cases.count, count)
        }
    }

    /// Frozen folder-rag-v1 §7 builder.
    func testSharedCasesOnSystemSQLite() throws {
        try run("contracts/fts-query-v1.json", count: 24) { $0.matchExpressionV1($1) }
    }

    /// fts-query-v2: stopwords, stem prefixes, exact acronyms.
    func testSharedV2CasesOnSystemSQLite() throws {
        try run("contracts/fts-query-v2.json", count: 24) { $0.matchExpression($1) }
    }

    func testV2ListsEqualFixture() throws {
        let fixture = try SharedFixtures.json("contracts/fts-query-v2.json")
        XCTAssertEqual(fixture["stopwords"] as? [String: [String]], FTSQueryBuilder.stopwords)
        XCTAssertEqual(fixture["suffixes"] as? [String], FTSQueryBuilder.suffixes)
        XCTAssertEqual((fixture["minStem"] as? NSNumber)?.intValue, FTSQueryBuilder.minStem)
        XCTAssertEqual((fixture["maxTokens"] as? NSNumber)?.intValue, RagContractV1.Retrieval.maxFtsTokens)
    }
}

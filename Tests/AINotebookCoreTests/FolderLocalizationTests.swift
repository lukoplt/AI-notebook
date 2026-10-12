import XCTest
@testable import AINotebookCore

final class FolderLocalizationTests: XCTestCase {
    func testFolderAndScopeCopy() {
        let en = AppText(language: .english), cs = AppText(language: .czech)
        XCTAssertEqual(en.string(.addFolderButton), "Add folder…")
        XCTAssertEqual(cs.string(.addFolderButton), "Přidat složku…")
        XCTAssertEqual(en.string(.scopeEmpty), "No sources selected")
        XCTAssertEqual(cs.string(.folderRefreshError), "Aktualizace selhala")
        XCTAssertEqual(en.string(.folderRemoveKeepsFiles), "Files on disk will be kept.")
    }

    func testAllSharedFolderStrings() throws {
        let f = try SharedFixtures.json("contracts/ingestion-ui-v1.json")
        let rows = (f["cases"] as! [[String: Any]]).filter { $0["operation"] as? String == "localization" }
        XCTAssertEqual(rows.count, 51)
        let keys = Dictionary(uniqueKeysWithValues: AppText.Key.allCases.map { (String(describing: $0), $0) })
        for row in rows {
            let i = row["input"] as! [String: Any], e = row["expected"] as! [String: String]
            let key = try XCTUnwrap(keys[i["key"] as! String])
            XCTAssertEqual(AppText(language: .english).string(key), e["en"])
            XCTAssertEqual(AppText(language: .czech).string(key), e["cs"])
        }
    }
}

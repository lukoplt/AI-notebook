import Foundation
import XCTest
@testable import AINotebookCore

/// Grouped-Sources copy in both languages, kept identical to the Windows resources.
final class FolderMembersLocalizationTests: XCTestCase {
    static let rows: [(AppText.Key, String, String)] = [
        (.folderShowFiles, "Show files", "Zobrazit soubory"),
        (.folderHideFiles, "Hide files", "Skrýt soubory"),
        (.folderFilesCount, "Files: {shown} / {total}", "Soubory: {shown} / {total}"),
        (.folderLoadMoreFiles, "Load more files", "Načíst další soubory"),
        (.folderNoFiles, "No files from this folder yet", "Ze složky zatím nejsou žádné soubory"),
        (.sourceLanguageLabel, "Language", "Jazyk"),
        (.sourceLanguageMixed, "Mixed", "Více jazyků"),
    ]

    func testCopyInBothLanguages() {
        for (key, english, czech) in Self.rows {
            XCTAssertEqual(AppText(language: .english).string(key), english)
            XCTAssertEqual(AppText(language: .czech).string(key), czech)
        }
        XCTAssertEqual(AppText(language: .english).folderFilesCount(shown: 200, total: 5000), "Files: 200 / 5000")
        XCTAssertEqual(AppText(language: .czech).folderFilesCount(shown: 0, total: 0), "Soubory: 0 / 0")
    }

    func testWindowsResourcesMatchAndPrecedeProviderBlock() throws {
        let repository = SharedFixtures.root.deletingLastPathComponent().deletingLastPathComponent()
        for (locale, language) in [("en-US", AppLanguage.english), ("cs-CZ", AppLanguage.czech)] {
            let resource = repository.appendingPathComponent("windows/src/AINotebook.App/Strings/\(locale)/Resources.resw")
            let entries = try XMLDocument(contentsOf: resource).nodes(forXPath: "/root/data").compactMap { $0 as? XMLElement }
            let names = entries.map { $0.attribute(forName: "name")?.stringValue ?? "" }
            let provider = try XCTUnwrap(names.firstIndex(of: "providerPresetLabel"))
            for (key, _, _) in Self.rows {
                let name = String(describing: key)
                let index = try XCTUnwrap(names.firstIndex(of: name), "\(locale): \(name)")
                XCTAssertLessThan(index, provider, "\(locale): \(name) must precede the WP2 provider block")
                XCTAssertEqual(entries[index].elements(forName: "value").first?.stringValue,
                               AppText(language: language).string(key), "\(locale): \(name)")
            }
        }
    }

    func testLanguageBadge() {
        let en = AppText(language: .english), cs = AppText(language: .czech)
        XCTAssertEqual(en.languageBadge("cs"), "CS")
        XCTAssertEqual(en.languageBadge("sk"), "SK")
        XCTAssertEqual(cs.languageBadge("en"), "EN")
        XCTAssertEqual(cs.languageBadge("de"), "DE")
        XCTAssertEqual(en.languageBadge("mixed"), "Mixed")
        XCTAssertEqual(cs.languageBadge("mixed"), "Více jazyků")
        XCTAssertNil(en.languageBadge("und"))
        XCTAssertNil(en.languageBadge(nil))
        XCTAssertNil(en.languageBadge("fr"))
    }
}

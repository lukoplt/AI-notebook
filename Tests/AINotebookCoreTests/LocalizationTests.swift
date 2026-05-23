import XCTest
@testable import AINotebookCore

final class LocalizationTests: XCTestCase {
    func testEveryKeyHasEnglishString() {
        let text = AppText(language: .english)
        for key in AppText.Key.allCases {
            let value = text.string(key)
            XCTAssertFalse(value.isEmpty, "English string missing for \(key)")
        }
    }

    func testEveryKeyHasCzechString() {
        let text = AppText(language: .czech)
        for key in AppText.Key.allCases {
            let value = text.string(key)
            XCTAssertFalse(value.isEmpty, "Czech string missing for \(key)")
        }
    }

    func testEnglishAndCzechDiffer() {
        let en = AppText(language: .english)
        let cs = AppText(language: .czech)
        // At least one key must actually differ — guards against accidentally
        // leaving Czech as a copy of English.
        let differs = AppText.Key.allCases.contains { key in
            en.string(key) != cs.string(key)
        }
        XCTAssertTrue(differs, "Czech strings appear identical to English")
    }

    func testKnownStringsExact() {
        let en = AppText(language: .english)
        XCTAssertEqual(en.string(.settings), "Settings")
        XCTAssertEqual(en.string(.notebooks), "Notebooks")

        let cs = AppText(language: .czech)
        XCTAssertEqual(cs.string(.settings), "Nastavení")
        XCTAssertEqual(cs.string(.notebooks), "Poznámkové bloky")
    }
}

import XCTest
@testable import AINotebookCore

final class AppLanguageTests: XCTestCase {
    func testAllCases() {
        XCTAssertEqual(AppLanguage.allCases, [.english, .czech])
    }

    func testRawValues() {
        XCTAssertEqual(AppLanguage.english.rawValue, "en")
        XCTAssertEqual(AppLanguage.czech.rawValue, "cs")
    }

    func testDisplayNames() {
        XCTAssertEqual(AppLanguage.english.displayName, "English")
        XCTAssertEqual(AppLanguage.czech.displayName, "Čeština")
    }
}

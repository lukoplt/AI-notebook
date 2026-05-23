import XCTest
@testable import AINotebookCore

final class LocaleDetectionTests: XCTestCase {
    func testCzechPreferredReturnsCzech() {
        let result = detectInitialLanguage(preferredLanguages: ["cs-CZ", "en-US"])
        XCTAssertEqual(result, .czech)
    }

    func testCzechWithoutRegionReturnsCzech() {
        let result = detectInitialLanguage(preferredLanguages: ["cs"])
        XCTAssertEqual(result, .czech)
    }

    func testEnglishPreferredReturnsEnglish() {
        let result = detectInitialLanguage(preferredLanguages: ["en-US"])
        XCTAssertEqual(result, .english)
    }

    func testUnknownLanguageDefaultsToEnglish() {
        let result = detectInitialLanguage(preferredLanguages: ["ja-JP", "ko-KR"])
        XCTAssertEqual(result, .english)
    }

    func testEmptyDefaultsToEnglish() {
        let result = detectInitialLanguage(preferredLanguages: [])
        XCTAssertEqual(result, .english)
    }

    func testCzechSecondInListStillCountsAsCzech() {
        // Czech anywhere in preferred list wins because the user explicitly
        // chose it; default English is only when no Czech preference exists.
        let result = detectInitialLanguage(preferredLanguages: ["en-US", "cs-CZ"])
        XCTAssertEqual(result, .czech)
    }
}

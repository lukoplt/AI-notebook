import XCTest
@testable import AINotebookCore

@MainActor
final class AppSettingsTests: XCTestCase {
    private func makeSuite(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testInitialLanguageFallsBackToDetection() {
        let defaults = makeSuite("test.initial.\(UUID().uuidString)")
        let settings = AppSettings(
            defaults: defaults,
            preferredLanguages: ["cs-CZ"]
        )
        XCTAssertEqual(settings.language, .czech)
    }

    func testInitialLanguageRespectsPersistedChoice() {
        let suite = "test.persisted.\(UUID().uuidString)"
        let defaults = makeSuite(suite)
        defaults.set("en", forKey: "language")

        let settings = AppSettings(
            defaults: defaults,
            preferredLanguages: ["cs-CZ"]   // would otherwise pick Czech
        )
        XCTAssertEqual(settings.language, .english)
    }

    func testSettingLanguagePersists() {
        let suite = "test.persist-write.\(UUID().uuidString)"
        let defaults = makeSuite(suite)
        let settings = AppSettings(
            defaults: defaults,
            preferredLanguages: ["en-US"]
        )
        XCTAssertEqual(settings.language, .english)

        settings.language = .czech
        XCTAssertEqual(defaults.string(forKey: "language"), "cs")
    }

    func testInvalidPersistedValueFallsBackToDetection() {
        let suite = "test.invalid.\(UUID().uuidString)"
        let defaults = makeSuite(suite)
        defaults.set("xx", forKey: "language")

        let settings = AppSettings(
            defaults: defaults,
            preferredLanguages: ["cs-CZ"]
        )
        XCTAssertEqual(settings.language, .czech)
    }
}

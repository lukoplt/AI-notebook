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

    func testHasCompletedOnboardingDefaultsFalse() {
        let defaults = makeSuite("test.onb.\(UUID().uuidString)")
        let settings = AppSettings(
            defaults: defaults,
            preferredLanguages: ["en-US"]
        )
        XCTAssertFalse(settings.hasCompletedOnboarding)
    }

    func testHasCompletedOnboardingPersists() {
        let suite = "test.onb-persist.\(UUID().uuidString)"
        let defaults = makeSuite(suite)
        let settings = AppSettings(
            defaults: defaults,
            preferredLanguages: ["en-US"]
        )
        settings.hasCompletedOnboarding = true
        XCTAssertEqual(defaults.bool(forKey: "hasCompletedOnboarding"), true)
    }

    func testSelectedModelsDefaults() {
        let defaults = makeSuite("test.models.\(UUID().uuidString)")
        let settings = AppSettings(
            defaults: defaults,
            preferredLanguages: ["en-US"]
        )
        XCTAssertEqual(settings.selectedChatModel, "llama3.2:3b")
        XCTAssertEqual(settings.selectedEmbeddingModel, "nomic-embed-text")
    }

    func testSelectedModelsPersist() {
        let defaults = makeSuite("test.models-w.\(UUID().uuidString)")
        let settings = AppSettings(
            defaults: defaults,
            preferredLanguages: ["en-US"]
        )
        settings.selectedChatModel = "llama3.1:8b"
        settings.selectedEmbeddingModel = "mxbai-embed-large"
        XCTAssertEqual(defaults.string(forKey: "selectedChatModel"), "llama3.1:8b")
        XCTAssertEqual(defaults.string(forKey: "selectedEmbeddingModel"), "mxbai-embed-large")
    }
}

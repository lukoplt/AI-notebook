import XCTest
@testable import AINotebookCore

@MainActor
final class AppSettingsTests: XCTestCase {
    private func makeSuite(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testInitialLanguageDefaultsToEnglish() {
        // No stored choice → English, regardless of OS locale.
        let defaults = makeSuite("test.initial.\(UUID().uuidString)")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.language, .english)
    }

    func testInitialLanguageRespectsPersistedChoice() {
        // A persisted Czech choice overrides the English default.
        let suite = "test.persisted.\(UUID().uuidString)"
        let defaults = makeSuite(suite)
        defaults.set("cs", forKey: "language")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.language, .czech)
    }

    func testSettingLanguagePersists() {
        let suite = "test.persist-write.\(UUID().uuidString)"
        let defaults = makeSuite(suite)
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.language, .english)

        settings.language = .czech
        XCTAssertEqual(defaults.string(forKey: "language"), "cs")
    }

    func testInvalidPersistedValueFallsBackToEnglish() {
        let suite = "test.invalid.\(UUID().uuidString)"
        let defaults = makeSuite(suite)
        defaults.set("xx", forKey: "language")

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.language, .english)
    }

    func testHasCompletedOnboardingDefaultsFalse() {
        let defaults = makeSuite("test.onb.\(UUID().uuidString)")
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.hasCompletedOnboarding)
    }

    func testHasCompletedOnboardingPersists() {
        let suite = "test.onb-persist.\(UUID().uuidString)"
        let defaults = makeSuite(suite)
        let settings = AppSettings(defaults: defaults)
        settings.hasCompletedOnboarding = true
        XCTAssertEqual(defaults.bool(forKey: "hasCompletedOnboarding"), true)
    }

    func testSelectedModelsDefaults() {
        let defaults = makeSuite("test.models.\(UUID().uuidString)")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.selectedChatModel, "llama3.2:3b")
        XCTAssertEqual(settings.selectedEmbeddingModel, "nomic-embed-text")
    }

    func testSelectedModelsPersist() {
        let defaults = makeSuite("test.models-w.\(UUID().uuidString)")
        let settings = AppSettings(defaults: defaults)
        settings.selectedChatModel = "llama3.1:8b"
        settings.selectedEmbeddingModel = "mxbai-embed-large"
        XCTAssertEqual(defaults.string(forKey: "selectedChatModel"), "llama3.1:8b")
        XCTAssertEqual(defaults.string(forKey: "selectedEmbeddingModel"), "mxbai-embed-large")
    }

    func testProviderSelectionDefaultsToBuiltInOllama() {
        let defaults = makeSuite("test.providers.\(UUID().uuidString)")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.selectedChatProviderId, ProviderConfig.ollamaId)
        XCTAssertEqual(settings.selectedEmbeddingProviderId, ProviderConfig.ollamaId)
    }

    func testProviderSelectionPersistsThroughSharedKeys() {
        let name = "test.providers.persist.\(UUID().uuidString)"
        let defaults = makeSuite(name)
        let settings = AppSettings(defaults: defaults)
        settings.selectedChatProviderId = "prov-1"
        settings.selectedChatModel = "gpt-4o"
        // The router-side reader must observe the same values immediately.
        let selection = DefaultsProviderSelection(defaults: defaults)
        XCTAssertEqual(selection.chatSelection().providerId, "prov-1")
        XCTAssertEqual(selection.chatSelection().model, "gpt-4o")
        // And a fresh AppSettings re-reads them.
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.selectedChatProviderId, "prov-1")
    }

    func testAutoCheckUpdatesDefaultsOnAndPersists() {
        let name = "test.updates.\(UUID().uuidString)"
        let defaults = makeSuite(name)
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.autoCheckUpdates)
        settings.autoCheckUpdates = false
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.autoCheckUpdates)
    }

    func testLastUpdateCheckDefaultsNilAndPersists() {
        let name = "test.updates.last.\(UUID().uuidString)"
        let defaults = makeSuite(name)
        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.lastUpdateCheck)
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        settings.lastUpdateCheck = stamp
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.lastUpdateCheck?.timeIntervalSince1970 ?? 0,
                       stamp.timeIntervalSince1970, accuracy: 0.001)
    }
}

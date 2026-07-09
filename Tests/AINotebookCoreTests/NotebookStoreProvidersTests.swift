import XCTest
@testable import AINotebookCore

@MainActor
final class NotebookStoreProvidersTests: XCTestCase {

    private func makeStore() throws -> NotebookStore {
        try NotebookStore(path: .inMemory)
    }

    func testSaveAndFetchRoundTrips() throws {
        let store = try makeStore()
        let cfg = ProviderConfig(
            type: .openwebui, name: "LAN server", baseURL: "http://192.168.1.50:3000"
        )
        try store.saveProvider(cfg)
        let loaded = try XCTUnwrap(try store.provider(id: cfg.id))
        XCTAssertEqual(loaded.type, .openwebui)
        XCTAssertEqual(loaded.name, "LAN server")
        XCTAssertEqual(loaded.baseURL, "http://192.168.1.50:3000")
        XCTAssertTrue(loaded.enabled)
        XCTAssertFalse(loaded.privacyAcknowledged)
    }

    func testProvidersListsSeedPlusSavedOrderedByCreation() throws {
        let store = try makeStore()
        let cfg = ProviderConfig(type: .anthropic, name: "Claude", baseURL: "https://api.anthropic.com")
        try store.saveProvider(cfg)
        let all = try store.providers()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.id, ProviderConfig.ollamaId)
        XCTAssertEqual(all.last?.id, cfg.id)
    }

    func testUpdatePreservesPrivacyAcknowledgement() throws {
        let store = try makeStore()
        var cfg = ProviderConfig(type: .openai, name: "OpenAI", baseURL: "https://api.openai.com")
        try store.saveProvider(cfg)
        try store.acknowledgePrivacy(providerId: cfg.id)
        cfg.name = "OpenAI renamed"
        try store.saveProvider(cfg)   // cfg still carries privacyAcknowledged == false
        let loaded = try XCTUnwrap(try store.provider(id: cfg.id))
        XCTAssertEqual(loaded.name, "OpenAI renamed")
        XCTAssertTrue(loaded.privacyAcknowledged, "edit must not reset the consent flag")
    }

    func testDeleteRefusesBuiltInOllama() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.deleteProvider(id: ProviderConfig.ollamaId))
        XCTAssertNotNil(try store.provider(id: ProviderConfig.ollamaId))
    }

    func testDeleteRemovesRow() throws {
        let store = try makeStore()
        let cfg = ProviderConfig(type: .openwebui, name: "X", baseURL: "http://h:3000")
        try store.saveProvider(cfg)
        try store.deleteProvider(id: cfg.id)
        XCTAssertNil(try store.provider(id: cfg.id))
    }

    func testUnknownTypeStringLoadsAsOpenAICompatible() throws {
        let store = try makeStore()
        try store.runOnDatabase { db in
            try db.execute(
                sql: """
                INSERT INTO providers(id, type, name, base_url, enabled, privacy_acknowledged, created_at)
                VALUES ('future-id', 'grok', 'Future', 'https://x', 1, 0, datetime('now'))
                """
            )
        }
        let loaded = try XCTUnwrap(try store.provider(id: "future-id"))
        XCTAssertEqual(loaded.type, .openaiCompatible)
    }
}

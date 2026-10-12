import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

@MainActor
final class ProviderRootUpgradeTests: XCTestCase {
    func testChatOnlyEmbeddingSelectionConvertsOnceAndNoticeSurvivesRestart() throws {
        let rows = try SharedFixtures.json("contracts/provider-routing-v1.json")["cases"] as! [[String: Any]]
        for row in rows where (row["name"] as! String).hasPrefix("unsupported-embed-") {
            let suite = UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = try NotebookStore(path: .inMemory)
            let type = ProviderType(rawValue: row["type"] as! String)!
            try store.saveProvider(.init(id: "chat-only", type: type, name: "P", baseURL: type.defaultBaseURL))
            defaults.set("chat-only", forKey: ProviderSettingsKeys.embeddingProviderId)
            defaults.set("vendor/model:tag", forKey: ProviderSettingsKeys.embeddingModel)
            let settings = AppSettings(defaults: defaults)

            try settings.convertLegacyProviderSelection(store: store)

            XCTAssertEqual(settings.selectedEmbeddingProviderId, ProviderConfig.ollamaId)
            XCTAssertEqual(settings.selectedEmbeddingModel, "nomic-embed-text")
            XCTAssertTrue(settings.embeddingSelectionConversionNoticePending)
            XCTAssertEqual(DefaultsProviderSelection(defaults: defaults).embeddingKey(), ProviderConfig.ollamaId + ":nomic-embed-text")
            let reopened = AppSettings(defaults: defaults)
            XCTAssertTrue(reopened.embeddingSelectionConversionNoticePending)
            reopened.dismissEmbeddingSelectionConversionNotice()
            reopened.selectedEmbeddingProviderId = "chat-only"
            reopened.selectedEmbeddingModel = "intentional-new-choice"
            try reopened.convertLegacyProviderSelection(store: store)
            XCTAssertEqual(reopened.selectedEmbeddingProviderId, "chat-only")
            XCTAssertEqual(reopened.selectedEmbeddingModel, "intentional-new-choice")
            XCTAssertFalse(AppSettings(defaults: defaults).embeddingSelectionConversionNoticePending)
        }
    }

    func testEmbeddingConversionPreservesCapableAndMissingProviderSelections() throws {
        for type in [ProviderType.ollama, .openai, .openaiCompatible, nil] {
            let suite = UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = try NotebookStore(path: .inMemory)
            if let type {
                try store.saveProvider(.init(id: "p", type: type, name: "P", baseURL: type.defaultBaseURL))
            }
            let settings = AppSettings(defaults: defaults)
            settings.selectedEmbeddingProviderId = "p"
            settings.selectedEmbeddingModel = "vendor/model:tag"
            try settings.convertLegacyProviderSelection(store: store)
            XCTAssertEqual(settings.selectedEmbeddingProviderId, "p")
            XCTAssertEqual(settings.selectedEmbeddingModel, "vendor/model:tag")
            XCTAssertFalse(settings.embeddingSelectionConversionNoticePending)
        }
    }

    func testLegacyRootsConvertOnceWithoutChangingProviderIdentity() throws {
        let rows = try SharedFixtures.json("contracts/provider-store-v1.json")["cases"] as! [[String: Any]]
        let legacy = rows.filter { ($0["name"] as! String).hasPrefix("legacy-") }
        let newRoot = try XCTUnwrap(rows.first { $0["name"] as? String == "new-versionless" })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = StorePath(fileURL: directory.appendingPathComponent("upgrade.sqlite"))
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let invalidRoot = "http://user:secret@host/v1"
        var originals: [ProviderConfig] = legacy.enumerated().map { offset, row in
            ProviderConfig(id: row["name"] as! String, type: ProviderType(rawValue: row["type"] as! String)!,
                name: "Provider \(offset)", baseURL: row["before"] as! String,
                enabled: offset % 2 == 0, privacyAcknowledged: offset % 2 != 0, createdAt: createdAt)
        }
        originals.append(.init(id: "invalid", type: .openai, name: "Invalid", baseURL: invalidRoot,
            enabled: false, privacyAcknowledged: true, createdAt: createdAt))
        do {
            let queue = try DatabaseQueue(path: path.fileURL!.path)
            defer { try? queue.close() }
            var migrator = DatabaseMigrator()
            registerMigrationV1(on: &migrator)
            registerMigrationV2(on: &migrator)
            registerMigrationV3(on: &migrator)
            registerMigrationV4(on: &migrator)
            registerMigrationV5(on: &migrator)
            registerMigrationV6(on: &migrator)
            registerMigrationV7(on: &migrator)
            registerMigrationV8(on: &migrator)
            registerMigrationV9(on: &migrator)
            registerMigrationV10(on: &migrator)
            registerMigrationV11(on: &migrator)
            registerMigrationV12(on: &migrator)
            registerMigrationV13(on: &migrator)
            registerMigrationV14(on: &migrator)
            registerMigrationV15(on: &migrator)
            registerMigrationV18(on: &migrator)
            try migrator.migrate(queue)
            try queue.write { db in
                for config in originals {
                    try db.execute(sql: """
                        INSERT INTO providers(id,type,name,base_url,enabled,privacy_acknowledged,created_at)
                        VALUES(?,?,?,?,?,?,?)
                        """, arguments: [config.id, config.type.rawValue, config.name, config.baseURL,
                                           config.enabled, config.privacyAcknowledged, config.createdAt])
                }
            }
        }
        for reopen in 0..<2 {
            let store = try NotebookStore(path: path, configuredEmbeddingModelKey: nil)
            defer { try? store.dbQueue.close() }
            for original in originals {
                var expected = original
                if let row = legacy.first(where: { $0["name"] as? String == original.id }) {
                    expected.baseURL = row["after"] as! String
                }
                XCTAssertEqual(try store.provider(id: original.id), expected, "\(original.id), reopen \(reopen)")
            }
            if reopen == 0 {
                try store.saveProvider(.init(id: "new-versionless", type: .openaiCompatible, name: "New",
                                            baseURL: newRoot["before"] as! String))
            } else {
                XCTAssertEqual(try store.provider(id: "new-versionless")?.baseURL, newRoot["after"] as? String)
            }
        }
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        XCTAssertThrowsError(try ProviderAPIRoot.build(type: .openai, baseURL: invalidRoot, endpoint: .chat)) {
            XCTAssertEqual($0 as? ProviderConfigurationError, .invalidBaseURL)
        }
        XCTAssertTrue(StubURLProtocol.allRequests.isEmpty)
    }
}

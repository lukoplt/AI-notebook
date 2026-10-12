import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

@MainActor
final class ProviderModelLimitsStoreTests: XCTestCase {
    func testFixtureProviderEndpointEditsInvalidateOnlyTheirAutomaticLimits() throws {
        let rows = try XCTUnwrap(SharedFixtures.json("contracts/provider-store-v1.json")["cases"] as? [[String: Any]])
            .filter { $0["operation"] as? String == "providerUpdate" }
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let name = try XCTUnwrap(row["name"] as? String)
            let id = try XCTUnwrap(row["providerId"] as? String)
            let otherId = try XCTUnwrap(row["otherProviderId"] as? String)
            let model = try XCTUnwrap(row["model"] as? String)
            let before = try XCTUnwrap(row["before"] as? [String: String])
            let after = try XCTUnwrap(row["after"] as? [String: String])
            let store = try NotebookStore(path: .inMemory)
            var provider = ProviderConfig(id: id, type: try XCTUnwrap(ProviderType(rawValue: XCTUnwrap(before["type"]))),
                name: "Original", baseURL: try XCTUnwrap(before["baseURL"]), privacyAcknowledged: true,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            try store.saveProvider(provider)
            try store.saveProvider(.init(id: otherId, type: provider.type, name: "Other", baseURL: provider.baseURL))
            func limits(_ providerId: String, _ model: String, source: String = "auto") throws -> ProviderModelLimits {
                .init(providerId: providerId, model: model, contextWindow: row["contextWindow"] as? Int,
                    runtimeContext: try XCTUnwrap(row["runtimeContext"] as? Int),
                    maxOutputTokens: try XCTUnwrap(row["maxOutputTokens"] as? Int), source: source)
            }
            let automatic = try limits(id, model)
            let otherModel = try limits(id, model + ":other")
            let otherProvider = try limits(otherId, model)
            let user = try limits(id, model + ":user", source: "user")
            for value in [automatic, otherModel, otherProvider, user] { try store.saveProviderModelLimits(value) }

            provider.type = try XCTUnwrap(ProviderType(rawValue: XCTUnwrap(after["type"])))
            provider.baseURL = try XCTUnwrap(after["baseURL"])
            provider.name = "Renamed"
            provider.enabled = false
            try store.saveProvider(provider)

            let retained = try XCTUnwrap(row["expectedAutoRetained"] as? Bool)
            XCTAssertEqual(try store.providerModelLimits(providerId: id, model: model), retained ? automatic : nil, name)
            XCTAssertEqual(try store.providerModelLimits(providerId: id, model: otherModel.model), retained ? otherModel : nil, name)
            XCTAssertEqual(try store.providerModelLimits(providerId: id, model: user.model), user, name)
            XCTAssertEqual(try store.providerModelLimits(providerId: otherId, model: model), otherProvider, name)
            XCTAssertEqual(try store.provider(id: id), provider, name)
            if !retained {
                try store.saveProviderModelLimits(ProviderLimitPolicy.automatic(providerId: id, type: provider.type,
                    model: model, contextWindow: row["refreshedWindow"] as? Int))
                XCTAssertEqual(try store.providerModelLimits(providerId: id, model: model)?.runtimeContext,
                    row["expectedRefreshedRuntime"] as? Int, name)
            }
        }
    }

    func testUserOverrideSurvivesAutoRefresh() throws {
        let row = try fixture("user-survives-auto")
        let user = try userLimits(row)
        let store = try makeStore(providerIds: [user.providerId])
        try store.saveProviderModelLimits(user)
        let automatic = try ProviderLimitPolicy.automatic(
            providerId: user.providerId, type: .ollama, model: user.model,
            contextWindow: user.contextWindow)
        XCTAssertEqual(automatic.runtimeContext, row["autoRuntime"] as? Int)

        try store.saveProviderModelLimits(automatic)

        let loaded = try XCTUnwrap(store.providerModelLimits(providerId: user.providerId, model: user.model))
        XCTAssertEqual(loaded, user)
        XCTAssertEqual(loaded.runtimeContext, row["expectedRuntime"] as? Int)
    }

    func testProvidersAndExactRawModelsRemainIndependent() throws {
        let row = try fixture("provider-isolation")
        let ids = try XCTUnwrap(row["providerIds"] as? [String])
        let runtimes = try XCTUnwrap(row["runtimes"] as? [Int])
        let model = try XCTUnwrap(row["model"] as? String)
        let store = try makeStore(providerIds: ids)
        var expected: [ProviderModelLimits] = []
        for (id, runtime) in zip(ids, runtimes) {
            let limits = ProviderModelLimits(providerId: id, model: model, contextWindow: nil,
                                             runtimeContext: runtime, maxOutputTokens: 333, source: "user")
            try store.saveProviderModelLimits(limits)
            expected.append(limits)
        }
        let firstId = try XCTUnwrap(ids.first)
        let distinct = ProviderModelLimits(providerId: firstId, model: "org/" + model.uppercased(),
                                            contextWindow: 32768, runtimeContext: 2048,
                                            maxOutputTokens: 111, source: "user")
        try store.saveProviderModelLimits(distinct)
        expected.append(distinct)

        for limits in expected {
            XCTAssertEqual(try store.providerModelLimits(providerId: limits.providerId, model: limits.model), limits)
        }
        XCTAssertNil(try store.providerModelLimits(providerId: firstId, model: model.uppercased()))
        try store.deleteProviderModelLimits(providerId: firstId, model: model)
        XCTAssertNil(try store.providerModelLimits(providerId: firstId, model: model))
        for limits in expected.dropFirst() {
            XCTAssertEqual(try store.providerModelLimits(providerId: limits.providerId, model: limits.model), limits)
        }
        // Deleting an absent pair is an idempotent reset, never a provider-wide delete.
        try store.deleteProviderModelLimits(providerId: firstId, model: model)
        XCTAssertEqual(try rowCount(store), expected.count - 1)
    }

    func testResetRestoresAutomaticLimits() throws {
        let row = try fixture("reset-auto")
        let providerId = try XCTUnwrap(row["providerId"] as? String)
        let model = try XCTUnwrap(row["model"] as? String)
        let user = try userLimits(fixture("user-survives-auto"), providerId: providerId, model: model)
        let store = try makeStore(providerIds: [providerId])
        try store.saveProviderModelLimits(user)
        try store.deleteProviderModelLimits(providerId: providerId, model: model)
        XCTAssertNil(try store.providerModelLimits(providerId: providerId, model: model))

        let automatic = try ProviderLimitPolicy.automatic(providerId: providerId, type: .ollama,
                                                          model: model, contextWindow: nil)
        try store.saveProviderModelLimits(automatic)

        let loaded = try XCTUnwrap(store.providerModelLimits(providerId: providerId, model: model))
        XCTAssertEqual(loaded, automatic)
        XCTAssertEqual(loaded.source, row["expectedSource"] as? String)
        XCTAssertEqual(loaded.runtimeContext, row["expectedRuntime"] as? Int)
        XCTAssertNil(loaded.contextWindow)
    }

    func testDeletingProviderCascadesOnlyItsLimits() throws {
        let row = try fixture("delete-cascades")
        let providerId = try XCTUnwrap(row["providerId"] as? String)
        let model = try XCTUnwrap(row["model"] as? String)
        let isolation = try fixture("provider-isolation")
        let ids = try XCTUnwrap(isolation["providerIds"] as? [String])
        let otherId = try XCTUnwrap(ids.first { $0 != providerId })
        let store = try makeStore(providerIds: [providerId, otherId])
        for id in [providerId, otherId] {
            for rawModel in [model, model + ":tag"] {
                try store.saveProviderModelLimits(ProviderLimitPolicy.automatic(
                    providerId: id, type: .ollama, model: rawModel, contextWindow: nil))
            }
        }

        try store.deleteProvider(id: providerId)

        XCTAssertNil(try store.providerModelLimits(providerId: providerId, model: model))
        XCTAssertNil(try store.providerModelLimits(providerId: providerId, model: model + ":tag"))
        try store.runOnDatabase { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM provider_model_limits WHERE provider_id=?",
                                            arguments: [providerId]), row["expectedRows"] as? Int)
        }
        XCTAssertNotNil(try store.providerModelLimits(providerId: otherId, model: model))
        XCTAssertNotNil(try store.providerModelLimits(providerId: otherId, model: model + ":tag"))
        XCTAssertEqual(try rowCount(store), 2)
    }

    func testNullableContextAndEveryPersistedFieldRoundTrip() throws {
        let row = try fixture("unknown", file: "provider-limits-v1.json")
        let expected = try XCTUnwrap(row["expected"] as? [String: Any])
        let model = try XCTUnwrap(row["model"] as? String)
        let store = try makeStore(providerIds: ["p"])
        let automatic = try ProviderLimitPolicy.automatic(providerId: "p", type: .openaiCompatible,
                                                          model: model, contextWindow: nil)
        try store.saveProviderModelLimits(automatic)
        let loaded = try XCTUnwrap(store.providerModelLimits(providerId: "p", model: model))
        XCTAssertEqual(loaded.providerId, "p")
        XCTAssertEqual(loaded.model, model)
        XCTAssertNil(loaded.contextWindow)
        XCTAssertEqual(loaded.runtimeContext, expected["runtimeContext"] as? Int)
        XCTAssertEqual(loaded.maxOutputTokens, expected["maxOutputTokens"] as? Int)
        XCTAssertEqual(loaded.source, expected["source"] as? String)
        try store.runOnDatabase { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT context_window IS NULL FROM provider_model_limits"), 1)
        }

        let user = try userLimits(fixture("user-survives-auto"), model: model)
        try store.saveProviderModelLimits(user)
        XCTAssertEqual(try store.providerModelLimits(providerId: "p", model: model), user)
        XCTAssertEqual(try rowCount(store), 1)
    }

    func testInvalidTypedWritesDoNotReplaceExistingLimits() throws {
        let user = try userLimits(fixture("user-survives-auto"))
        let store = try makeStore(providerIds: [user.providerId])
        try store.saveProviderModelLimits(user)
        var invalid = try invalidFixtureLimits(providerId: user.providerId, model: user.model)
        invalid += [
            ProviderModelLimits(providerId: "", model: user.model, contextWindow: nil,
                                runtimeContext: 8192, maxOutputTokens: 1024, source: "user"),
            ProviderModelLimits(providerId: user.providerId, model: " \n\t ", contextWindow: nil,
                                runtimeContext: 8192, maxOutputTokens: 1024, source: "user"),
            ProviderModelLimits(providerId: user.providerId, model: user.model, contextWindow: nil,
                                runtimeContext: 8192, maxOutputTokens: 1024, source: "invalid")
        ]
        for limits in invalid {
            XCTAssertThrowsError(try store.saveProviderModelLimits(limits)) {
                XCTAssertEqual($0 as? ProviderConfigurationError, .invalidLimits)
            }
            XCTAssertEqual(try store.providerModelLimits(providerId: user.providerId, model: user.model), user)
            XCTAssertEqual(try rowCount(store), 1)
        }
    }

    func testDatabaseEnforcesLimitConstraints() throws {
        let store = try makeStore(providerIds: ["p"])
        var invalid = try invalidFixtureLimits(providerId: "p", model: "m")
        invalid += [
            ProviderModelLimits(providerId: "p", model: "", contextWindow: nil,
                                runtimeContext: 8192, maxOutputTokens: 1024, source: "auto"),
            ProviderModelLimits(providerId: "p", model: "   ", contextWindow: nil,
                                runtimeContext: 8192, maxOutputTokens: 1024, source: "auto"),
            ProviderModelLimits(providerId: "p", model: "m", contextWindow: 0,
                                runtimeContext: 8192, maxOutputTokens: 1024, source: "auto"),
            ProviderModelLimits(providerId: "p", model: "m", contextWindow: nil,
                                runtimeContext: 8192, maxOutputTokens: 8193, source: "auto"),
            ProviderModelLimits(providerId: "p", model: "m", contextWindow: nil,
                                runtimeContext: 8192, maxOutputTokens: 1024, source: "invalid")
        ]
        for limits in invalid {
            XCTAssertThrowsError(try store.runOnDatabase { db in try insertRaw(limits, into: db) }) {
                XCTAssertEqual(($0 as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
            }
        }
        XCTAssertEqual(try rowCount(store), 0)
    }

    func testMissingProviderIsRejectedByForeignKey() throws {
        let user = try userLimits(fixture("user-survives-auto"))
        let store = try NotebookStore(path: .inMemory)
        XCTAssertNil(try store.provider(id: user.providerId))

        XCTAssertThrowsError(try store.saveProviderModelLimits(user)) {
            XCTAssertEqual(($0 as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
        }

        XCTAssertEqual(try rowCount(store), 0)
        XCTAssertNil(try store.providerModelLimits(providerId: user.providerId, model: user.model))
    }

    func testDatabaseEnforcesRequiredFieldsAndCompositePrimaryKey() throws {
        let user = try userLimits(fixture("user-survives-auto"))
        let store = try makeStore(providerIds: [user.providerId])
        try store.saveProviderModelLimits(user)
        for column in ["provider_id", "model", "runtime_context", "max_output_tokens", "source"] {
            XCTAssertThrowsError(try store.runOnDatabase { db in
                try db.execute(sql: "UPDATE provider_model_limits SET \(column)=NULL")
            }) {
                XCTAssertEqual(($0 as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT, column)
            }
        }
        XCTAssertThrowsError(try store.runOnDatabase { db in try insertRaw(user, into: db) }) {
            XCTAssertEqual(($0 as? DatabaseError)?.resultCode, .SQLITE_CONSTRAINT)
        }
        XCTAssertEqual(try store.providerModelLimits(providerId: user.providerId, model: user.model), user)
        XCTAssertEqual(try rowCount(store), 1)
    }

    func testTypedReadsRejectInvalidPersistedLimits() throws {
        let store = try makeStore(providerIds: ["p"])
        let invalid = try XCTUnwrap(invalidFixtureLimits(providerId: "p", model: "m").first)
        try store.runOnDatabase { db in
            // Simulate corrupt/pre-validation data without weakening the production schema.
            try db.execute(sql: "PRAGMA ignore_check_constraints=ON")
            defer { try? db.execute(sql: "PRAGMA ignore_check_constraints=OFF") }
            try insertRaw(invalid, into: db)
        }

        XCTAssertThrowsError(try store.providerModelLimits(providerId: "p", model: "m")) {
            XCTAssertEqual($0 as? ProviderConfigurationError, .invalidLimits)
        }
    }

    func testLimitsAndDeletionPersistAcrossReopen() throws {
        let user = try userLimits(fixture("user-survives-auto"))
        let unknown = try fixture("unknown", file: "provider-limits-v1.json")
        let automatic = try ProviderLimitPolicy.automatic(providerId: user.providerId,
            type: .openaiCompatible, model: XCTUnwrap(unknown["model"] as? String), contextWindow: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = StorePath(fileURL: directory.appendingPathComponent("limits.sqlite"))
        do {
            let store = try makeStore(providerIds: [user.providerId], path: path)
            defer { try? store.dbQueue.close() }
            try store.saveProviderModelLimits(user)
            try store.saveProviderModelLimits(automatic)
        }
        do {
            let store = try NotebookStore(path: path)
            defer { try? store.dbQueue.close() }
            XCTAssertEqual(try store.providerModelLimits(providerId: user.providerId, model: user.model), user)
            XCTAssertEqual(try store.providerModelLimits(providerId: automatic.providerId, model: automatic.model), automatic)
            try store.deleteProviderModelLimits(providerId: user.providerId, model: user.model)
        }
        do {
            let store = try NotebookStore(path: path)
            defer { try? store.dbQueue.close() }
            XCTAssertNil(try store.providerModelLimits(providerId: user.providerId, model: user.model))
            XCTAssertEqual(try store.providerModelLimits(providerId: automatic.providerId, model: automatic.model), automatic)
            XCTAssertEqual(try rowCount(store), 1)
        }
    }

    private func fixture(_ name: String, file: String = "provider-store-v1.json") throws -> [String: Any] {
        let rows = try XCTUnwrap(SharedFixtures.json("contracts/" + file)["cases"] as? [[String: Any]])
        return try XCTUnwrap(rows.first { $0["name"] as? String == name }, "Missing fixture \(name)")
    }

    private func userLimits(_ row: [String: Any], providerId: String? = nil,
                            model: String? = nil) throws -> ProviderModelLimits {
        ProviderModelLimits(providerId: try providerId ?? XCTUnwrap(row["providerId"] as? String),
                            model: try model ?? XCTUnwrap(row["model"] as? String),
                            contextWindow: row["contextWindow"] as? Int,
                            runtimeContext: try XCTUnwrap(row["runtimeContext"] as? Int),
                            maxOutputTokens: try XCTUnwrap(row["maxOutputTokens"] as? Int),
                            source: try XCTUnwrap(row["source"] as? String))
    }

    private func invalidFixtureLimits(providerId: String, model: String) throws -> [ProviderModelLimits] {
        let rows = try XCTUnwrap(SharedFixtures.json("contracts/provider-limits-v1.json")["cases"] as? [[String: Any]])
        let invalid = rows.filter { $0["user"] != nil }
        XCTAssertFalse(invalid.isEmpty)
        return try invalid.map { row in
            let user = try XCTUnwrap(row["user"] as? [String: Int])
            XCTAssertEqual(row["expectedError"] as? String, "invalidLimits")
            return ProviderModelLimits(providerId: providerId, model: model, contextWindow: row["window"] as? Int,
                runtimeContext: try XCTUnwrap(user["runtimeContext"]),
                maxOutputTokens: try XCTUnwrap(user["maxOutputTokens"]), source: "user")
        }
    }

    private func makeStore(providerIds: [String], path: StorePath = .inMemory) throws -> NotebookStore {
        let store = try NotebookStore(path: path)
        for id in providerIds {
            try store.saveProvider(ProviderConfig(id: id, type: .ollama, name: id,
                                                  baseURL: ProviderType.ollama.defaultBaseURL))
        }
        return store
    }

    private func rowCount(_ store: NotebookStore) throws -> Int {
        try store.runOnDatabase { db in
            try XCTUnwrap(Int.fetchOne(db, sql: "SELECT count(*) FROM provider_model_limits"))
        }
    }

    private func insertRaw(_ limits: ProviderModelLimits, into db: Database) throws {
        try db.execute(sql: """
            INSERT INTO provider_model_limits(provider_id,model,context_window,runtime_context,max_output_tokens,source)
            VALUES(?,?,?,?,?,?)
            """, arguments: [limits.providerId, limits.model, limits.contextWindow,
                              limits.runtimeContext, limits.maxOutputTokens, limits.source])
    }
}

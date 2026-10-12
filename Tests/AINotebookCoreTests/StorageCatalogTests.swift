import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private struct CatalogIdentity: FolderPathIdentity {
    let values: [(String, FolderIdentity)]
    func resolve(rootPath: String) throws -> FolderIdentity {
        guard let value = values.first(where: { $0.0.utf8.elementsEqual(rootPath.utf8) })?.1 else {
            throw StorageV19Error.notFound
        }
        return value
    }
}

private final class RecordingCatalogIdentity: FolderPathIdentity, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private let adapter: CatalogIdentity

    init(_ values: [(String, FolderIdentity)]) { adapter = CatalogIdentity(values: values) }
    func resolve(rootPath: String) throws -> FolderIdentity {
        lock.lock()
        paths.append(rootPath)
        lock.unlock()
        return try adapter.resolve(rootPath: rootPath)
    }
    var resolvedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

@MainActor
final class StorageCatalogTests: XCTestCase {
    func testRootFileIdentityDistinguishesReplacementAndPersistsAcrossReopen() throws {
        let originalJSON = #"{"volumeId":"volume-1","components":["docs"],"rootFileId":"root-1"}"#
        let replacementJSON = #"{"volumeId":"volume-1","components":["docs"],"rootFileId":"root-2"}"#
        let decoder = JSONDecoder()
        let original = try decoder.decode(FolderIdentity.self, from: Data(originalJSON.utf8))
        let replacement = try decoder.decode(FolderIdentity.self, from: Data(replacementJSON.utf8))
        XCTAssertNotEqual(original, replacement)

        let copy = try V19TestStore.upgradeCopy(configuredKey: nil)
        var store = copy.0
        defer {
            try? store.dbQueue.close()
            try? FileManager.default.removeItem(at: copy.1)
        }
        let notebook = try XCTUnwrap(store.createNotebook(name: "root identity").id)
        let first = try store.createFolder(notebookId: notebook, draft: draft("/docs"),
                                           identity: CatalogIdentity(values: [("/docs", original)]), now: 0)
        try store.runOnDatabase { db in
            let json = try XCTUnwrap(String.fetchOne(db, sql: "SELECT path_identity FROM folder_sources WHERE id=?", arguments: [first.id]))
            let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(persisted["rootFileId"] as? String, "root-1")
        }
        try store.dbQueue.close()
        store = try V19TestStore.reopen(at: copy.1.appendingPathComponent("db.sqlite"), configuredKey: nil)
        let restored = try XCTUnwrap(store.folders(notebookId: notebook).first)
        XCTAssertEqual(restored.identity, original)
        XCTAssertNotEqual(restored.identity, replacement)

        // Object replacement does not make an already occupied root path available.
        assertError("overlappingRoot") {
            _ = try store.createFolder(notebookId: notebook, draft: draft("/docs-replacement"),
                                       identity: CatalogIdentity(values: [("/docs-replacement", replacement)]), now: 1)
        }

        // Filesystem identities are opaque bytes, including their root object IDs.
        let composed = try decoder.decode(FolderIdentity.self, from: Data(#"{"volumeId":"volume-1","components":["docs"],"rootFileId":"é"}"#.utf8))
        let decomposed = try decoder.decode(FolderIdentity.self, from: Data(#"{"volumeId":"volume-1","components":["docs"],"rootFileId":"e\u0301"}"#.utf8))
        XCTAssertNotEqual(composed, decomposed)
    }

    func testOverlapAndCapFixtures() throws {
        for c in try cases(operation: "overlap") {
            let reopens = c["reopen"] as? Bool == true
            let copy = reopens ? try V19TestStore.upgradeCopy(configuredKey: nil) : nil
            var store = try copy?.0 ?? V19TestStore.make()
            defer {
                try? store.dbQueue.close()
                if let directory = copy?.1 { try? FileManager.default.removeItem(at: directory) }
            }
            let notebook = try XCTUnwrap(store.createNotebook(name: "paths").id)
            let secondNotebook = c["secondNotebookId"] == nil ? notebook
                : try XCTUnwrap(store.createNotebook(name: "other").id)
            let first = try XCTUnwrap(c["firstPath"] as? String)
            let second = try XCTUnwrap(c["secondPath"] as? String)
            let volume = try XCTUnwrap(c["volume"] as? String)
            let adapter = CatalogIdentity(values: [
                (first, FolderIdentity(volumeId: volume, components: try XCTUnwrap(c["firstComponents"] as? [String]),
                                       rootFileId: try XCTUnwrap(c["firstRootFileId"] as? String))),
                (second, FolderIdentity(volumeId: c["secondVolume"] as? String ?? volume,
                                       components: try XCTUnwrap(c["secondComponents"] as? [String]),
                                       rootFileId: try XCTUnwrap(c["secondRootFileId"] as? String)))
            ])
            if c["name"] as? String == "opaque-unicode-identity" {
                XCTAssertNotEqual(try adapter.resolve(rootPath: first), try adapter.resolve(rootPath: second))
            }
            let firstFolder = try store.createFolder(notebookId: notebook, draft: draft(first), identity: adapter, now: 0)
            XCTAssertEqual(firstFolder.createdAt, 0)
            XCTAssertEqual(firstFolder.scanState, "idle")
            XCTAssertEqual(firstFolder.scanGeneration, 0)
            XCTAssertNil(firstFolder.lastFullScanAt)
            XCTAssertNil(firstFolder.lastScanError)
            var createAdapter: any FolderPathIdentity = adapter
            var recorded: RecordingCatalogIdentity?
            if reopens {
                try store.dbQueue.close()
                store = try V19TestStore.reopen(at: XCTUnwrap(copy?.1).appendingPathComponent("db.sqlite"), configuredKey: nil)
                let identities = try XCTUnwrap(c["afterReopenIdentities"] as? [[String: Any]])
                let recorder = RecordingCatalogIdentity(try identities.map {
                    (try XCTUnwrap($0["rootPath"] as? String), try folderIdentity($0))
                })
                createAdapter = recorder
                recorded = recorder
            }
            if let error = c["expectedError"] as? String {
                XCTAssertThrowsError(try store.createFolder(notebookId: secondNotebook, draft: draft(second), identity: createAdapter, now: 0)) {
                    XCTAssertEqual(($0 as? StorageV19Error)?.code, error)
                }
            } else {
                _ = try store.createFolder(notebookId: secondNotebook, draft: draft(second), identity: createAdapter, now: 0)
            }
            let expected = try XCTUnwrap(c["expected"] as? [String: Any])
            let count = try store.folders(notebookId: notebook).count
                + (secondNotebook == notebook ? 0 : store.folders(notebookId: secondNotebook).count)
            XCTAssertEqual(count, expected["folderCount"] as? Int, c["name"] as? String ?? "")
            if let counts = expected["folderCountsByNotebook"] as? [String: Int] {
                XCTAssertEqual(try store.folders(notebookId: notebook).count, counts["1"])
                XCTAssertEqual(try store.folders(notebookId: secondNotebook).count, counts["2"])
            }
            if let persisted = expected["persistedIdentity"] as? [String: Any] {
                XCTAssertEqual(try store.folders(notebookId: notebook).first?.identity, try folderIdentity(persisted))
                XCTAssertEqual(recorded?.resolvedPaths, expected["resolvedPathsAfterReopen"] as? [String])
            }
            // Display/rules updates must retain the resolved identity without touching the adapter.
            let renamed = FolderDraft(rootPath: first, displayName: "Renamed", includeExts: ["txt", "md"],
                                      ignoreGlobs: ["build/"], limitsJSON: "{\"maxBytes\":64}",
                                      encodingFallback: "none", watchEnabled: false)
            try store.updateFolder(id: firstFolder.id, draft: renamed, identity: CatalogIdentity(values: []))
            let updated = try XCTUnwrap(store.folders(notebookId: notebook).first { $0.id == firstFolder.id })
            XCTAssertEqual(updated.draft, renamed)
            XCTAssertEqual(updated.identity, firstFolder.identity)
            try store.setEvidenceBudgetCap(notebookId: notebook, value: 0)
            XCTAssertEqual(try store.evidenceBudgetCap(notebookId: notebook), 0)
            XCTAssertThrowsError(try store.setEvidenceBudgetCap(notebookId: notebook, value: -1))
        }
        try assertFolderUpdateValidation()
    }

    func testRelativePathsAndInventory() throws {
        for c in try cases(operation: "relative-paths") {
            let store = try V19TestStore.make()
            let notebook = try XCTUnwrap(store.createNotebook(name: "paths").id)
            let folder = try store.createFolder(notebookId: notebook, draft: draft("/docs"),
                                                identity: CatalogIdentity(values: [("/docs", FolderIdentity(volumeId: "v", components: ["docs"], rootFileId: "root-1"))]), now: 0)
            var accepted: [String] = []
            var rejected = 0
            for p in try XCTUnwrap(c["paths"] as? [[String: Any]]) {
                let path = try XCTUnwrap(p["path"] as? String)
                let source = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text,
                    title: "Path", uri: nil, rawPath: nil).id)
                if p["valid"] as? Bool == true {
                    try store.attachSource(sourceId: source, folderId: folder.id, relPath: path)
                    accepted.append(path)
                    try store.runOnDatabase { db in
                        XCTAssertEqual(try String.fetchOne(db, sql: "SELECT rel_path FROM sources WHERE id=?", arguments: [source]), path)
                    }
                } else {
                    let error = try XCTUnwrap(p["expectedError"] as? String)
                    assertError(error) { try store.attachSource(sourceId: source, folderId: folder.id, relPath: path) }
                    try store.runOnDatabase { db in
                        XCTAssertThrowsError(try db.execute(sql: "UPDATE sources SET folder_id=?,rel_path=? WHERE id=?", arguments: [folder.id, path, source]))
                        XCTAssertThrowsError(try db.execute(sql: """
                            INSERT INTO sources(notebook_id,type,title,status,ingested_at,folder_id,rel_path)
                            VALUES(?,'text','invalid','pending','2026-01-02 03:04:05.000',?,?)
                            """, arguments: [notebook, folder.id, path]))
                        XCTAssertNil(try Int64.fetchOne(db, sql: "SELECT folder_id FROM sources WHERE id=?", arguments: [source]))
                    }
                    rejected += 1
                }
            }
            let expected = try XCTUnwrap(c["expected"] as? [String: Any])
            XCTAssertEqual(accepted, expected["acceptedPaths"] as? [String])
            XCTAssertEqual(rejected, expected["rejectedCount"] as? Int)
        }
        for c in try cases(operation: "inventory-upsert") {
            let store = try seeded(c)
            let folderID = try id(c, "folderId")
            let items = try XCTUnwrap(c["items"] as? [[String: Any]]).map(scanItem)
            XCTAssertFalse(items.isEmpty)
            for item in items { try store.upsertScanItems(folderId: folderID, items: [item]) }
            let expected = try XCTUnwrap(c["expected"] as? [String: Any])
            let persisted = try store.scanItems(folderId: folderID)
            XCTAssertEqual(persisted.count, expected["rowCount"] as? Int)
            XCTAssertEqual(persisted, try XCTUnwrap(expected["items"] as? [[String: Any]]).map(scanItem))
            let valid = ScanItem(folderId: folderID, relPath: "new.md", kind: "eligible", skipReason: nil,
                                 mtime: nil, sizeBytes: nil, seenGeneration: 3)
            let wrong = ScanItem(folderId: folderID + 1, relPath: "wrong.md", kind: "eligible", skipReason: nil,
                                 mtime: nil, sizeBytes: nil, seenGeneration: 3)
            XCTAssertThrowsError(try store.upsertScanItems(folderId: folderID, items: [valid, wrong]))
            XCTAssertEqual(try store.scanItems(folderId: folderID), persisted)
            assertError("notFound") { _ = try store.scanItems(folderId: 999) }
            assertError("notFound") { try store.upsertScanItems(folderId: 999, items: []) }
        }
    }

    func testFolderDeleteOnlyCascadesDatabase() throws {
        for c in try cases(operation: "remove-folder") {
            let store = try seeded(c)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let fs = try XCTUnwrap(c["filesystem"] as? [String: Any])
            let paths = try XCTUnwrap(fs["existingPaths"] as? [String])
            let root = directory.appendingPathComponent(paths[0])
            let file = directory.appendingPathComponent(paths[1])
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bytes = Data("The user's document must survive database removal.".utf8)
            try bytes.write(to: file)
            let folderID = try id(c, "folderId")
            try store.runOnDatabase { db in
                try db.execute(sql: "UPDATE folder_sources SET root_path=? WHERE id=?", arguments: [root.path, folderID])
                try db.execute(sql: "UPDATE sources SET raw_path=? WHERE folder_id=?", arguments: [file.path, folderID])
            }
            let before = try FileManager.default.attributesOfItem(atPath: file.path)
            try store.deleteFolder(id: folderID)
            let expected = try XCTUnwrap(c["expected"] as? [String: Any])
            try store.runOnDatabase { db in
                let idQueries = [
                    "folderIds": "SELECT id FROM folder_sources ORDER BY id",
                    "sourceIds": "SELECT id FROM sources ORDER BY id",
                    "sourceSetMemberIds": "SELECT source_id FROM source_set_members ORDER BY source_id",
                    "sourceSetFolderIds": "SELECT folder_id FROM source_set_folders ORDER BY folder_id",
                    "sourceSetIds": "SELECT id FROM source_sets ORDER BY id",
                    "generationIds": "SELECT id FROM index_generations ORDER BY id"
                ]
                for (key, sql) in idQueries { XCTAssertEqual(try Int64.fetchAll(db, sql: sql), try ids(expected, key), key) }
                let tables = ["scanItemCount": "scan_items", "revisionCount": "source_revisions", "chunkCount": "source_chunks",
                              "vectorCount": "chunk_embeddings", "manifestCount": "index_generation_manifest", "jobCount": "ingest_jobs"]
                for (key, table) in tables {
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)"), expected[key] as? Int, key)
                }
                XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, before[.modificationDate] as? Date)
            XCTAssertEqual(expected["filesystemDeleteOperations"] as? Int, 0)
            XCTAssertEqual(expected["filesystemWriteOperations"] as? Int, 0)
            assertError("notFound") { try store.deleteFolder(id: folderID) }
        }
    }

    func testMembershipAtomicity() throws {
        for c in try cases(operation: "membership") {
            let store = try seeded(c)
            for event in try XCTUnwrap(c["events"] as? [[String: Any]]) {
                let error = try XCTUnwrap(event["expectedError"] as? String)
                assertError(error) {
                    switch try XCTUnwrap(event["op"] as? String) {
                    case "setSourceSetMembers":
                        try store.setSourceSetMembers(setId: id(event, "setId"), sourceIds: ids(event, "sourceIds"))
                    case "setSourceSetFolders":
                        try store.setSourceSetFolders(setId: id(event, "setId"), folderIds: ids(event, "folderIds"))
                    case "attachSource":
                        try store.attachSource(sourceId: id(event, "sourceId"), folderId: id(event, "folderId"),
                                               relPath: XCTUnwrap(event["relPath"] as? String))
                    default: XCTFail("Unconsumed membership event")
                    }
                }
                try assertMembership(store, expected: XCTUnwrap(event["expected"] as? [String: Any]))
            }
            try assertMembership(store, expected: XCTUnwrap(c["expected"] as? [String: Any]))
            try store.runOnDatabase { db in
                XCTAssertThrowsError(try db.execute(sql: "UPDATE sources SET folder_id=1,rel_path='2.md' WHERE id=2"))
                XCTAssertThrowsError(try db.execute(sql: "INSERT INTO source_set_folders(set_id,folder_id) VALUES(1,2)"))
                XCTAssertThrowsError(try db.execute(sql: "UPDATE source_set_folders SET folder_id=2 WHERE set_id=1"))
            }
            assertError("notFound") { try store.setSourceSetFolders(setId: 1, folderIds: [1, 999]) }
            XCTAssertThrowsError(try store.setSourceSetMembers(setId: 1, sourceIds: [1, 999]))
            try assertMembership(store, expected: XCTUnwrap(c["expected"] as? [String: Any]))
            try store.setSourceSetFolders(setId: 1, folderIds: [1, 1])
            try store.setSourceSetMembers(setId: 1, sourceIds: [1, 1])
            try assertMembership(store, expected: XCTUnwrap(c["expected"] as? [String: Any]))
            try store.setSourceSetFolders(setId: 1, folderIds: [])
            try store.setSourceSetMembers(setId: 1, sourceIds: [])
            XCTAssertTrue(try store.sourceSetFolders(setId: 1).isEmpty)
            XCTAssertTrue(try store.sourceSetMembers(setId: 1).isEmpty)
            assertError("notFound") { _ = try store.sourceSetFolders(setId: 999) }
            assertError("notFound") { try store.setSourceSetFolders(setId: 999, folderIds: []) }
        }
    }

    func testCoverageSnapshot() throws {
        let selected = try cases(operation: "coverage").filter { ["coverage", "coverage-no-generation"].contains($0["name"] as? String ?? "") }
        XCTAssertFalse(selected.isEmpty)
        for c in selected {
            let store = try seeded(c)
            let notebook = try id(c, "notebookId")
            let scope = try scope(c)
            try assertCoverage(store.coverage(notebookId: notebook, scope: scope), expected: XCTUnwrap(c["expected"] as? [String: Any]))
            // A repeated snapshot must not mutate catalog state.
            try assertCoverage(store.coverage(notebookId: notebook, scope: scope), expected: XCTUnwrap(c["expected"] as? [String: Any]))
            if c["name"] as? String == "coverage-no-generation" {
                try store.runOnDatabase { db in
                    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM index_generations"), 0)
                }
            }
            assertError("notFound") { _ = try store.coverage(notebookId: 999, scope: .all) }
        }
    }

    func testCoverageScopeIsolation() throws {
        let selected = try cases(operation: "coverage").filter { !["coverage", "coverage-no-generation"].contains($0["name"] as? String ?? "") }
        XCTAssertFalse(selected.isEmpty)
        for c in selected {
            let store = try seeded(c)
            let notebook = try id(c, "notebookId")
            try assertCoverage(store.coverage(notebookId: notebook, scope: scope(c)), expected: XCTUnwrap(c["expected"] as? [String: Any]))
            if c["name"] as? String == "folder-union" {
                // Foreign notebook IDs in an otherwise identical selection cannot leak entities.
                try assertCoverage(store.coverage(notebookId: notebook, scope: .selection(sourceIds: [1, 2, 20], folderIds: [1, 2])),
                                   expected: XCTUnwrap(c["expected"] as? [String: Any]))
            }
            if c["name"] as? String == "empty-selection" {
                // An included partial folder remains a lower bound even if it has no source rows.
                try store.runOnDatabase { db in
                    try db.execute(sql: "DELETE FROM sources WHERE folder_id=1")
                    try db.execute(sql: "DELETE FROM scan_items WHERE folder_id=1")
                }
                var expected = try XCTUnwrap(c["expected"] as? [String: Any])
                expected["isLowerBound"] = true
                try assertCoverage(store.coverage(notebookId: notebook, scope: .selection(sourceIds: [], folderIds: [1])), expected: expected)
            }
        }
    }

    func testModelLimitsAndEvidenceCap() throws {
        for c in try cases(operation: "evidence-cap") {
            let store = try seeded(c)
            let notebook = try id(c, "notebookId")
            let values = try XCTUnwrap(c["values"] as? [Any])
            let expected = try XCTUnwrap(c["expectedValues"] as? [Any])
            let errors = try XCTUnwrap(c["expectedErrors"] as? [Any])
            XCTAssertEqual(values.count, expected.count)
            XCTAssertEqual(values.count, errors.count)
            for index in values.indices {
                if let error = errors[index] as? String {
                    assertError(error) { try store.setEvidenceBudgetCap(notebookId: notebook, value: values[index] as? Int) }
                } else {
                    try store.setEvidenceBudgetCap(notebookId: notebook, value: values[index] as? Int)
                }
                XCTAssertEqual(try store.evidenceBudgetCap(notebookId: notebook), expected[index] as? Int)
            }
            assertError("notFound") { _ = try store.evidenceBudgetCap(notebookId: 999) }
            assertError("notFound") { try store.setEvidenceBudgetCap(notebookId: 999, value: 0) }
        }
        for c in try cases(operation: "limits") {
            let store = try seeded(c)
            for event in try XCTUnwrap(c["events"] as? [[String: Any]]) {
                if event["op"] as? String == "get" {
                    XCTAssertNil(try store.modelLimits(providerId: XCTUnwrap(event["providerId"] as? String), model: XCTUnwrap(event["model"] as? String)))
                    continue
                }
                let value = try modelLimits(XCTUnwrap(event["limits"] as? [String: Any]))
                if let error = event["expectedError"] as? String {
                    assertError(error) { try store.setModelLimits(value) }
                } else {
                    let before = try (event["before"] as? [String: Any]).map(modelLimits)
                    XCTAssertEqual(try store.modelLimits(providerId: value.providerId, model: value.model), before)
                    try store.setModelLimits(value)
                    XCTAssertEqual(try store.modelLimits(providerId: value.providerId, model: value.model), try modelLimits(XCTUnwrap(event["expected"] as? [String: Any])))
                }
                if let expected = event["expectedRecords"] as? [[String: Any]] { try assertLimits(store, expected: expected) }
            }
            let expected = try XCTUnwrap(c["expected"] as? [String: Any])
            try assertLimits(store, expected: XCTUnwrap(expected["records"] as? [[String: Any]]))
            let valid = try modelLimits(XCTUnwrap(c["after"] as? [String: Any]))
            assertError("notFound") {
                try store.setModelLimits(ProviderModelLimits(providerId: "missing", model: valid.model, contextWindow: valid.contextWindow,
                    runtimeContext: valid.runtimeContext, maxOutputTokens: valid.maxOutputTokens, source: valid.source))
            }
            assertError("invalidValue") {
                try store.setModelLimits(ProviderModelLimits(providerId: valid.providerId, model: valid.model, contextWindow: valid.contextWindow,
                    runtimeContext: valid.runtimeContext, maxOutputTokens: valid.maxOutputTokens, source: "invalid"))
            }
            try assertLimits(store, expected: XCTUnwrap(expected["records"] as? [[String: Any]]))
        }
    }

    private func cases(operation: String) throws -> [[String: Any]] {
        let root = try SharedFixtures.json("contracts/storage-catalog-v1.json")
        let all = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let operations: Set<String> = ["overlap", "relative-paths", "inventory-upsert", "membership", "remove-folder", "coverage", "evidence-cap", "limits"]
        XCTAssertEqual(Set(all.compactMap { $0["operation"] as? String }), operations)
        XCTAssertTrue(all.allSatisfy { $0["operation"] is String })
        let selected = all.filter { $0["operation"] as? String == operation }
        XCTAssertFalse(selected.isEmpty, operation)
        return selected
    }

    private func seeded(_ c: [String: Any]) throws -> NotebookStore {
        let store = try V19TestStore.make()
        let sql = try XCTUnwrap(c["setupSql"] as? [String])
        try store.runOnDatabase { db in for statement in sql { try db.execute(sql: statement) } }
        return store
    }

    private func draft(_ path: String) -> FolderDraft {
        FolderDraft(rootPath: path, displayName: "Docs", includeExts: ["md"], ignoreGlobs: [],
                    limitsJSON: "{}", encodingFallback: "cp1250", watchEnabled: true)
    }

    private func folderIdentity(_ value: [String: Any]) throws -> FolderIdentity {
        FolderIdentity(volumeId: try XCTUnwrap(value["volumeId"] as? String), components: try XCTUnwrap(value["components"] as? [String]),
                       rootFileId: try XCTUnwrap(value["rootFileId"] as? String))
    }

    private func id(_ value: [String: Any], _ key: String) throws -> Int64 {
        try XCTUnwrap(value[key] as? NSNumber, key).int64Value
    }

    private func ids(_ value: [String: Any], _ key: String) throws -> [Int64] {
        try XCTUnwrap(value[key] as? [NSNumber], key).map(\.int64Value)
    }

    private func scanItem(_ value: [String: Any]) throws -> ScanItem {
        ScanItem(folderId: try id(value, "folderId"), relPath: try XCTUnwrap(value["relPath"] as? String),
                 kind: try XCTUnwrap(value["kind"] as? String), skipReason: value["skipReason"] as? String,
                 mtime: (value["mtime"] as? NSNumber)?.int64Value, sizeBytes: (value["sizeBytes"] as? NSNumber)?.int64Value,
                 seenGeneration: try id(value, "seenGeneration"))
    }

    private func scope(_ c: [String: Any]) throws -> RetrievalScope {
        try JSONDecoder().decode(RetrievalScope.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(c["scope"])))
    }

    private func modelLimits(_ value: [String: Any]) throws -> ProviderModelLimits {
        ProviderModelLimits(providerId: try XCTUnwrap(value["providerId"] as? String), model: try XCTUnwrap(value["model"] as? String),
                            contextWindow: value["contextWindow"] as? Int, runtimeContext: try XCTUnwrap(value["runtimeContext"] as? Int),
                            maxOutputTokens: try XCTUnwrap(value["maxOutputTokens"] as? Int), source: try XCTUnwrap(value["source"] as? String))
    }

    private func assertError(_ expected: String, file: StaticString = #filePath, line: UInt = #line,
                             _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual(($0 as? StorageV19Error)?.code, expected, file: file, line: line)
        }
    }

    private func assertMembership(_ store: NotebookStore, expected: [String: Any]) throws {
        XCTAssertEqual(try store.sourceSetMembers(setId: 1), try ids(expected, "sourceIds"))
        XCTAssertEqual(try store.sourceSetFolders(setId: 1), try ids(expected, "folderIds"))
        try store.runOnDatabase { db in
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT folder_id FROM sources WHERE id=2"), (expected["source2FolderId"] as? NSNumber)?.int64Value)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT rel_path FROM sources WHERE id=2"), expected["source2RelPath"] as? String)
        }
    }

    private func assertCoverage(_ actual: CoverageSnapshot, expected: [String: Any]) throws {
        let counts = ["searchable": actual.searchable, "notSearchable": actual.notSearchable, "current": actual.current,
                      "pending": actual.pending, "error": actual.error, "skipped": actual.skipped, "missing": actual.missing,
                      "unavailable": actual.unavailable, "refreshPending": actual.refreshPending, "refreshError": actual.refreshError]
        for (key, count) in counts { XCTAssertEqual(count, expected[key] as? Int, key) }
        XCTAssertEqual(actual.isLowerBound, expected["isLowerBound"] as? Bool)
        XCTAssertEqual(actual.searchable + actual.notSearchable, actual.current + actual.refreshPending + actual.refreshError)
        XCTAssertEqual(actual.notSearchable, actual.pending + actual.error)
    }

    private func assertLimits(_ store: NotebookStore, expected: [[String: Any]]) throws {
        for value in expected {
            let limits = try modelLimits(value)
            XCTAssertEqual(try store.modelLimits(providerId: limits.providerId, model: limits.model), limits)
        }
        try store.runOnDatabase { db in XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM provider_model_limits"), expected.count) }
    }

    private func assertFolderUpdateValidation() throws {
        let overlap = try XCTUnwrap(cases(operation: "overlap").first { $0["name"] as? String == "ancestor-root" })
        let first = try XCTUnwrap(overlap["firstPath"] as? String)
        let second = try XCTUnwrap(overlap["secondPath"] as? String)
        let volume = try XCTUnwrap(overlap["volume"] as? String)
        let adapter = CatalogIdentity(values: [
            (first, FolderIdentity(volumeId: volume, components: try XCTUnwrap(overlap["firstComponents"] as? [String]),
                                   rootFileId: try XCTUnwrap(overlap["firstRootFileId"] as? String))),
            (second, FolderIdentity(volumeId: volume, components: try XCTUnwrap(overlap["secondComponents"] as? [String]),
                                    rootFileId: try XCTUnwrap(overlap["secondRootFileId"] as? String))),
            ("/other", FolderIdentity(volumeId: volume, components: ["other"], rootFileId: "root-3")),
            ("/changed", FolderIdentity(volumeId: volume, components: ["changed"], rootFileId: "root-4"))
        ])
        let store = try V19TestStore.make()
        let notebook = try XCTUnwrap(store.createNotebook(name: "updates").id)
        _ = try store.createFolder(notebookId: notebook, draft: draft(first), identity: adapter, now: 0)
        let other = try store.createFolder(notebookId: notebook, draft: draft("/other"), identity: adapter, now: 0)
        assertError(try XCTUnwrap(overlap["expectedError"] as? String)) {
            try store.updateFolder(id: other.id, draft: draft(second), identity: adapter)
        }
        XCTAssertEqual(try store.folders(notebookId: notebook).first { $0.id == other.id }, other)
        assertError("notFound") { try store.updateFolder(id: other.id, draft: draft("/unknown"), identity: adapter) }
        XCTAssertEqual(try store.folders(notebookId: notebook).first { $0.id == other.id }, other)
        try store.updateFolder(id: other.id, draft: draft("/changed"), identity: adapter)
        let changed = try XCTUnwrap(store.folders(notebookId: notebook).first { $0.id == other.id })
        XCTAssertEqual(changed.draft.rootPath, "/changed")
        XCTAssertEqual(changed.identity, try adapter.resolve(rootPath: "/changed"))
        let source = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: "member", uri: nil, rawPath: nil).id)
        try store.attachSource(sourceId: source, folderId: other.id, relPath: "member.md")
        assertError("invalidValue") { try store.updateFolder(id: other.id, draft: draft("/other"), identity: adapter) }
        XCTAssertEqual(try store.folders(notebookId: notebook).first { $0.id == other.id }, changed)
        for invalidLimits in ["[]", "null", "invalid JSON"] {
            let invalid = FolderDraft(rootPath: "/other", displayName: "Docs", includeExts: ["md"], ignoreGlobs: [],
                                      limitsJSON: invalidLimits, encodingFallback: "cp1250", watchEnabled: true)
            assertError("invalidValue") { _ = try store.createFolder(notebookId: notebook, draft: invalid, identity: adapter, now: 0) }
        }
        assertError("notFound") { _ = try store.folders(notebookId: 999) }
        assertError("notFound") { _ = try store.createFolder(notebookId: 999, draft: draft("/other"), identity: adapter, now: 0) }
        assertError("notFound") { try store.updateFolder(id: 999, draft: draft(first), identity: adapter) }
    }
}

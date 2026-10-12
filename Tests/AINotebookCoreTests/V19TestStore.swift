import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

@MainActor
enum V19TestStore {
    static func make() throws -> NotebookStore {
        try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
    }

    static func upgradeCopy(configuredKey: String?) throws -> (NotebookStore, URL, V19MigrationReport) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let url = directory.appendingPathComponent("db.sqlite")
            try FileManager.default.copyItem(at: SharedFixtures.url("storage/v18.sqlite"), to: url)
            let queue = try DatabaseQueue(path: url.path)
            do {
                let migrator = v18Migrator()
                try migrator.migrate(queue)
                let report = try queue.write { db in
                    let report = try migrateV19(db, configuredEmbeddingModelKey: configuredKey)
                    try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v19_folder_rag')")
                    return report
                }
                try queue.close()
                let store = try NotebookStore(path: StorePath(fileURL: url), configuredEmbeddingModelKey: configuredKey)
                return (store, directory, report)
            } catch {
                try? queue.close()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func reopen(at url: URL, configuredKey: String?) throws -> NotebookStore {
        try NotebookStore(path: StorePath(fileURL: url), configuredEmbeddingModelKey: configuredKey)
    }

    private static func v18Migrator() -> DatabaseMigrator {
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
        return migrator
    }

    static func assertQueries(_ store: NotebookStore, queries: [[String: Any]],
                              file: StaticString = #filePath, line: UInt = #line) throws {
        try store.runOnDatabase { db in
            for query in queries {
                let sql = try XCTUnwrap(query["sql"] as? String, file: file, line: line)
                let expected = try XCTUnwrap(query["rows"] as? [[Any]], file: file, line: line)
                let actual: [[Any]] = try Row.fetchAll(db, sql: sql).map { row in
                    row.map { _, value -> Any in
                        switch value.storage {
                        case .null: return NSNull()
                        case .int64(let value): return NSNumber(value: value)
                        case .double(let value): return NSNumber(value: value)
                        case .string(let value): return value
                        case .blob(let value): return value.map { String(format: "%02X", $0) }.joined()
                        }
                    }
                }
                XCTAssertEqual(actual as NSArray, expected as NSArray, sql, file: file, line: line)
            }
        }
    }
}

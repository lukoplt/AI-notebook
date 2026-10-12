import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

/// Shared retrieval fixture rows are inserted directly because they model an
/// already activated historical generation, rather than an activation request.
@MainActor enum RetrievalFixtureStore {
    private static var traces: [ObjectIdentifier: SQLTrace] = [:]

    static func cases() throws -> [[String: Any]] {
        try XCTUnwrap(SharedFixtures.json("contracts/retrieval-scope-v1.json")["cases"] as? [[String: Any]])
    }

    static func make(_ caseName: String = "all", path: StorePath = .inMemory) throws -> NotebookStore {
        let store = try NotebookStore(path: path, configuredEmbeddingModelKey: nil)
        try seed(store, caseName: caseName)
        return store
    }

    static func seed(_ store: NotebookStore, caseName: String = "all") throws {
        let seed = try XCTUnwrap(SharedFixtures.json("contracts/retrieval-scope-v1.json")["seed"] as? [String: Any])
        try store.runOnDatabase { db in
            for row in try rows(seed, "notebooks") {
                try insert(db, "notebooks", row, ["id": "id", "name": "name", "createdAt": "created_at", "updatedAt": "updated_at"])
            }
            for row in try rows(seed, "folders") {
                var row = row
                for key in ["pathIdentity", "includeExts", "ignoreGlobs", "limits"] {
                    row[key] = String(decoding: try JSONSerialization.data(withJSONObject: row[key]!, options: [.sortedKeys]), as: UTF8.self)
                }
                try insert(db, "folder_sources", row, ["id": "id", "notebookId": "notebook_id", "rootPath": "root_path",
                    "pathIdentity": "path_identity", "displayName": "display_name", "includeExts": "include_exts",
                    "ignoreGlobs": "ignore_globs", "limits": "limits", "createdAt": "created_at"])
            }
            for row in try rows(seed, "sources") {
                try insert(db, "sources", row, ["id": "id", "notebookId": "notebook_id", "type": "type", "title": "title",
                    "status": "status", "folderId": "folder_id", "relPath": "rel_path", "availability": "availability",
                    "eligible": "eligible", "ingestedAt": "ingested_at"])
            }
            for row in try rows(seed, "revisions") {
                try insert(db, "source_revisions", row, ["id": "id", "sourceId": "source_id", "revision": "revision",
                    "contentHash": "content_hash", "canonicalText": "canonical_text", "textFormatVersion": "text_format_version",
                    "chunkerVersion": "chunker_version", "createdAt": "created_at"])
            }
            for row in try rows(seed, "chunks") {
                try insert(db, "source_chunks", row, ["id": "id", "sourceId": "source_id", "revisionId": "revision_id",
                    "ord": "ord", "text": "text", "tokenCount": "token_count", "charStart": "char_start", "charEnd": "char_end"])
            }
            for row in try rows(seed, "sources") {
                try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?",
                    arguments: StatementArguments([try value(row["currentRevision"]), try value(row["publishedRevisionId"]), try value(row["id"])]))
            }
            for row in try rows(seed, "generations") {
                try insert(db, "index_generations", row, ["id": "id", "notebookId": "notebook_id", "providerId": "provider_id",
                    "endpointRevision": "endpoint_revision", "model": "model", "modelDigest": "model_digest", "dims": "dims",
                    "normalization": "normalization", "queryFormatVersion": "query_format_version", "docFormatVersion": "doc_format_version",
                    "chunkerVersion": "chunker_version", "state": "state", "createdAt": "created_at"])
            }
            for row in try rows(seed, "manifest") {
                try insert(db, "index_generation_manifest", row, ["generationId": "generation_id", "sourceId": "source_id",
                    "revisionId": "revision_id", "state": "state", "reason": "reason"])
            }
            for row in try rows(seed, "embeddings") {
                let vector = try XCTUnwrap(row["vector"] as? [NSNumber]).map(\.floatValue)
                try db.execute(sql: "INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES(?,?,?)",
                    arguments: [try number(row, "chunkId"), try number(row, "generationId"), EmbeddingVector(values: vector).asData()])
            }
            if caseName == "no-active" {
                try db.execute(sql: "UPDATE index_generations SET state='retired' WHERE state='active'")
            }
        }
        try installTrace(store)
    }

    static func applyEvent(_ name: String, to store: NotebookStore) throws {
        let fixture = try XCTUnwrap(cases().first { $0["name"] as? String == name })
        let events = try XCTUnwrap(fixture["events"] as? [[String: Any]])
        try store.runOnDatabase { db in
            for event in events {
                switch try XCTUnwrap(event["kind"] as? String) {
                case "setAvailability":
                    try db.execute(sql: "UPDATE sources SET availability=? WHERE id=?",
                        arguments: [try XCTUnwrap(event["value"] as? String), try number(event, "sourceId")])
                case "setEligible":
                    try db.execute(sql: "UPDATE sources SET eligible=? WHERE id=?",
                        arguments: [try number(event, "value"), try number(event, "sourceId")])
                case "setFolder":
                    try db.execute(sql: "UPDATE sources SET folder_id=?,rel_path=? WHERE id=?",
                        arguments: [try number(event, "folderId"), try XCTUnwrap(event["relPath"] as? String), try number(event, "sourceId")])
                case "publish":
                    let revision = try number(event, "revisionId"), source = try number(event, "sourceId")
                    let text = "needle revision \(revision)"
                    try db.execute(sql: """
                        INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                        VALUES(?,?,?,?,?,1,1,'2026-01-01 00:00:00.000')
                        """, arguments: [revision, source, revision % 100, "fixture-\(revision)", text])
                    try db.execute(sql: "INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count) VALUES(?,?,?,0,?,4)",
                        arguments: [revision * 10, source, revision, text])
                    try db.execute(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?",
                        arguments: [revision, revision, source])
                case "switchGeneration":
                    try db.execute(sql: "UPDATE index_generations SET state='retired' WHERE id=?", arguments: [try number(event, "oldId")])
                    try db.execute(sql: "UPDATE index_generations SET state='active' WHERE id=?", arguments: [try number(event, "newId")])
                default: XCTFail("Unknown retrieval event: \(event)")
                }
            }
        }
    }

    static func sqlStatementCount(_ store: NotebookStore) -> Int {
        traces[ObjectIdentifier(store)]?.count ?? 0
    }

    private static func installTrace(_ store: NotebookStore) throws {
        let trace = SQLTrace()
        traces[ObjectIdentifier(store)] = trace
        try store.runOnDatabase { db in db.trace { _ in trace.increment() } }
        trace.reset()
    }

    private static func rows(_ value: [String: Any], _ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(value[key] as? [[String: Any]], key)
    }

    private static func number(_ row: [String: Any], _ key: String) throws -> Int64 {
        try XCTUnwrap(row[key] as? NSNumber, key).int64Value
    }

    private static func value(_ value: Any?) throws -> DatabaseValue {
        switch value {
        case nil, is NSNull: return .null
        case let value as NSNumber: return value.int64Value.databaseValue
        case let value as String: return value.databaseValue
        default: throw CocoaError(.coderReadCorrupt)
        }
    }

    private static func insert(_ db: Database, _ table: String, _ row: [String: Any], _ columns: [String: String]) throws {
        let keys = columns.keys.sorted()
        let names = keys.map { columns[$0]! }.joined(separator: ",")
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        try db.execute(sql: "INSERT INTO \(table)(\(names)) VALUES(\(placeholders))",
            arguments: StatementArguments(try keys.map { try value(row[$0]) }))
    }
}

private final class SQLTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var statements = 0
    var count: Int { lock.withLock { statements } }
    func increment() { lock.withLock { statements += 1 } }
    func reset() { lock.withLock { statements = 0 } }
}

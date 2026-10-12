import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private final class ScopeChat: ChatStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [[ChatTurn]] = []
    var captured: [[ChatTurn]] { lock.lock(); defer { lock.unlock() }; return prompts }
    func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        lock.lock(); prompts.append(messages); lock.unlock()
        return AsyncThrowingStream { c in c.yield("ok"); c.finish() }
    }
    func stream(model: String, messages: [ChatTurn], options: ChatRequestOptions) -> AsyncThrowingStream<String, Error> {
        stream(model: model, messages: messages)
    }
}

private struct UnitEmbedder: EmbeddingProducing {
    func embed(model: String, inputs: [String]) async throws -> [[Float]] { inputs.map { _ in [1, 0] } }
}

@MainActor
final class FolderScopeTests: XCTestCase {
    func testEmptySelectionNeverBecomesAll() {
        let s = FolderScopeSelection(wholeNotebook: false)
        XCTAssertEqual(s.resolved(setScopes: [:]), .selection(sourceIds: [], folderIds: []))
        XCTAssertEqual(FolderScopeSelection().resolved(setScopes: [:]), .all)
    }

    func testResolveSetsEachTurnWithoutExpandingFolders() {
        let s = FolderScopeSelection(wholeNotebook: false, sourceIds: [1], folderIds: [8], setIds: [9])
        XCTAssertEqual(s.resolved(setScopes: [9: .selection(sourceIds: [2], folderIds: [7])]),
            .selection(sourceIds: [1, 2], folderIds: [7, 8]))
        XCTAssertEqual(s.resolved(setScopes: [9: .selection(sourceIds: [3], folderIds: [10])]),
            .selection(sourceIds: [1, 3], folderIds: [8, 10]))
        XCTAssertEqual(s.resolved(setScopes: [:]), .selection(sourceIds: [1], folderIds: [8]))
    }

    func testAllSharedScopeCases() throws {
        let root = try SharedFixtures.json("contracts/ingestion-ui-v1.json")
        let cases = (root["cases"] as! [[String: Any]]).filter { $0["operation"] as? String == "scope" }
        XCTAssertFalse(cases.isEmpty)
        func ids(_ x: Any?) -> Set<Int64> { Set((x as! [NSNumber]).map(\.int64Value)) }
        for c in cases {
            let i = c["input"] as! [String: Any], e = c["expected"] as! [String: Any]
            let s = FolderScopeSelection(wholeNotebook: i["wholeNotebook"] as! Bool,
                sourceIds: ids(i["sourceIds"]), folderIds: ids(i["folderIds"]), setIds: ids(i["setIds"]))
            var sets: [Int64: RetrievalScope] = [:]
            for row in i["members"] as! [[String: Any]] {
                sets[(row["setId"] as! NSNumber).int64Value] = .selection(
                    sourceIds: ids(row["sourceIds"]), folderIds: ids(row["folderIds"]))
            }
            let expected: RetrievalScope = e["kind"] as! String == "all" ? .all :
                .selection(sourceIds: ids(e["sourceIds"]), folderIds: ids(e["folderIds"]))
            XCTAssertEqual(s.resolved(setScopes: sets), expected, c["name"] as! String)
        }
    }

    // MARK: Store resolver

    private func seededStore(_ seed: [String: Any]) throws -> NotebookStore {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        func int64(_ v: Any?) -> Int64 { (v as! NSNumber).int64Value }
        try store.runOnDatabase { db in
            let date = Date(timeIntervalSince1970: 0)
            for notebook in seed["notebooks"] as! [[String: Any]] {
                try db.execute(sql: "INSERT INTO notebooks(id,name,created_at,updated_at) VALUES(?,'nb',?,?)", arguments: [int64(notebook["id"]), date, date])
            }
            for folder in seed["folders"] as! [[String: Any]] {
                let id = int64(folder["id"])
                try db.execute(sql: """
                    INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,created_at)
                    VALUES(?,?,?,?,'F','["md"]','[]','{}',?)
                    """, arguments: [id, int64(folder["notebookId"]), "/f\(id)",
                                      #"{"volumeId":"v","components":["f\#(id)"],"rootFileId":"r\#(id)"}"#, date])
            }
            for source in seed["sources"] as! [[String: Any]] {
                let id = int64(source["id"])
                try db.execute(sql: """
                    INSERT INTO sources(id,notebook_id,type,title,status,ingested_at,folder_id,rel_path) VALUES(?,?,'text','s','ready',?,?,?)
                    """, arguments: [id, int64(source["notebookId"]), date, (source["folderId"] as? NSNumber)?.int64Value, "s\(id).md"])
            }
            for set in seed["sets"] as! [[String: Any]] {
                let id = int64(set["id"])
                try db.execute(sql: "INSERT INTO source_sets(id,notebook_id,name,created_at) VALUES(?,?,?,?)", arguments: [id, int64(set["notebookId"]), "set\(id)", date])
                for s in set["sourceIds"] as! [NSNumber] {
                    try db.execute(sql: "INSERT INTO source_set_members(set_id,source_id) VALUES(?,?)", arguments: [id, s.int64Value])
                }
                for f in set["folderIds"] as! [NSNumber] {
                    try db.execute(sql: "INSERT INTO source_set_folders(set_id,folder_id) VALUES(?,?)", arguments: [id, f.int64Value])
                }
            }
        }
        return store
    }

    private func storeCases() throws -> [[String: Any]] {
        try XCTUnwrap(SharedFixtures.json("contracts/ingestion-ui-v1.json")["cases"] as? [[String: Any]])
            .filter { $0["operation"] as? String == "scope-store" }
    }

    private func run(_ row: [String: Any]) throws {
        let name = row["name"] as! String, input = row["input"] as! [String: Any], expected = row["expected"] as! [String: Any]
        func ids(_ x: Any?) -> Set<Int64> { Set((x as! [NSNumber]).map(\.int64Value)) }
        let store = try seededStore(input["seed"] as! [String: Any])
        let s = input["selection"] as! [String: Any]
        let selection = FolderScopeSelection(wholeNotebook: s["wholeNotebook"] as! Bool, sourceIds: ids(s["sourceIds"]),
                                             folderIds: ids(s["folderIds"]), setIds: ids(s["setIds"]))
        let notebook = (input["notebookId"] as! NSNumber).int64Value
        if let error = expected["error"] as? String {
            XCTAssertThrowsError(try store.resolveFolderScope(notebookId: notebook, selection: selection), name) {
                XCTAssertEqual(($0 as? StorageV19Error)?.code, error, name)
            }
        } else {
            let scope = expected["scope"] as! [String: Any]
            let value: RetrievalScope = scope["kind"] as! String == "all" ? .all
                : .selection(sourceIds: ids(scope["sourceIds"]), folderIds: ids(scope["folderIds"]))
            XCTAssertEqual(try store.resolveFolderScope(notebookId: notebook, selection: selection), value, name)
        }
    }

    func testStoreRejectsCrossNotebookIDs() throws {
        let rows = try storeCases()
        XCTAssertEqual(rows.count, 5)
        for row in rows { try run(row) }
    }

    func testRemovedSelectedFolderStaysEmpty() async throws {
        let row = try XCTUnwrap(storeCases().first { $0["name"] as? String == "removed-explicit-folder" })
        try run(row)
        let store = try seededStore((row["input"] as! [String: Any])["seed"] as! [String: Any])
        // Deleting a selected folder leaves an empty selection; it never becomes all.
        let selection = FolderScopeSelection(wholeNotebook: false, folderIds: [1])
        XCTAssertEqual(try store.resolveFolderScope(notebookId: 1, selection: selection), .selection(sourceIds: [], folderIds: [1]))
        try store.deleteFolder(id: 1)
        let scope = try store.resolveFolderScope(notebookId: 1, selection: selection)
        XCTAssertEqual(scope, .selection(sourceIds: [], folderIds: []))
        XCTAssertEqual(try store.chatSourceIds(notebookId: 1, scope: scope), [])
        XCTAssertNil(try store.chatSourceIds(notebookId: 1, scope: .all))

        // An empty typed scope retrieves no evidence instead of the legacy empty-means-all.
        let notebook = try store.createNotebook(name: "chat")
        let source = try store.createSource(notebookId: notebook.id!, type: .text, title: "doc", uri: nil, rawPath: nil)
        _ = try store.commitForegroundRevision(sourceId: source.id!, draft: RevisionDraft(contentHash: "h",
            canonicalText: "the secret ingredient is saffron", textFormatVersion: 1, chunkerVersion: 2),
            chunks: ScalarChunker.chunk("the secret ingredient is saffron"), now: 0, leaseToken: "seed")
        let session = try store.createChatSession(notebookId: notebook.id!, title: "T")
        let chat = ScopeChat()
        let engine = ChatEngine(store: store, retriever: Retriever(store: store, client: UnitEmbedder(), model: "m"),
                                chat: chat, chatModel: "m")
        _ = try await engine.send(sessionId: session.id!, notebookId: notebook.id!, userText: "saffron",
                                  scope: .selection(sourceIds: [], folderIds: [])) { _ in }
        XCTAssertFalse(try XCTUnwrap(chat.captured.last).contains { $0.content.contains("secret ingredient") },
                       "no evidence in an empty scope")
        XCTAssertTrue(try XCTUnwrap(chat.captured.last?.last?.content).contains("Turn: 0 passages from 0 files"))
        _ = try await engine.send(sessionId: session.id!, notebookId: notebook.id!, userText: "saffron", scope: .all) { _ in }
        XCTAssertTrue(try XCTUnwrap(chat.captured.last?.last?.content).contains("secret ingredient"), "whole notebook finds it")
        XCTAssertFalse(try XCTUnwrap(chat.captured.last?.first?.content).contains("secret ingredient"), "evidence is never system text")
        _ = try await engine.regenerate(sessionId: session.id!, notebookId: notebook.id!,
                                        scope: .selection(sourceIds: [source.id!], folderIds: [])) { _ in }
        XCTAssertTrue(try XCTUnwrap(chat.captured.last?.last?.content).contains("secret ingredient"))
    }

    func testSaveFolderScopeSet() throws {
        let row = try XCTUnwrap(storeCases().first { $0["name"] as? String == "owned-set-scope" })
        let store = try seededStore((row["input"] as! [String: Any])["seed"] as! [String: Any])
        XCTAssertThrowsError(try store.saveFolderScopeSet(notebookId: 1, name: "all", selection: FolderScopeSelection()))
        let saved = try store.saveFolderScopeSet(notebookId: 1, name: "mine",
            selection: FolderScopeSelection(wholeNotebook: false, sourceIds: [], folderIds: [], setIds: [9]))
        XCTAssertEqual(try store.sourceSetMembers(setId: saved.id), [101])
        XCTAssertEqual(try store.sourceSetFolders(setId: saved.id), [1])
        XCTAssertThrowsError(try store.saveFolderScopeSet(notebookId: 1, name: "x",
            selection: FolderScopeSelection(wholeNotebook: false, folderIds: [2])))
    }
}

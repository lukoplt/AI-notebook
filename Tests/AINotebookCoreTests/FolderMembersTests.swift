import Foundation
import XCTest
@testable import AINotebookCore

private struct MembersIdentity: FolderPathIdentity {
    func resolve(rootPath: String) throws -> FolderIdentity {
        FolderIdentity(volumeId: "v", components: [rootPath], rootFileId: rootPath)
    }
}

/// Shared `folder-members-v1` fixture: the paged member query behind the grouped Sources list.
@MainActor
final class FolderMembersTests: XCTestCase {
    private func cases() throws -> [[String: Any]] {
        try XCTUnwrap(SharedFixtures.json("contracts/folder-members-v1.json")["cases"] as? [[String: Any]])
    }

    private func named(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(cases().first { $0["name"] as? String == name })
    }

    private func draft(_ root: String) -> FolderDraft {
        FolderDraft(rootPath: root, displayName: root, includeExts: ["md"], ignoreGlobs: [],
                    limitsJSON: "{}", encodingFallback: "cp1250", watchEnabled: false)
    }

    private struct Seeded {
        let store: NotebookStore
        let notebook: Int64
        let folder: Int64
        let ids: [String: Int64]
    }

    private func seed(_ c: [String: Any], rawPath: (String) -> String? = { _ in nil }) throws -> Seeded {
        let store = try V19TestStore.make()
        let notebook = try XCTUnwrap(store.createNotebook(name: "members").id)
        let folder = try store.createFolder(notebookId: notebook, draft: draft("/docs"), identity: MembersIdentity(), now: 0)
        let other = try store.createFolder(notebookId: notebook, draft: draft("/other"), identity: MembersIdentity(), now: 0)
        var ids: [String: Int64] = [:]
        for path in c["members"] as? [String] ?? [] {
            let id = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: "t-" + path,
                                                      uri: nil, rawPath: rawPath(path)).id)
            try store.attachSource(sourceId: id, folderId: folder.id, relPath: path)
            ids[path] = id
        }
        for path in c["otherFolderMembers"] as? [String] ?? [] {
            let id = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: "o-" + path, uri: nil, rawPath: nil).id)
            try store.attachSource(sourceId: id, folderId: other.id, relPath: path)
        }
        for title in c["looseTitles"] as? [String] ?? [] {
            try store.createSource(notebookId: notebook, type: .text, title: title, uri: nil, rawPath: nil)
        }
        for title in c["noteTitles"] as? [String] ?? [] {
            try store.createSource(notebookId: notebook, type: .note, title: title, uri: nil, rawPath: nil)
        }
        return Seeded(store: store, notebook: notebook, folder: folder.id, ids: ids)
    }

    private func assertPage(_ store: NotebookStore, folder: Int64, _ p: [String: Any],
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let page = try store.folderMembers(folderId: folder, offset: try XCTUnwrap(p["offset"] as? Int),
                                           limit: try XCTUnwrap(p["limit"] as? Int))
        XCTAssertEqual(page.members.map { $0.relPath ?? "" }, p["expected"] as? [String], file: file, line: line)
        XCTAssertTrue(page.members.allSatisfy { $0.folderId == folder }, file: file, line: line)
        XCTAssertEqual(page.total, p["total"] as? Int, file: file, line: line)
        XCTAssertEqual(page.nextOffset, p["nextOffset"] as? Int, file: file, line: line)
        XCTAssertEqual(page.hasMore, p["hasMore"] as? Bool, file: file, line: line)
    }

    func testPagesFollowByteOrderAndExcludeOtherFoldersAndLooseSources() throws {
        for name in ["paged-byte-order", "empty-folder"] {
            let c = try named(name)
            let seeded = try seed(c)
            for p in try XCTUnwrap(c["pages"] as? [[String: Any]]) {
                try assertPage(seeded.store, folder: seeded.folder, p)
            }
            let loose = try seeded.store.looseSources(notebookId: seeded.notebook)
            XCTAssertEqual(loose.map(\.title).sorted(), c["expectedLooseTitles"] as? [String], name)
            XCTAssertTrue(loose.allSatisfy { $0.folderId == nil && $0.type != .note }, name)
        }
    }

    func testInvalidArgumentsAreRejected() throws {
        let fixture = try SharedFixtures.json("contracts/folder-members-v1.json")
        XCTAssertEqual(fixture["maxLimit"] as? Int, NotebookStore.folderMembersMaxLimit)
        XCTAssertEqual(fixture["uiPageSize"] as? Int, NotebookStore.folderMembersPageSize)
        let c = try named("invalid-arguments")
        let seeded = try seed(c)
        for row in try XCTUnwrap(c["invalid"] as? [[String: Any]]) {
            let folder = row["folder"] as? String == "missing" ? Int64(999_999) : seeded.folder
            XCTAssertThrowsError(try seeded.store.folderMembers(folderId: folder, offset: try XCTUnwrap(row["offset"] as? Int),
                                                                limit: try XCTUnwrap(row["limit"] as? Int))) {
                XCTAssertEqual(($0 as? StorageV19Error)?.code, row["expectedError"] as? String)
            }
        }
    }

    func testDeletingAMemberKeepsTheFileOnDisk() throws {
        let c = try named("delete-member-keeps-file")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = try XCTUnwrap(c["deleteMember"] as? String)
        let file = directory.appendingPathComponent("member.md")
        try Data("keep me".utf8).write(to: file)
        let seeded = try seed(c) { $0 == target ? file.path : nil }
        try seeded.store.deleteSource(id: try XCTUnwrap(seeded.ids[target]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep me")
        try assertPage(seeded.store, folder: seeded.folder, try XCTUnwrap(c["after"] as? [String: Any]))
    }
}


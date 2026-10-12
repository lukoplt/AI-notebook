import Foundation
import XCTest
@testable import AINotebookCore

private final class WalkCalls: @unchecked Sendable {
    private let gate = NSLock()
    private var paths: [String] = []
    func record(_ path: String) { gate.lock(); defer { gate.unlock() }; paths.append(path) }
    var snapshot: [String] { gate.lock(); defer { gate.unlock() }; return paths }
}

private final class FileAccessEvents: @unchecked Sendable {
    private let gate = NSLock()
    private var blocks: [Int] = []
    private var flag = false
    func read(_ size: Int) { gate.lock(); defer { gate.unlock() }; blocks.append(size) }
    var reads: [Int] { gate.lock(); defer { gate.unlock() }; return blocks }
    func cancel() { gate.lock(); defer { gate.unlock() }; flag = true }
    var cancelled: Bool { gate.lock(); defer { gate.unlock() }; return flag }
}

private struct ScriptedFS: FolderFileSystem {
    let root: FolderSource
    private let sensitive: Bool
    private let directories: [String: [FolderEntry]]
    private let stamps: [String: FileStamp]
    private let denied: Set<String>
    private let calls = WalkCalls()
    private let bodyCalls = WalkCalls()
    var listCalls: [String] { calls.snapshot }
    var readCalls: [String] { bodyCalls.snapshot }

    init(caseJSON: [String: Any]) throws {
        let input = try XCTUnwrap(caseJSON["input"] as? [String: Any])
        let value = try XCTUnwrap(input["root"] as? [String: Any])
        let identity = FolderIdentity(volumeId: value["volumeId"] as! String,
            components: value["components"] as! [String], rootFileId: value["rootFileId"] as! String)
        let draft = FolderDraft(rootPath: value["rootPath"] as! String, displayName: value["displayName"] as! String,
            includeExts: ["md"], ignoreGlobs: input["ignoreGlobs"] as? [String] ?? [], limitsJSON: "{}",
            encodingFallback: "cp1250", watchEnabled: true)
        root = FolderSource(id: (value["id"] as! NSNumber).int64Value,
            notebookId: (value["notebookId"] as! NSNumber).int64Value, draft: draft, identity: identity,
            scanState: "idle", scanGeneration: 0, lastFullScanAt: nil, lastScanError: nil, createdAt: 0)
        sensitive = input["caseSensitive"] as! Bool
        let values = (input["stats"] as! [String: [String: Any]]).mapValues { value in
            FileStamp(identity: value["identity"] as! String,
                mtimeNs: (value["mtimeNs"] as! NSNumber).int64Value,
                sizeBytes: (value["sizeBytes"] as! NSNumber).int64Value)
        }
        stamps = values
        directories = try (input["directories"] as! [String: [[String: Any]]]).mapValues { rows in
            try rows.map { row in
                let path = row["relPath"] as! String
                return FolderEntry(relPath: path, isDirectory: row["isDirectory"] as! Bool,
                    isLink: row["isLink"] as! Bool, stamp: try XCTUnwrap(values[path]))
            }
        }
        let errors = input["listErrors"] as! [String: String]
        XCTAssertTrue(errors.values.allSatisfy { $0 == "permissionDenied" })
        denied = Set(errors.keys)
    }
    func resolve(rootPath: String) throws -> FolderIdentity {
        XCTAssertEqual(rootPath, root.draft.rootPath)
        return root.identity
    }
    func caseSensitive(root: FolderSource) throws -> Bool { sensitive }
    func list(root: FolderSource, directory: String) throws -> [FolderEntry] {
        calls.record(directory)
        if denied.contains(directory) { throw CocoaError(.fileReadNoPermission) }
        return try XCTUnwrap(directories[directory], "unexpected list: \(directory)")
    }
    func stat(root: FolderSource, relativePath: String) throws -> FileStamp {
        try XCTUnwrap(stamps[relativePath], "unexpected stat: \(relativePath)")
    }
    func hash(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderRead {
        bodyCalls.record(relativePath)
        XCTFail("walk must not hash file bodies")
        throw CocoaError(.fileReadUnknown)
    }
    func snapshot(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderFileSnapshot {
        bodyCalls.record(relativePath)
        XCTFail("walk must not snapshot file bodies")
        throw CocoaError(.fileReadUnknown)
    }
}

final class FolderFileSystemTests: XCTestCase {
    private func rows(_ operation: String) throws -> [[String: Any]] {
        let rows = try XCTUnwrap(SharedFixtures.json("contracts/ingestion-scan-v1.json")["cases"] as? [[String: Any]])
        return rows.filter { $0["operation"] as? String == operation }
    }
    private func identity(_ value: [String: Any]) -> FolderIdentity {
        FolderIdentity(volumeId: value["volumeId"] as! String,
            components: value["components"] as! [String], rootFileId: value["rootFileId"] as! String)
    }
    private func stamp(_ value: [String: Any]) -> FileStamp {
        FileStamp(identity: value["identity"] as! String, mtimeNs: (value["mtimeNs"] as! NSNumber).int64Value,
            sizeBytes: (value["sizeBytes"] as! NSNumber).int64Value)
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolderFileSystemTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func root(_ url: URL, fileSystem: NativeFolderFileSystem) throws -> FolderSource {
        let draft = FolderDraft(rootPath: url.path, displayName: url.lastPathComponent,
            includeExts: ["md"], ignoreGlobs: [], limitsJSON: "{}", encodingFallback: "cp1250", watchEnabled: true)
        return FolderSource(id: 1, notebookId: 1, draft: draft, identity: try fileSystem.resolve(rootPath: url.path),
            scanState: "idle", scanGeneration: 0, lastFullScanAt: nil, lastScanError: nil, createdAt: 0)
    }
    private func assertError(_ code: String, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? IngestionError)?.code, code, "\($0)", file: file, line: line)
        }
    }

    func testPartialSiblingCompletion() async throws {
        let row = try XCTUnwrap(rows("walk").first { $0["name"] as? String == "partial-sibling" })
        let fs = try ScriptedFS(caseJSON: row)
        let result = try await FolderWalk(fileSystem: fs).walk(root: fs.root, cancelled: { false }, visit: { _ in })
        XCTAssertEqual(result.completed, ["good"])
        XCTAssertEqual(result.incomplete, ["bad", ""])
        XCTAssertFalse(result.rootUnavailable)
        XCTAssertEqual(fs.listCalls, ["", "bad", "good"])
        XCTAssertEqual(fs.readCalls, [])
    }

    func testAllWalkTraces() async throws {
        let cases = try rows("walk")
        var covered = Set<String>()
        for row in cases {
            let name = row["name"] as! String, expected = row["expected"] as! [String: Any]
            XCTAssertTrue(covered.insert(name).inserted)
            let fs = try ScriptedFS(caseJSON: row), visited = WalkCalls()
            let result = try await FolderWalk(fileSystem: fs).walk(root: fs.root, cancelled: { false }, visit: { visited.record($0.relPath) })
            let completion = expected["completion"] as! [String: Any]
            XCTAssertEqual(result.completed, completion["completed"] as? [String], name)
            XCTAssertEqual(result.incomplete, completion["incomplete"] as? [String], name)
            XCTAssertEqual(result.rootUnavailable, completion["rootUnavailable"] as? Bool, name)
            XCTAssertEqual(fs.listCalls, expected["listCalls"] as? [String], name)
            if let paths = expected["visitedPaths"] as? [String] { XCTAssertEqual(visited.snapshot, paths, name) }
            XCTAssertEqual(fs.readCalls, [], name)
            if let reads = expected["targetReadCalls"] as? Int { XCTAssertEqual(fs.readCalls.count, reads, name) }
        }
        XCTAssertEqual(covered.count, 7)

        let nested = try XCTUnwrap(cases.first { $0["name"] as? String == "nested-eligible-file" })
        let cancelled = try ScriptedFS(caseJSON: nested)
        let initial = try await FolderWalk(fileSystem: cancelled).walk(root: cancelled.root, cancelled: { true }, visit: { _ in XCTFail("cancelled walk visited an entry") })
        XCTAssertEqual(initial.completed, [])
        XCTAssertEqual(cancelled.listCalls, [])
        let partial = try ScriptedFS(caseJSON: nested), signal = FileAccessEvents(), visits = WalkCalls()
        let stopped = try await FolderWalk(fileSystem: partial).walk(root: partial.root, cancelled: { signal.cancelled }, visit: {
            visits.record($0.relPath)
            signal.cancel()
        })
        XCTAssertEqual(stopped.completed, [])
        XCTAssertFalse(stopped.rootUnavailable)
        XCTAssertEqual(partial.listCalls, [""])
        XCTAssertEqual(visits.snapshot, ["nested"])

        let visitorFailure = try ScriptedFS(caseJSON: nested)
        do {
            _ = try await FolderWalk(fileSystem: visitorFailure).walk(root: visitorFailure.root, cancelled: { false }, visit: { _ in throw CocoaError(.fileReadUnknown) })
            XCTFail("Unexpected visitor failure must propagate, never manufacture subtree completion")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadUnknown) }
    }

    /// A read that fails on a dataless (cloud placeholder, e.g. iCloud Drive
    /// "Optimize Mac Storage") file reports `notDownloaded`; other read failures
    /// are unchanged. Reading itself is not changed: it may still download.
    func testDatalessReadFailureIsNotDownloaded() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("inside".utf8).write(to: directory.appendingPathComponent("a.md"))
        for dataless in [true, false] {
            let fs = NativeFolderFileSystem(beforeOpen: { _ in }, didRead: { _ in throw POSIXError(.EDEADLK) },
                                            isDataless: { _ in dataless })
            let saved = try root(directory, fileSystem: fs)
            XCTAssertThrowsError(try fs.hash(root: saved, relativePath: "a.md", maxBytes: 100)) {
                if dataless { XCTAssertEqual(($0 as? IngestionError)?.code, "notDownloaded") }
                else { XCTAssertEqual(($0 as? POSIXError)?.code, .EDEADLK) }
            }
        }
        XCTAssertTrue(DatalessFile.isDataless(flags: 0x4000_0000))
        XCTAssertFalse(DatalessFile.isDataless(flags: 0))
        XCTAssertFalse(DatalessFile.isDataless(path: directory.appendingPathComponent("a.md").path))
    }

    func testNativeSymlinkAndContainment() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documents = directory.appendingPathComponent("docs"), outside = directory.appendingPathComponent("docs2")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("secret.md")
        try Data("private".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: documents.appendingPathComponent("file-link.md"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: documents.appendingPathComponent("directory-link"), withDestinationURL: outside)
        let events = FileAccessEvents()
        let fs = NativeFolderFileSystem(beforeOpen: { _ in }, didRead: { events.read($0) })
        let saved = try root(documents, fileSystem: fs), visited = WalkCalls()
        let result = try await FolderWalk(fileSystem: fs).walk(root: saved, cancelled: { false }, visit: { visited.record($0.relPath) })
        XCTAssertEqual(result.completed, [""])
        XCTAssertEqual(visited.snapshot, ["directory-link", "file-link.md"])
        for path in ["file-link.md", "directory-link/secret.md"] {
            assertError("interiorLink") { _ = try fs.hash(root: saved, relativePath: path, maxBytes: 100) }
            assertError("interiorLink") { _ = try fs.snapshot(root: saved, relativePath: path, maxBytes: 100) }
        }
        for path in ["../docs2/secret.md", target.path, "directory-link/../file-link.md", "a//b", "."] {
            assertError("outsideRoot") { _ = try fs.hash(root: saved, relativePath: path, maxBytes: 100) }
        }
        XCTAssertEqual(events.reads, [])

        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: documents)
        let aliasRoot = try root(alias, fileSystem: fs)
        XCTAssertEqual(aliasRoot.identity, saved.identity)
        XCTAssertEqual(try fs.stat(root: aliasRoot, relativePath: "").identity, saved.identity.rootFileId)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        assertError("rootIdentityChanged") { _ = try fs.list(root: aliasRoot, directory: "") }
        let retargeted = try await FolderWalk(fileSystem: fs).walk(root: aliasRoot, cancelled: { false }, visit: { _ in XCTFail("retargeted root visited") })
        XCTAssertTrue(retargeted.rootUnavailable)
        XCTAssertEqual(retargeted.completed, [])
        XCTAssertEqual(events.reads, [])
        try FileManager.default.removeItem(at: documents)
        let unavailable = try await FolderWalk(fileSystem: fs).walk(root: saved, cancelled: { false }, visit: { _ in XCTFail("missing root visited") })
        XCTAssertTrue(unavailable.rootUnavailable)
        XCTAssertEqual(unavailable.completed, [])

        let finalRootURL = directory.appendingPathComponent("final-root")
        let finalAlias = directory.appendingPathComponent("final-alias")
        try FileManager.default.createDirectory(at: finalRootURL, withIntermediateDirectories: true)
        try Data("last".utf8).write(to: finalRootURL.appendingPathComponent("a.md"))
        try FileManager.default.createSymbolicLink(at: finalAlias, withDestinationURL: finalRootURL)
        let finalRoot = try root(finalAlias, fileSystem: fs)
        let retargetedAtFinish = try await FolderWalk(fileSystem: fs).walk(root: finalRoot, cancelled: { false }, visit: { entry in
            XCTAssertEqual(entry.relPath, "a.md")
            try FileManager.default.removeItem(at: finalAlias)
            try FileManager.default.createSymbolicLink(at: finalAlias, withDestinationURL: outside)
        })
        XCTAssertTrue(retargetedAtFinish.rootUnavailable)
        XCTAssertEqual(retargetedAtFinish.completed, [], "A last-entry visitor cannot leave the previous selected root completed")

        let parentURL = directory.appendingPathComponent("parent")
        let childURL = parentURL.appendingPathComponent("child")
        let movedChildURL = directory.appendingPathComponent("moved-child")
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
        try Data("last".utf8).write(to: childURL.appendingPathComponent("a.md"))
        let parentRoot = try root(parentURL, fileSystem: fs)
        let replacedAtFinish = try await FolderWalk(fileSystem: fs).walk(root: parentRoot, cancelled: { false }, visit: { entry in
            if entry.relPath == "child/a.md" {
                try FileManager.default.moveItem(at: childURL, to: movedChildURL)
                try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
            }
        })
        XCTAssertFalse(replacedAtFinish.rootUnavailable)
        XCTAssertEqual(replacedAtFinish.completed, [])
        XCTAssertEqual(replacedAtFinish.incomplete, ["child", ""])
        XCTAssertEqual(events.reads, [])

        let deletedParentURL = directory.appendingPathComponent("deleted-parent")
        let deletedChildURL = deletedParentURL.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: deletedChildURL, withIntermediateDirectories: true)
        try Data("last".utf8).write(to: deletedChildURL.appendingPathComponent("a.md"))
        let deletedParentRoot = try root(deletedParentURL, fileSystem: fs)
        do {
            let deletedAtFinish = try await FolderWalk(fileSystem: fs).walk(root: deletedParentRoot, cancelled: { false }, visit: { entry in
                if entry.relPath == "child/a.md" { try FileManager.default.removeItem(at: deletedChildURL) }
            })
            XCTAssertFalse(deletedAtFinish.rootUnavailable)
            XCTAssertEqual(deletedAtFinish.completed, [])
            XCTAssertEqual(deletedAtFinish.incomplete, ["child", ""])
        } catch { XCTFail("A child deleted during its last visitor must produce partial completion: \(error)") }

        let fileParentURL = directory.appendingPathComponent("file-parent")
        let fileChildURL = fileParentURL.appendingPathComponent("child")
        let nestedURL = fileChildURL.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try Data("last".utf8).write(to: nestedURL.appendingPathComponent("a.md"))
        let fileParentRoot = try root(fileParentURL, fileSystem: fs)
        do {
            let fileAtFinish = try await FolderWalk(fileSystem: fs).walk(root: fileParentRoot, cancelled: { false }, visit: { entry in
                if entry.relPath == "child/nested/a.md" {
                    try FileManager.default.removeItem(at: fileChildURL)
                    try Data("replacement file".utf8).write(to: fileChildURL)
                }
            })
            XCTAssertFalse(fileAtFinish.rootUnavailable)
            XCTAssertEqual(fileAtFinish.completed, [])
            XCTAssertEqual(fileAtFinish.incomplete, ["child/nested", "child", ""])
        } catch { XCTFail("An ancestor replaced with a regular file during its last visitor must produce partial completion: \(error)") }
        XCTAssertEqual(events.reads, [])
    }

    func testOpenRace() throws {
        var count = 0
        for row in try rows("open") {
            count += 1
            let input = row["input"] as! [String: Any], expected = row["expected"] as! [String: Any]
            var reads = 0
            assertError(expected["error"] as! String) {
                try FolderAccessValidation.validateOpen(enumerated: stamp(input["enumerated"] as! [String: Any]),
                    opened: stamp(input["opened"] as! [String: Any]), openedIsLink: input["openedIsLink"] as! Bool,
                    parentBefore: input["parentBefore"] as! String, parentAfter: input["parentAfter"] as! String)
                reads += 1
            }
            XCTAssertEqual(reads, expected["readCalls"] as? Int)
        }
        XCTAssertEqual(count, 2)
        let original = FileStamp(identity: "file-1", mtimeNs: 1, sizeBytes: 1)
        assertError("changedDuringExtraction") {
            try FolderAccessValidation.validateOpen(enumerated: original,
                opened: FileStamp(identity: "file-2", mtimeNs: 1, sizeBytes: 1), openedIsLink: false,
                parentBefore: "dir-1", parentAfter: "dir-1")
        }
        try FolderAccessValidation.validateOpen(enumerated: original, opened: original, openedIsLink: false,
            parentBefore: "dir-1", parentAfter: "dir-1")

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documents = directory.appendingPathComponent("docs"), outside = directory.appendingPathComponent("outside.md")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        let file = documents.appendingPathComponent("a.md")
        try Data("inside".utf8).write(to: file)
        let reads = FileAccessEvents()
        let fs = NativeFolderFileSystem(beforeOpen: { _ in
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        }, didRead: { reads.read($0) })
        let saved = try root(documents, fileSystem: fs)
        assertError("interiorLink") { _ = try fs.hash(root: saved, relativePath: "a.md", maxBytes: 100) }
        XCTAssertEqual(reads.reads, [])

        try FileManager.default.removeItem(at: file)
        let child = documents.appendingPathComponent("child"), renamed = directory.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: child.appendingPathComponent("a.md"))
        let swapped = NativeFolderFileSystem(beforeOpen: { _ in
            try FileManager.default.moveItem(at: child, to: renamed)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data("replacement".utf8).write(to: child.appendingPathComponent("a.md"))
        }, didRead: { reads.read($0) })
        assertError("outsideRoot") { _ = try swapped.hash(root: saved, relativePath: "child/a.md", maxBytes: 100) }
        XCTAssertEqual(reads.reads, [])

        let alias = directory.appendingPathComponent("selected-alias")
        let alternate = directory.appendingPathComponent("alternate")
        try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: true)
        try Data("other root".utf8).write(to: alternate.appendingPathComponent("a.md"))
        try Data("old root".utf8).write(to: documents.appendingPathComponent("a.md"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: documents)
        let retargeted = NativeFolderFileSystem(beforeOpen: { _ in
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: alternate)
        }, didRead: { reads.read($0) })
        let aliasRoot = try root(alias, fileSystem: retargeted)
        assertError("rootIdentityChanged") { _ = try retargeted.hash(root: aliasRoot, relativePath: "a.md", maxBytes: 100) }
        XCTAssertEqual(reads.reads, [], "Retargeting the selected root must fail before reading the retained old target")
    }

    func testStreamingHashAndCancellation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.md"), bytes = Data(repeating: 97, count: 131_077)
        try bytes.write(to: file)
        let events = FileAccessEvents()
        let fs = NativeFolderFileSystem(beforeOpen: { _ in }, didRead: { events.read($0) })
        let saved = try root(directory, fileSystem: fs)
        let hashed = try fs.hash(root: saved, relativePath: "large.md", maxBytes: Int64(bytes.count))
        XCTAssertEqual(hashed.sha256, "99d31cce9bcf8d3c5482530b5ee5c77abedaf5f4e6fc9591e42abf8a0dfcf174")
        XCTAssertTrue(hashed.bytes.isEmpty, "Hash must retain zero payload bytes")
        XCTAssertEqual(hashed.stamp.sizeBytes, Int64(bytes.count))
        XCTAssertEqual(events.reads.reduce(0, +), bytes.count)
        XCTAssertTrue(events.reads.allSatisfy { $0 > 0 && $0 <= 65_536 })
        XCTAssertGreaterThan(events.reads.count, 1)
        let limited = FileAccessEvents()
        let limitedFS = NativeFolderFileSystem(beforeOpen: { _ in }, didRead: { limited.read($0) })
        assertError("fileLimit") { _ = try limitedFS.hash(root: saved, relativePath: "large.md", maxBytes: 65_536) }
        XCTAssertLessThanOrEqual(limited.reads.reduce(0, +), 65_536)

        let snapshot = try fs.snapshot(root: saved, relativePath: "large.md", maxBytes: Int64(bytes.count))
        let path = snapshot.url
        XCTAssertNotEqual(path.path, file.path)
        XCTAssertEqual(path.pathExtension, "md")
        XCTAssertEqual(snapshot.hash, hashed.sha256)
        XCTAssertEqual(snapshot.stamp, hashed.stamp)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        snapshot.close()
        snapshot.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let cancelled = FileAccessEvents()
        let cancelling = NativeFolderFileSystem(beforeOpen: { _ in }, didRead: {
            cancelled.read($0)
            throw CancellationError()
        })
        do {
            _ = try cancelling.snapshot(root: saved, relativePath: "large.md", maxBytes: Int64(bytes.count))
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(cancelled.reads, [65_536])
        let taskEvents = FileAccessEvents()
        let taskFS = NativeFolderFileSystem(beforeOpen: { _ in }, didRead: { taskEvents.read($0) })
        let task = Task.detached { () throws -> FolderRead in
            withUnsafeCurrentTask { $0?.cancel() }
            return try taskFS.hash(root: saved, relativePath: "large.md", maxBytes: Int64(bytes.count))
        }
        do {
            _ = try await task.value
            XCTFail("Expected task cancellation before first file body read")
        } catch { XCTAssertTrue(error is CancellationError || (error as? IngestionError)?.code == "cancelled", "\(error)") }
        XCTAssertEqual(taskEvents.reads, [])
        XCTAssertEqual(try fs.hash(root: saved, relativePath: "large.md", maxBytes: Int64(bytes.count)).sha256, hashed.sha256)

        let alternate = directory.appendingPathComponent("alternate")
        let alias = directory.appendingPathComponent("selected-alias")
        try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: directory.appendingPathComponent("one.md"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let retargetReads = FileAccessEvents()
        let retargeted = NativeFolderFileSystem(beforeOpen: { _ in }, didRead: {
            retargetReads.read($0)
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: alternate)
        })
        let aliasRoot = try root(alias, fileSystem: retargeted)
        assertError("rootIdentityChanged") {
            _ = try retargeted.snapshot(root: aliasRoot, relativePath: "one.md", maxBytes: 100)
        }
        XCTAssertEqual(retargetReads.reads, [3], "A root retargeted during the last read must invalidate the completed copy")
    }

    func testVolumeIdentity() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documents = directory.appendingPathComponent("MiXeD"), alias = directory.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: documents)
        let fs = NativeFolderFileSystem(), native = try fs.resolve(rootPath: documents.path)
        XCTAssertEqual(try fs.resolve(rootPath: alias.path), native)
        XCTAssertEqual(try fs.resolve(rootPath: documents.path), native)
        XCTAssertFalse(native.volumeId.isEmpty)
        XCTAssertFalse(native.rootFileId.isEmpty)
        XCTAssertEqual(native.components.last, "MiXeD")
        let saved = try root(documents, fileSystem: fs)
        XCTAssertEqual(try fs.stat(root: saved, relativePath: "").identity, native.rootFileId)
        if try !fs.caseSensitive(root: saved) {
            XCTAssertEqual(try fs.resolve(rootPath: directory.appendingPathComponent("mixed").path), native)
        }
        var covered = Set<String>()
        for row in try rows("identity") {
            let input = row["input"] as! [String: Any], expected = row["expected"] as! [String: Any]
            let name = row["name"] as! String
            XCTAssertTrue(covered.insert(name).inserted)
            switch input["action"] as? String {
            case "resolve-root":
                var resolutions = 0
                let resolved = try fs.resolve(rootPath: alias.path)
                resolutions += 1
                XCTAssertEqual(resolved, native)
                try FolderAccessValidation.validateRoot(persisted: identity(input["resolvedIdentity"] as! [String: Any]),
                    opened: identity(input["openedIdentity"] as! [String: Any]))
                XCTAssertEqual(identity(input["resolvedIdentity"] as! [String: Any]), identity(expected["identity"] as! [String: Any]))
                XCTAssertEqual(resolutions, expected["rootResolutions"] as? Int)
                XCTAssertEqual(expected["accepted"] as? Bool, true)
            case "validate-root":
                var reads = 0
                assertError(expected["error"] as! String) {
                    try FolderAccessValidation.validateRoot(persisted: identity(input["persistedIdentity"] as! [String: Any]),
                        opened: identity(input["openedIdentity"] as! [String: Any]))
                    reads += 1
                }
                XCTAssertEqual(reads, expected["readCalls"] as? Int)
            case "containment":
                var reads = 0
                assertError(expected["error"] as! String) {
                    try FolderAccessValidation.validateContainment(root: identity(input["rootIdentity"] as! [String: Any]),
                        resolvedComponents: input["resolvedComponents"] as! [String])
                    reads += 1
                }
                XCTAssertEqual(reads, expected["readCalls"] as? Int)
            case "canonicalize-paths":
                let result = FolderAccessValidation.canonicalPaths(input["canonicalPaths"] as! [String])
                XCTAssertEqual(result.map { Array($0.utf8) }, (expected["sourcePaths"] as! [String]).map { Array($0.utf8) }, name)
            default: XCTFail("Unknown identity action: \(input)")
            }
        }
        XCTAssertEqual(covered.count, 6)
        try FolderAccessValidation.validateContainment(root: native, resolvedComponents: native.components + ["a.md"])
        try FolderAccessValidation.validateRoot(persisted: native, opened: native)
        assertError("rootIdentityChanged") {
            try FolderAccessValidation.validateRoot(persisted: native,
                opened: FolderIdentity(volumeId: native.volumeId + "-other", components: native.components, rootFileId: native.rootFileId))
        }
        let composed = "é", decomposed = "e\u{301}"
        XCTAssertEqual(FolderAccessValidation.canonicalPaths([composed, decomposed, composed]).map { Array($0.utf8) },
            [decomposed, composed].map { Array($0.utf8) })

        let largestWholeSeconds = Int64.max / 1_000_000_000
        XCTAssertEqual(try FolderAccessValidation.nanoseconds(seconds: largestWholeSeconds, nanoseconds: 0),
            largestWholeSeconds * 1_000_000_000)
        XCTAssertEqual(try FolderAccessValidation.nanoseconds(seconds: largestWholeSeconds,
            nanoseconds: Int64.max % 1_000_000_000), Int64.max)
        for (seconds, nanoseconds) in [(largestWholeSeconds + 1, Int64(0)),
                                       (largestWholeSeconds, Int64.max % 1_000_000_000 + 1),
                                       (-largestWholeSeconds - 1, Int64(0))] {
            XCTAssertThrowsError(try FolderAccessValidation.nanoseconds(seconds: seconds, nanoseconds: nanoseconds)) {
                XCTAssertEqual(($0 as? POSIXError)?.code, .EOVERFLOW, "Out-of-range metadata must throw, never trap or clamp")
            }
        }
    }
}

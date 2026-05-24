import XCTest
@testable import AINotebookCore

@MainActor
final class AttachmentStoreTests: XCTestCase {

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aino-att-\(UUID().uuidString)")
    }

    func testSaveWritesFileAndDbRow() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "")
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let atts = AttachmentStore(store: store, root: root)

        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let att = try atts.save(noteId: n.id!,
                                noteUuid: n.noteUuid,
                                filename: "icon.png",
                                mime: "image/png",
                                bytes: bytes)
        XCTAssertNotNil(att.id)
        let onDisk = root
            .appendingPathComponent(n.noteUuid)
            .appendingPathComponent("icon.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDisk.path))
        XCTAssertEqual(try Data(contentsOf: onDisk), bytes)
        XCTAssertEqual(try atts.list(noteId: n.id!).count, 1)
    }

    func testCollisionAppendsSuffix() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "")
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let atts = AttachmentStore(store: store, root: root)
        let a = try atts.save(noteId: n.id!, noteUuid: n.noteUuid, filename: "x.png",
                              mime: "image/png", bytes: Data([1]))
        let b = try atts.save(noteId: n.id!, noteUuid: n.noteUuid, filename: "x.png",
                              mime: "image/png", bytes: Data([2]))
        XCTAssertEqual(a.filename, "x.png")
        XCTAssertNotEqual(b.filename, "x.png")
        XCTAssertTrue(b.filename.contains("(2)"), "got: \(b.filename)")
    }

    func testReadReturnsBytes() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "")
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let atts = AttachmentStore(store: store, root: root)
        _ = try atts.save(noteId: n.id!, noteUuid: n.noteUuid, filename: "a.bin",
                          mime: "application/octet-stream", bytes: Data([42, 43, 44]))
        let read = try atts.read(noteUuid: n.noteUuid, filename: "a.bin")
        XCTAssertEqual(read, Data([42, 43, 44]))
    }

    func testDeleteNoteFolderRemovesFiles() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let n = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "")
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let atts = AttachmentStore(store: store, root: root)
        _ = try atts.save(noteId: n.id!, noteUuid: n.noteUuid, filename: "a.png",
                          mime: "image/png", bytes: Data([1]))
        try atts.deleteFolder(noteUuid: n.noteUuid)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(n.noteUuid).path
            )
        )
    }
}

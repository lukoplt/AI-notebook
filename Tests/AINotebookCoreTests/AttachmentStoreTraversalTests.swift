import XCTest
@testable import AINotebookCore

/// The attachment filename has always been reduced to one path component, but
/// the note-folder segment beside it was joined onto the root raw. The scheme
/// handler passes the URL host straight in, so a crafted `attachment://../x`
/// image in a note resolved one level above the attachments root — the
/// directory holding the database. Windows has the same test in
/// AttachmentStoreTraversalTests.cs.
@MainActor
final class AttachmentStoreTraversalTests: XCTestCase {

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aino-att-trav-\(UUID().uuidString)")
    }

    private func fixture() throws -> (atts: AttachmentStore, root: URL, noteId: Int64) {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        // attachments.note_id is a real FK, so the row needs a real note.
        let note = try store.createNote(notebookId: nb.id!, title: "T", bodyMd: "")
        let root = tempRoot()
        return (AttachmentStore(store: store, root: root), root, note.id!)
    }

    /// Asserts the SPECIFIC rejection, not merely "it threw". A plain
    /// XCTAssertThrowsError passes even with the fix removed, because reading
    /// a path that happens not to exist throws too — the escape has to be
    /// distinguished from a miss, hence the real file planted outside the root.
    private func assertRejects(
        _ label: String, _ body: () throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), label, file: file, line: line) { error in
            guard let e = error as? AttachmentStoreError, case .invalidNoteFolder = e else {
                return XCTFail("\(label): expected .invalidNoteFolder, got \(error)",
                               file: file, line: line)
            }
        }
    }

    func testTraversalNoteFolderIsRejected() throws {
        let (atts, root, noteId) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        // A REAL file one level above the attachments root — what the old code
        // handed back to the WebView. Without this the read would fail as
        // "no such file" and mask a missing guard.
        let escaped = root.deletingLastPathComponent().appendingPathComponent("aino-escaped.bin")
        try Data([9, 9, 9]).write(to: escaped)
        defer { try? FileManager.default.removeItem(at: escaped) }

        for uuid in ["..", ".", "", "../..", "foo/.."] {
            let shown = uuid.isEmpty ? "<empty>" : uuid
            assertRejects("read \(shown)") {
                _ = try atts.read(noteUuid: uuid, filename: "aino-escaped.bin")
            }
            assertRejects("deleteFolder \(shown)") { try atts.deleteFolder(noteUuid: uuid) }
            assertRejects("save \(shown)") {
                _ = try atts.save(noteId: noteId, noteUuid: uuid,
                                  filename: "planted.bin", mime: "image/png",
                                  bytes: Data([1]))
            }
        }

        // The guard held: the outside file is untouched and no new one appeared
        // beside it.
        XCTAssertEqual(try Data(contentsOf: escaped), Data([9, 9, 9]))
        let planted = root.deletingLastPathComponent().appendingPathComponent("planted.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: planted.path),
                       "traversal write escaped the attachments root")
    }

    func testRoundTripsInsideTheNoteFolder() throws {
        let (atts, root, noteId) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let uuid = UUID().uuidString.lowercased()
        let bytes = Data([1, 2, 3])
        let att = try atts.save(noteId: noteId, noteUuid: uuid,
                                filename: "shot.png", mime: "image/png", bytes: bytes)

        XCTAssertEqual(try atts.read(noteUuid: uuid, filename: att.filename), bytes)
        let onDisk = root.appendingPathComponent(uuid).appendingPathComponent(att.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDisk.path))
    }
}

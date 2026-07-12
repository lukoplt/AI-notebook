import XCTest
import GRDB
import ZIPFoundation
@testable import AINotebookCore

/// Core-layer tests for Epic B macOS parity: tags, note/global search,
/// export, and DB backup/restore.
@MainActor
final class EpicBCoreTests: XCTestCase {

    // MARK: Tags (FR-B8)

    func testCreateTagIsIdempotentOnName() throws {
        let store = try NotebookStore(path: .inMemory)
        let a = try store.createTag(name: "  physics ")
        let b = try store.createTag(name: "physics")
        XCTAssertEqual(a.id, b.id, "same trimmed name must reuse the row")
        XCTAssertEqual(a.name, "physics")
        XCTAssertEqual(try store.tags().count, 1)
    }

    func testSetAndReadNoteTagsReplacesPrevious() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let note = try store.createNote(notebookId: nb.id!, title: "N", bodyMd: "b")
        let t1 = try store.createTag(name: "a")
        let t2 = try store.createTag(name: "b")
        let t3 = try store.createTag(name: "c")
        try store.setNoteTags(noteId: note.id!, tagIds: [t1.id, t2.id])
        XCTAssertEqual(Set(try store.tagsForNote(noteId: note.id!).map(\.name)), ["a", "b"])
        // Replace, not append.
        try store.setNoteTags(noteId: note.id!, tagIds: [t3.id])
        XCTAssertEqual(try store.tagsForNote(noteId: note.id!).map(\.name), ["c"])
    }

    func testDeleteTagCascadesToNoteTags() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let note = try store.createNote(notebookId: nb.id!, title: "N", bodyMd: "b")
        let t = try store.createTag(name: "temp")
        try store.setNoteTags(noteId: note.id!, tagIds: [t.id])
        try store.deleteTag(id: t.id)
        XCTAssertTrue(try store.tagsForNote(noteId: note.id!).isEmpty)
    }

    // MARK: Search (FR-B4/B9)

    func testSearchNotesScopedToNotebook() throws {
        let store = try NotebookStore(path: .inMemory)
        let a = try store.createNotebook(name: "A")
        let b = try store.createNotebook(name: "B")
        _ = try store.createNote(notebookId: a.id!, title: "Physics", bodyMd: "quantum entanglement")
        _ = try store.createNote(notebookId: b.id!, title: "Physics", bodyMd: "quantum entanglement")
        let hits = try store.searchNotes(notebookId: a.id!, query: "entanglement")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.notebookId, a.id)
    }

    func testGlobalSearchCrossesNotebooks() throws {
        let store = try NotebookStore(path: .inMemory)
        let a = try store.createNotebook(name: "A")
        let b = try store.createNotebook(name: "B")
        _ = try store.createNote(notebookId: a.id!, title: "Alpha", bodyMd: "mitochondria powerhouse")
        _ = try store.createNote(notebookId: b.id!, title: "Beta", bodyMd: "mitochondria membrane")
        let res = try store.globalSearch(query: "mitochondria")
        XCTAssertEqual(res.notes.count, 2)
    }

    func testSearchToleratesPunctuation() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        _ = try store.createNote(notebookId: nb.id!, title: "Note", bodyMd: "AND OR NOT special")
        // A bare "AND"/"OR" would be an FTS syntax error unquoted; escaping fixes it.
        XCTAssertNoThrow(try store.searchNotes(notebookId: nb.id!, query: "AND OR special"))
        let hits = try store.searchNotes(notebookId: nb.id!, query: "special")
        XCTAssertEqual(hits.count, 1)
    }

    func testEmptyQueryReturnsNoHits() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        _ = try store.createNote(notebookId: nb.id!, title: "N", bodyMd: "x")
        XCTAssertTrue(try store.searchNotes(notebookId: nb.id!, query: "   ").isEmpty)
        XCTAssertTrue(try store.globalSearch(query: "").notes.isEmpty)
    }

    // MARK: Export (FR-B1/B2)

    func testExportNoteMarkdownShape() {
        let note = Note(notebookId: 1, title: "My Title", bodyMd: "Line one\nLine two")
        XCTAssertEqual(ExportService.exportNoteMarkdown(note), "# My Title\n\nLine one\nLine two\n")
    }

    func testSanitizeFilenameStripsInvalidChars() {
        XCTAssertEqual(ExportService.sanitizeFilename("a/b:c*?"), "a_b_c") // trailing _ trimmed
        XCTAssertEqual(ExportService.sanitizeFilename("a/b*c"), "a_b_c")
        XCTAssertEqual(ExportService.sanitizeFilename("   "), "note")
    }

    func testExportNotebookZipContainsNotesAndManifest() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        _ = try store.createNote(notebookId: nb.id!, title: "First", bodyMd: "one")
        _ = try store.createNote(notebookId: nb.id!, title: "First", bodyMd: "two") // dup title
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("nb-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: out) }
        try ExportService.exportNotebookZip(notebookId: nb.id!, store: store, to: out)

        let archive = try Archive(url: out, accessMode: .read)
        let paths = archive.map(\.path).sorted()
        XCTAssertTrue(paths.contains("sources.json"), "got: \(paths)")
        XCTAssertEqual(paths.filter { $0.hasPrefix("notes/") && $0.hasSuffix(".md") }.count, 2,
                       "dup titles must not collide: \(paths)")
    }

    // MARK: Backup / restore (FR-B3)

    func testBackupThenRestoreRoundTrips() throws {
        let store = try NotebookStore(path: .inMemory)
        _ = try store.createNotebook(name: "Original")
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("bk-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: backup) }
        try store.backupDatabase(to: backup)

        // Mutate after the backup, then restore and confirm the mutation is gone.
        _ = try store.createNotebook(name: "AddedLater")
        XCTAssertEqual(store.notebooks.count, 2)
        try store.restoreDatabase(from: backup)
        XCTAssertEqual(store.notebooks.map(\.name), ["Original"])
    }
}

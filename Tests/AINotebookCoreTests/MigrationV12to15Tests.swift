import XCTest
import GRDB
@testable import AINotebookCore

/// Schema-parity tests for the macOS port of Windows migrations v12–v15
/// (Epics B/C/D/E). Verifies tables, columns, the notes_fts virtual table +
/// triggers, and the FTS backfill of pre-existing notes.
@MainActor
final class MigrationV12to15Tests: XCTestCase {

    private func columnNames(_ db: Database, table: String) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info('\(table)')")
        return Set(rows.compactMap { $0["name"] as String? })
    }

    private func tableExists(_ db: Database, _ name: String) throws -> Bool {
        try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM sqlite_master WHERE type IN ('table','view') AND name = ?",
            arguments: [name]
        ) == 1
    }

    // MARK: v12 — tags + notes_fts

    func testV12CreatesTagTables() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            XCTAssertTrue(try tableExists(db, "tags"))
            XCTAssertEqual(try columnNames(db, table: "tags"), ["id", "name"])
            XCTAssertEqual(try columnNames(db, table: "note_tags"), ["note_id", "tag_id"])
            XCTAssertEqual(try columnNames(db, table: "source_tags"), ["source_id", "tag_id"])
        }
    }

    func testV12CreatesNotesFtsAndTriggerIndexesNewNote() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        try store.runOnDatabase { db in
            try db.execute(sql: """
                INSERT INTO notes(notebook_id, title, body_md, origin, created_at, updated_at)
                VALUES (?, 'Quantum notes', 'entanglement and superposition', 'manual', datetime('now'), datetime('now'))
                """, arguments: [nb.id])
            let hits = try Int.fetchOne(db, sql: "SELECT count(*) FROM notes_fts WHERE notes_fts MATCH 'superposition'")
            XCTAssertEqual(hits, 1, "insert trigger should index the new note")
        }
    }

    func testV12BackfillsExistingNotesIntoFts() throws {
        // Build a v11 DB, insert a note (no notes_fts yet), then run v12 and
        // assert the backfill made the pre-existing note searchable.
        let q = try DatabaseQueue()
        var m = DatabaseMigrator()
        registerMigrationV1(on: &m); registerMigrationV2(on: &m); registerMigrationV3(on: &m)
        registerMigrationV4(on: &m); registerMigrationV5(on: &m); registerMigrationV6(on: &m)
        registerMigrationV7(on: &m); registerMigrationV8(on: &m); registerMigrationV9(on: &m)
        registerMigrationV10(on: &m); registerMigrationV11(on: &m)
        try m.migrate(q)
        try q.write { db in
            try db.execute(sql: "INSERT INTO notebooks(name, description, created_at, updated_at) VALUES ('NB','',datetime('now'),datetime('now'))")
            let nbId = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO notes(notebook_id, title, body_md, origin, created_at, updated_at)
                VALUES (?, 'Legacy', 'photosynthesis chloroplast', 'manual', datetime('now'), datetime('now'))
                """, arguments: [nbId])
        }
        var m2 = m
        registerMigrationV12(on: &m2)
        try m2.migrate(q)
        try q.read { db in
            let hits = try Int.fetchOne(db, sql: "SELECT count(*) FROM notes_fts WHERE notes_fts MATCH 'chloroplast'")
            XCTAssertEqual(hits, 1, "pre-existing note must be backfilled into notes_fts")
        }
    }

    // MARK: v13 — instructions, message model, source sets

    func testV13AddsInstructionsAndMessageModelAndSourceSets() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            XCTAssertTrue(try columnNames(db, table: "notebooks").contains("instructions"))
            XCTAssertTrue(try columnNames(db, table: "messages").contains("model"))
            XCTAssertEqual(try columnNames(db, table: "source_sets"), ["id", "notebook_id", "name", "created_at"])
            XCTAssertEqual(try columnNames(db, table: "source_set_members"), ["set_id", "source_id"])
        }
    }

    func testV13InstructionsDefaultsToEmptyString() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        try store.runOnDatabase { db in
            let instr = try String.fetchOne(db, sql: "SELECT instructions FROM notebooks WHERE id = ?", arguments: [nb.id])
            XCTAssertEqual(instr, "")
        }
    }

    // MARK: v14 — chunk context

    func testV14AddsChunkContextColumn() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            XCTAssertTrue(try columnNames(db, table: "source_chunks").contains("context"))
        }
    }

    // MARK: v15 — live source columns

    func testV15AddsLiveSourceColumns() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let cols = try columnNames(db, table: "sources")
            XCTAssertTrue(cols.contains("last_synced_at"))
            XCTAssertTrue(cols.contains("content_hash"))
        }
    }
}

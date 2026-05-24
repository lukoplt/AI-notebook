import Foundation
import GRDB

extension NotebookStore {

    @discardableResult
    public func createNote(
        notebookId: Int64,
        title: String,
        bodyMd: String,
        origin: NoteOrigin = .manual,
        originRef: Int64? = nil
    ) throws -> Note {
        let now = Date()
        var note = Note(
            notebookId: notebookId,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            bodyMd: bodyMd,
            origin: origin,
            originRef: originRef,
            createdAt: now,
            updatedAt: now
        )
        try runOnDatabase { db in
            try note.insert(db)
        }
        if let id = note.id, let hook = onNoteSaved {
            Task { await hook(id) }
        }
        return note
    }

    public func notes(notebookId: Int64) throws -> [Note] {
        try runOnDatabase { db in
            try Note
                .filter(Note.Columns.notebookId.column == notebookId)
                .order(Note.Columns.updatedAt.column.desc)
                .fetchAll(db)
        }
    }

    public func note(id: Int64) throws -> Note? {
        try runOnDatabase { db in
            try Note.fetchOne(db, key: id)
        }
    }

    public func updateNote(id: Int64, title: String, bodyMd: String) throws {
        try runOnDatabase { db in
            guard var n = try Note.fetchOne(db, key: id) else { return }
            n.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            n.bodyMd = bodyMd
            n.updatedAt = Date()
            try n.update(db)
        }
        if let hook = onNoteSaved {
            Task { await hook(id) }
        }
    }

    public func deleteNote(id: Int64) throws {
        let uuid: String? = try runOnDatabase { db in
            try String.fetchOne(
                db,
                sql: "SELECT note_uuid FROM notes WHERE id = ?",
                arguments: [id]
            )
        }
        try runOnDatabase { db in
            _ = try Note.deleteOne(db, key: id)
        }
        if let uuid, let hook = onNoteDeleted {
            Task { await hook(uuid) }
        }
    }

    public func linkNoteToShadowSource(noteId: Int64, sourceId: Int64) throws {
        try runOnDatabase { db in
            try db.execute(
                sql: "UPDATE notes SET auto_source_id = ? WHERE id = ?",
                arguments: [sourceId, noteId]
            )
        }
    }
}

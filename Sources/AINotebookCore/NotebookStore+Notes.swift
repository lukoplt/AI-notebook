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
    }

    public func deleteNote(id: Int64) throws {
        try runOnDatabase { db in
            _ = try Note.deleteOne(db, key: id)
        }
    }
}

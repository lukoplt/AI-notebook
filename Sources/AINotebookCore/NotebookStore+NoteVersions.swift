import Foundation
import GRDB

extension NotebookStore {

    public static let noteVersionCap: Int = 50

    public func noteVersions(noteId: Int64) throws -> [NoteVersion] {
        try runOnDatabase { db in
            try NoteVersion
                .filter(NoteVersion.Columns.noteId.column == noteId)
                .order(NoteVersion.Columns.savedAt.column.asc)
                .fetchAll(db)
        }
    }

    @discardableResult
    public func snapshotNoteVersion(noteId: Int64, reason: NoteVersionReason) throws -> NoteVersion? {
        guard let note = try note(id: noteId) else { return nil }
        var version = NoteVersion(
            noteId: noteId,
            title: note.title,
            bodyMd: note.bodyMd,
            savedAt: Date(),
            reason: reason
        )
        try runOnDatabase { db in
            try version.insert(db)
            try Self.pruneIfNeeded(db: db, noteId: noteId)
        }
        return version
    }

    public func restoreNoteVersion(versionId: Int64) throws {
        var resolvedNoteId: Int64 = 0
        try runOnDatabase { db in
            guard let v = try NoteVersion.fetchOne(db, key: versionId) else { return }
            resolvedNoteId = v.noteId
            if let current = try Note.fetchOne(db, key: v.noteId) {
                var restoreSnap = NoteVersion(
                    noteId: v.noteId,
                    title: current.title,
                    bodyMd: current.bodyMd,
                    savedAt: Date(),
                    reason: .restore
                )
                try restoreSnap.insert(db)
                try Self.pruneIfNeeded(db: db, noteId: v.noteId)
            }
            try db.execute(
                sql: "UPDATE notes SET title = ?, body_md = ?, updated_at = ? WHERE id = ?",
                arguments: [v.title, v.bodyMd, Date(), v.noteId]
            )
        }
        if resolvedNoteId != 0, let hook = onNoteSaved {
            Task { await hook(resolvedNoteId) }
        }
    }

    static func pruneIfNeeded(db: Database, noteId: Int64) throws {
        let total: Int = try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM note_versions WHERE note_id = ?",
            arguments: [noteId]
        ) ?? 0
        let cap = NotebookStore.noteVersionCap
        if total > cap {
            try db.execute(
                sql: """
                DELETE FROM note_versions
                WHERE id IN (
                  SELECT id FROM note_versions
                  WHERE note_id = ?
                  ORDER BY saved_at ASC
                  LIMIT ?
                )
                """,
                arguments: [noteId, total - cap]
            )
        }
    }
}

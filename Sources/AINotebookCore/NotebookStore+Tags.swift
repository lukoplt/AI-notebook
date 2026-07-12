import Foundation
import GRDB

/// Tag CRUD + note/source tag assignment (Epic B, FR-B8). Ported from the
/// Windows `NotebookStore.Tags` partial. Tag names are trimmed and de-duped
/// via the `tags.name UNIQUE` constraint (upsert on conflict).
extension NotebookStore {

    /// All tags, alphabetical.
    public func tags() throws -> [Tag] {
        try runOnDatabase { db in
            try Row.fetchAll(db, sql: "SELECT id, name FROM tags ORDER BY name ASC")
                .map { Tag(id: $0["id"], name: $0["name"]) }
        }
    }

    /// Creates the tag, or returns the existing row if the (trimmed) name is
    /// already taken. Mirrors the Windows upsert-then-select.
    @discardableResult
    public func createTag(name: String) throws -> Tag {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidTagName(name) }
        return try runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO tags(name) VALUES(?) ON CONFLICT(name) DO UPDATE SET name=excluded.name",
                arguments: [trimmed]
            )
            let id = try Int64.fetchOne(db, sql: "SELECT id FROM tags WHERE name=?", arguments: [trimmed])!
            return Tag(id: id, name: trimmed)
        }
    }

    public func deleteTag(id: Int64) throws {
        try runOnDatabase { db in
            try db.execute(sql: "DELETE FROM tags WHERE id=?", arguments: [id])
        }
    }

    public func setNoteTags(noteId: Int64, tagIds: [Int64]) throws {
        try runOnDatabase { db in
            try db.execute(sql: "DELETE FROM note_tags WHERE note_id=?", arguments: [noteId])
            for tid in tagIds {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO note_tags(note_id, tag_id) VALUES(?, ?)",
                    arguments: [noteId, tid]
                )
            }
        }
    }

    public func setSourceTags(sourceId: Int64, tagIds: [Int64]) throws {
        try runOnDatabase { db in
            try db.execute(sql: "DELETE FROM source_tags WHERE source_id=?", arguments: [sourceId])
            for tid in tagIds {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO source_tags(source_id, tag_id) VALUES(?, ?)",
                    arguments: [sourceId, tid]
                )
            }
        }
    }

    public func tagsForNote(noteId: Int64) throws -> [Tag] {
        try runOnDatabase { db in
            try Row.fetchAll(
                db,
                sql: "SELECT t.id, t.name FROM tags t JOIN note_tags nt ON nt.tag_id=t.id WHERE nt.note_id=? ORDER BY t.name",
                arguments: [noteId]
            ).map { Tag(id: $0["id"], name: $0["name"]) }
        }
    }

    public func tagsForSource(sourceId: Int64) throws -> [Tag] {
        try runOnDatabase { db in
            try Row.fetchAll(
                db,
                sql: "SELECT t.id, t.name FROM tags t JOIN source_tags st ON st.tag_id=t.id WHERE st.source_id=? ORDER BY t.name",
                arguments: [sourceId]
            ).map { Tag(id: $0["id"], name: $0["name"]) }
        }
    }
}

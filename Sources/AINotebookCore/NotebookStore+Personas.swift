import Foundation
import GRDB

/// Persona CRUD (Epic C5). Ported to Windows as `NotebookStore.Personas`.
extension NotebookStore {

    public func personas(notebookId: Int64) throws -> [Persona] {
        try runOnDatabase { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, notebook_id, name, instructions, source_set_id, model, created_at FROM personas WHERE notebook_id=? ORDER BY name ASC",
                arguments: [notebookId]
            ).map(Self.persona(from:))
        }
    }

    @discardableResult
    public func createPersona(
        notebookId: Int64,
        name: String,
        instructions: String = "",
        sourceSetId: Int64? = nil,
        model: String? = nil
    ) throws -> Persona {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidPersonaName(name) }
        let now = Date()
        return try runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO personas(notebook_id, name, instructions, source_set_id, model, created_at) VALUES(?,?,?,?,?,?)",
                arguments: [notebookId, trimmed, instructions, sourceSetId, model, now]
            )
            return Persona(id: db.lastInsertedRowID, notebookId: notebookId, name: trimmed,
                           instructions: instructions, sourceSetId: sourceSetId, model: model, createdAt: now)
        }
    }

    public func updatePersona(_ persona: Persona) throws {
        try runOnDatabase { db in
            try db.execute(
                sql: "UPDATE personas SET name=?, instructions=?, source_set_id=?, model=? WHERE id=?",
                arguments: [persona.name, persona.instructions, persona.sourceSetId, persona.model, persona.id]
            )
        }
    }

    public func deletePersona(id: Int64) throws {
        try runOnDatabase { db in
            try db.execute(sql: "DELETE FROM personas WHERE id=?", arguments: [id])
        }
    }

    private static func persona(from row: Row) -> Persona {
        Persona(
            id: row["id"],
            notebookId: row["notebook_id"],
            name: row["name"],
            instructions: row["instructions"],
            sourceSetId: row["source_set_id"],
            model: row["model"],
            createdAt: row["created_at"]
        )
    }
}

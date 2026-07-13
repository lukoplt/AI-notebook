using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    public IReadOnlyList<Persona> Personas(long notebookId) =>
        Connection.Query(
            "SELECT id, notebook_id, name, instructions, source_set_id, model, created_at FROM personas WHERE notebook_id=$nb ORDER BY name ASC",
            new { nb = notebookId })
            .Select(r => new Persona(
                (long)r.id,
                (long)r.notebook_id,
                (string)r.name,
                (string)r.instructions,
                r.source_set_id is null ? (long?)null : (long)r.source_set_id,
                r.model is null ? null : (string)r.model,
                SqliteDate.FromDb((string)r.created_at)))
            .ToList();

    public Persona CreatePersona(long notebookId, string name, string instructions = "",
        long? sourceSetId = null, string? model = null)
    {
        var trimmed = name.Trim();
        var now = Now();
        var id = Connection.ExecuteScalar<long>(
            """
            INSERT INTO personas(notebook_id, name, instructions, source_set_id, model, created_at)
            VALUES($nb, $name, $instructions, $setId, $model, $created);
            SELECT last_insert_rowid();
            """,
            new { nb = notebookId, name = trimmed, instructions, setId = sourceSetId, model, created = SqliteDate.ToDb(now) });
        return new Persona(id, notebookId, trimmed, instructions, sourceSetId, model, now);
    }

    public void UpdatePersona(Persona persona) =>
        Connection.Execute(
            "UPDATE personas SET name=$name, instructions=$instructions, source_set_id=$setId, model=$model WHERE id=$id",
            new { name = persona.Name.Trim(), instructions = persona.Instructions, setId = persona.SourceSetId, model = persona.Model, id = persona.Id });

    public void DeletePersona(long id) =>
        Connection.Execute("DELETE FROM personas WHERE id=$id", new { id });
}

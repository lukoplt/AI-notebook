using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    private const string TransformationCols =
        "id, name, prompt_template, scope, is_builtin, description";

    private static Transformation MapTransformation(dynamic r) => new Transformation(
        (long)r.id, (string)r.name, (string)r.prompt_template,
        TransformationScopeExtensions.FromDb((string)r.scope),
        ((long)r.is_builtin) != 0, (string)r.description);

    public Transformation CreateTransformation(string name, string promptTemplate,
        TransformationScope scope, bool isBuiltin = false, string description = "")
    {
        var id = Connection.ExecuteScalar<long>(
            """
            INSERT INTO transformations(name, prompt_template, scope, is_builtin, description)
            VALUES($name, $prompt, $scope, $builtin, $desc);
            SELECT last_insert_rowid();
            """,
            new { name, prompt = promptTemplate, scope = scope.ToDb(), builtin = isBuiltin ? 1 : 0, desc = description });
        return new Transformation(id, name, promptTemplate, scope, isBuiltin, description);
    }

    public IReadOnlyList<Transformation> Transformations() =>
        Connection.Query(
            $"SELECT {TransformationCols} FROM transformations ORDER BY is_builtin DESC, name ASC")
            .Select(r => (Transformation)MapTransformation(r)).ToList();

    public void UpdateTransformation(long id, string name, string promptTemplate, string description = "") =>
        Connection.Execute(
            "UPDATE transformations SET name=$name, prompt_template=$prompt, description=$desc WHERE id=$id",
            new { name, prompt = promptTemplate, desc = description, id });

    public void UpdateTransformationScope(long id, TransformationScope scope) =>
        Connection.Execute("UPDATE transformations SET scope=$scope WHERE id=$id",
            new { scope = scope.ToDb(), id });

    public void DeleteTransformation(long id) =>
        Connection.Execute("DELETE FROM transformations WHERE id=$id", new { id });

    public TransformationRun RecordTransformationRun(long transformationId, long? sourceId, long? resultNoteId)
    {
        var ranAt = DateTime.UtcNow;
        var id = Connection.ExecuteScalar<long>(
            """
            INSERT INTO transformation_runs(transformation_id, source_id, result_note_id, ran_at)
            VALUES($tid, $sid, $nid, $ran);
            SELECT last_insert_rowid();
            """,
            new { tid = transformationId, sid = sourceId, nid = resultNoteId, ran = SqliteDate.ToDb(ranAt) });
        return new TransformationRun(id, transformationId, sourceId, resultNoteId, ranAt);
    }

    public IReadOnlyList<TransformationRun> TransformationRuns() =>
        Connection.Query(
            "SELECT id, transformation_id, source_id, result_note_id, ran_at FROM transformation_runs ORDER BY ran_at DESC")
            .Select(r => new TransformationRun(
                (long)r.id, (long)r.transformation_id,
                r.source_id is null ? (long?)null : (long)r.source_id,
                r.result_note_id is null ? (long?)null : (long)r.result_note_id,
                SqliteDate.FromDb((string)r.ran_at)))
            .ToList();
}

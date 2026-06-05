namespace AINotebook.Core.Models;

public enum TransformationScope { Source, Notebook }

public static class TransformationScopeExtensions
{
    public static string RawValue(this TransformationScope scope) => scope switch
    {
        TransformationScope.Source => "source",
        TransformationScope.Notebook => "notebook",
        _ => throw new ArgumentOutOfRangeException(nameof(scope), scope, null)
    };

    public static TransformationScope FromRawValue(string raw) => raw switch
    {
        "source" => TransformationScope.Source,
        "notebook" => TransformationScope.Notebook,
        _ => throw new ArgumentOutOfRangeException(nameof(raw), raw, "Unknown TransformationScope raw value")
    };

    // DB-mapper aliases (consumed by NotebookStore partials in Tasks 7-11).
    public static string ToDb(this TransformationScope v) => v.RawValue();
    public static TransformationScope FromDb(string raw) => FromRawValue(raw);
}

public record Transformation(
    long? Id,
    string Name,
    string PromptTemplate,
    TransformationScope Scope,
    bool IsBuiltin,
    string Description);

public record TransformationRun(
    long? Id,
    long TransformationId,
    long? SourceId,
    long? ResultNoteId,
    DateTime RanAt);

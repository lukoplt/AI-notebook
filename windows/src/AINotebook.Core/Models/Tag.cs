namespace AINotebook.Core.Models;

public record Tag(long Id, string Name);

public record SourceSet(long Id, long NotebookId, string Name, DateTime CreatedAt);

// Epic C5 — a named chat preset: instructions + optional source set + model.
public record Persona(
    long Id,
    long NotebookId,
    string Name,
    string Instructions,
    long? SourceSetId,
    string? Model,
    DateTime CreatedAt);

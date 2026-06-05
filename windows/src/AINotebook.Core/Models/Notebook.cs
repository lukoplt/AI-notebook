namespace AINotebook.Core.Models;

public record Notebook(
    long? Id,
    string Name,
    string Description,
    DateTime CreatedAt,
    DateTime UpdatedAt);

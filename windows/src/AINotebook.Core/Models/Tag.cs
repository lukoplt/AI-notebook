namespace AINotebook.Core.Models;

public record Tag(long Id, string Name);

public record SourceSet(long Id, long NotebookId, string Name, DateTime CreatedAt);

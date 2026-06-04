namespace AINotebook.Core.Models;

public sealed record RetrievalHit(long ChunkId, long SourceId, float Score, string Snippet);

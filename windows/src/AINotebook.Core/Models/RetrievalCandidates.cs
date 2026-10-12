namespace AINotebook.Core.Models;

public sealed record RetrievalCandidates(IReadOnlyList<RetrievalHit> Lexical,
    IReadOnlyList<RetrievalHit> Vector, IReadOnlyList<RetrievalHit> Fused);

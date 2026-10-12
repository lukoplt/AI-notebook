namespace AINotebook.Core.Eval;

public sealed record EvalEvidence(long ChunkId, EvalSpan Span, string Text);

/// <summary>Returns actual retained canonical spans, including any truncated prefix end.</summary>
public delegate Task<IReadOnlyList<EvalSpan>> EvalPackHook(EvalQuestion question,
    IReadOnlyList<EvalEvidence> candidates, CancellationToken ct);

public sealed record EvalMetric(string Status, int? Found, int? Total, int? RecallBp)
{
    public static EvalMetric Unavailable { get; } = new("not_available", null, null, null);
    public static EvalMetric NotApplicable { get; } = new("not_applicable", 0, 0, null);
}

public static class EvalMetrics
{
    public static IReadOnlyList<string> Names { get; } = Array.AsReadOnly(new[]
    {
        "lexical_recall_at_top_k", "lexical_recall_at_fetch_k", "hybrid_recall_at_top_k",
        "candidate_recall_at_fetch_k", "packed_evidence_recall"
    });

    public static EvalMetric Recall(IReadOnlyList<EvalSpan> gold, IReadOnlyList<EvalSpan> evidence)
    {
        if (gold.Count == 0) return EvalMetric.NotApplicable;
        var found = gold.Count(g => evidence.Any(e => e.DocumentId == g.DocumentId &&
            e.ContentHash == g.ContentHash && e.Start <= g.Start && e.End >= g.End));
        return new("measured", found, gold.Count, checked((int)(10000L * found / gold.Count)));
    }

    public static EvalMetric Aggregate(IEnumerable<EvalMetric> metrics)
    {
        var all = metrics.ToArray();
        var measured = all.Where(m => m.Status == "measured").ToArray();
        var found = measured.Sum(m => m.Found ?? 0);
        var total = measured.Sum(m => m.Total ?? 0);
        if (total > 0) return new("measured", found, total, checked((int)(10000L * found / total)));
        return all.Any(m => m.Status == "not_available") ? EvalMetric.Unavailable : EvalMetric.NotApplicable;
    }

    public static IReadOnlyDictionary<string, EvalMetric> Measure(IReadOnlyList<EvalSpan> gold,
        IReadOnlyList<EvalSpan> lexical, IReadOnlyList<EvalSpan> fused, int topK,
        bool includeVectors, IReadOnlyList<EvalSpan>? packed)
    {
        if (topK <= 0) throw new EvalFailure("invalid_top_k");
        return new Dictionary<string, EvalMetric>(StringComparer.Ordinal)
        {
            ["lexical_recall_at_top_k"] = Recall(gold, lexical.Take(topK).ToArray()),
            ["lexical_recall_at_fetch_k"] = Recall(gold, lexical),
            ["hybrid_recall_at_top_k"] = includeVectors ? Recall(gold, fused.Take(topK).ToArray()) : EvalMetric.Unavailable,
            ["candidate_recall_at_fetch_k"] = Recall(gold, fused),
            ["packed_evidence_recall"] = packed is null ? EvalMetric.Unavailable : Recall(gold, packed)
        };
    }
}

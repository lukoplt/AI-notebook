using System.Text;

namespace AINotebook.Core.Rag;

public interface IContextTokenEstimator
{
    int Version { get; }
    int Estimate(string text, string language);
}

/// <summary>The pinned scalar-based development estimator from folder-rag-v1 §12.</summary>
public sealed class PlaceholderTokenEstimatorV1 : IContextTokenEstimator
{
    public int Version => 1;

    public int Estimate(string text, string language)
    {
        if (text is null || language is null) throw new ContextPackException("invalidInput");
        long divisor = language == "en" ? 4 : 3;
        long basis = checked(text.EnumerateRunes().LongCount() + divisor - 1) / divisor;
        return checked((int)((basis * (10_000L + RagContractV1.Pack.TokenEstimateHeadroomBp)
            + 9_999) / 10_000));
    }
}

/// <summary>Pure integer selection and allocation kernels shared with the Swift packer.</summary>
public static class ContextPackAlgorithms
{
    private const long MaxJsonInteger = 9_007_199_254_740_991;

    public static int CompareScalars(string a, string b)
    {
        if (a is null || b is null) throw new ContextPackException("invalidInput");
        var left = a.EnumerateRunes().GetEnumerator();
        var right = b.EnumerateRunes().GetEnumerator();
        while (true)
        {
            bool hasLeft = left.MoveNext(), hasRight = right.MoveNext();
            if (!hasLeft || !hasRight) return hasLeft.CompareTo(hasRight);
            int order = left.Current.Value.CompareTo(right.Current.Value);
            if (order != 0) return order;
        }
    }

    public static PackPassage[] Diversity(IReadOnlyList<PackPassage> passages, bool singleSource)
    {
        if (passages is null) throw new ContextPackException("invalidInput");
        var remaining = passages.ToList();
        foreach (var passage in remaining) ValidateSelectionPassage(passage);
        var counts = new Dictionary<long, int>();
        var output = new List<PackPassage>(remaining.Count);
        long penalty = singleSource ? 10_000 : RagContractV1.Pack.DiversityPenaltyBp;

        long Effective(PackPassage passage)
        {
            long score = passage.RrfMicro;
            for (int n = 0; n < counts.GetValueOrDefault(passage.SourceId); n++)
                score = checked(score * penalty) / 10_000;
            return score;
        }

        while (remaining.Count > 0)
        {
            var next = remaining.OrderByDescending(Effective).ThenBy(p => p.ChunkId).First();
            remaining.Remove(next);
            output.Add(next);
            counts[next.SourceId] = checked(counts.GetValueOrDefault(next.SourceId) + 1);
        }
        return output.ToArray();
    }

    public static PackPassage[] OverviewOrder(IReadOnlyList<PackPassage> passages)
    {
        if (passages is null) throw new ContextPackException("invalidInput");
        var snapshot = passages.ToArray();
        var sources = new HashSet<long>();
        foreach (var passage in snapshot)
        {
            ValidateSelectionPassage(passage);
            // The caller pins publication; this DTO carries the actual hydrated revision.
            if (passage.Ordinal != 0 || passage.RelPath is null || !sources.Add(passage.SourceId))
                throw new ContextPackException("invalidInput");
        }

        var scalarComparer = Comparer<string>.Create(CompareScalars);
        var groups = snapshot
            .GroupBy(p => (p.FolderId, Directory: DirectoryOf(p.RelPath)))
            .OrderBy(g => g.Key.FolderId)
            .ThenBy(g => g.Key.Directory, scalarComparer)
            .Select(g => g.OrderBy(p => p.RelPath, scalarComparer)
                .ThenBy(p => p.SourceId).ThenBy(p => p.ChunkId).ToArray())
            .ToArray();
        var output = new List<PackPassage>(snapshot.Length);
        for (int round = 0; output.Count < snapshot.Length; round++)
            foreach (var group in groups)
                if (round < group.Length) output.Add(group[round]);
        return output.ToArray();
    }

    public static PackBudgetResult Budget(PackBudgetInput input, int evidenceShareBp = RagContractV1.Pack.EvidenceShareBp)
    {
        if (evidenceShareBp is < 0 or > 10_000) throw new ContextPackException("invalidInput");
        if (input is null || input.RuntimeContext <= 0 || input.MaxOutputTokens <= 0
            || input.MandatoryTokens < 0 || input.EvidenceBudgetCap is < 0 || input.TopK <= 0
            || input.MapTokensDesired < 0 || input.NoteWebTokensDesired < 0
            || input.MapCeilingTokens is < 0 || input.EvidenceCeilingTokens is < 0)
            throw new ContextPackException("invalidInput");

        // DTO getters return copies: take each collection exactly once for this operation.
        var passages = input.Passages;
        var history = input.HistoryTurnTokensNewestFirst;
        var prefixes = new Dictionary<long, PackBudgetPrefix[]>();
        foreach (var passage in passages)
        {
            if (passage is null || !IsJsonInteger(passage.Id) || passage.Tokens < 0
                || prefixes.ContainsKey(passage.Id))
                throw new ContextPackException("invalidInput");
            var candidates = passage.TruncationCandidates;
            long priorEnd = 0;
            int priorTokens = 0;
            foreach (var candidate in candidates)
            {
                if (candidate is null || candidate.EndScalar <= priorEnd
                    || !IsJsonInteger(candidate.EndScalar) || candidate.Tokens <= priorTokens
                    || candidate.Tokens >= passage.Tokens)
                    throw new ContextPackException("invalidInput");
                priorEnd = candidate.EndScalar;
                priorTokens = candidate.Tokens;
            }
            prefixes.Add(passage.Id, candidates);
        }
        if (history.Any(cost => cost < 0)) throw new ContextPackException("invalidInput");

        long available = checked((long)input.RuntimeContext - input.MaxOutputTokens);
        if (available <= 0 || input.MandatoryTokens > available)
            throw new ContextPackException("contextTooSmall");
        long remainder = checked(available - input.MandatoryTokens);
        long evidenceCap = input.EvidenceBudgetCap ?? int.MaxValue;
        // retrieval-paths v2 (§6, inventory questions only): the evidence target's upper bound.
        long evidenceTarget = Math.Min(Math.Min(Share(remainder, evidenceShareBp), evidenceCap),
            input.EvidenceCeilingTokens ?? long.MaxValue);
        int limit = Math.Min(input.TopK, RagContractV1.Pack.MaxPassages);
        var included = new HashSet<long>();
        long used = 0;
        long? truncatedId = null, truncatedEnd = null;
        int? truncatedTokens = null;

        void FillEvidence(long ceiling)
        {
            if (evidenceTarget == 0) return;
            foreach (var passage in passages)
            {
                if (included.Count == limit) break;
                if (included.Contains(passage.Id) || passage.Tokens > ceiling - used) continue;
                included.Add(passage.Id);
                used = checked(used + passage.Tokens);
            }
        }

        if (evidenceTarget > 0 && passages.Length > 0 && passages[0].Tokens > evidenceTarget)
        {
            var first = passages[0];
            var prefix = prefixes[first.Id].LastOrDefault(p => p.Tokens <= evidenceTarget);
            if (prefix is not null)
            {
                included.Add(first.Id);
                used = prefix.Tokens;
                truncatedId = first.Id;
                truncatedEnd = prefix.EndScalar;
                truncatedTokens = prefix.Tokens;
            }
        }
        FillEvidence(evidenceTarget);

        long mapCeiling = Math.Min(input.MapTokensDesired,
            input.MapCeilingTokens ?? Share(remainder, RagContractV1.Pack.MapMaxShareBp));
        long map = mapCeiling;
        long external = Math.Min(input.NoteWebTokensDesired, Share(remainder, RagContractV1.Pack.NoteWebMaxShareBp));
        int historyCount = 0;
        long historyTokens = 0;

        void FillHistory(long ceiling)
        {
            while (historyCount < history.Length)
            {
                int cost = history[historyCount];
                if (cost > ceiling - historyTokens) break;
                historyTokens = checked(historyTokens + cost);
                historyCount++;
            }
        }

        FillHistory(checked(remainder - used - map - external));
        long left = checked(remainder - used - map - external - historyTokens);
        FillEvidence(Math.Min(checked(used + left), evidenceCap));
        left = checked(remainder - used - map - external - historyTokens);
        FillHistory(checked(historyTokens + left));
        left = checked(remainder - used - map - external - historyTokens);
        long mapExtra = Math.Min(left, mapCeiling - map);
        map = checked(map + mapExtra);
        left = checked(left - mapExtra);

        return new PackBudgetResult(checked((int)remainder), checked((int)evidenceTarget),
            passages.Where(p => included.Contains(p.Id)).Select(p => p.Id).ToArray(),
            truncatedId, truncatedEnd, truncatedTokens, checked((int)used), checked((int)map),
            checked((int)external), historyCount, checked((int)historyTokens), checked((int)left));
    }

    private static string DirectoryOf(string path)
    {
        int slash = path.LastIndexOf('/');
        return slash < 0 ? "" : path[..slash];
    }

    private static long Share(long total, int basisPoints) => checked(total * basisPoints) / 10_000;
    private static bool IsJsonInteger(long value) => value is >= 0 and <= MaxJsonInteger;

    private static void ValidateSelectionPassage(PackPassage? passage)
    {
        if (passage is null || !IsJsonInteger(passage.ChunkId) || !IsJsonInteger(passage.SourceId)
            || !IsJsonInteger(passage.RevisionId) || passage.FolderId is { } folder && !IsJsonInteger(folder)
            || passage.RrfMicro is < 0 or > 2_000_000)
            throw new ContextPackException("invalidInput");
    }
}

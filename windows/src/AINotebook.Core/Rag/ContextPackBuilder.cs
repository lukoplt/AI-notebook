using System.Diagnostics.CodeAnalysis;
using System.Globalization;
using System.Text;
using static AINotebook.Core.Rag.ContextPackRendering;

namespace AINotebook.Core.Rag;

/// <summary>Builds a deterministic request from an already scoped and hydrated snapshot.</summary>
public static class ContextPackBuilder
{
    private const long MaxId = 9_007_199_254_740_991;
    private static readonly HashSet<string> Languages = ["en", "cs", "sk", "de", "und", "mixed"];

    public static PreparedContextRequest Build(ContextPackInput input, IContextTokenEstimator? estimator = null,
        RagRuntimeTuning? tuning = null)
    {
        // Resolved once; only the evidence share comes from tuning. Input fetchK/topK stay explicit.
        tuning ??= RagRuntimeTuning.Bundled();
        // Production default: estimator v2 (benchmark-v1 §4). Without a proven digest this is the explicitly
        // uncalibrated UTF-8 fallback; historical v1 output stays available by passing PlaceholderTokenEstimatorV1.
        estimator = new ValidatedEstimator(estimator ?? TokenEstimatorV2.Bundled(input?.Model?.Model ?? string.Empty));
        try
        {
            Validate(input, estimator);
            return BuildValidated(input, estimator, tuning.EvidenceShareBp);
        }
        catch (OverflowException) { throw Invalid(); }
    }

    private static PreparedContextRequest BuildValidated(ContextPackInput input, IContextTokenEstimator estimator, int evidenceShareBp)
    {
        bool empty = input.Scope.Kind == "selection" && input.Scope.SourceIds.Length == 0 && input.Scope.FolderIds.Length == 0;
        bool overview = input.Mode == "overview";
        var originalPassages = overview ? input.OverviewCandidates : input.Candidates;
        var originalFiles = originalPassages.Select(p => p.SourceId).Concat(input.FolderMap.Select(f => f.SourceId)).Distinct().Order().ToArray();
        if (empty) input = input with { Candidates = [], Neighbours = [], OverviewCandidates = [], FolderMap = [] };

        var system = ContextPackRendering.System(input, estimator);
        var question = Section("question", input.Question, estimator, label: "QUESTION");
        int reservedScope = Section("scope", ScopeBody(input, RagContractV1.Pack.MaxPassages, input.Coverage.FilesInScope), estimator).Tokens;
        int mandatory = checked((int)(8L + system.Sum(s => (long)s.Tokens) + question.Tokens + reservedScope));
        long remaining = (long)input.Model.RuntimeContext - input.Model.MaxOutputTokens - mandatory;
        if (remaining < 0 || input.Model.RuntimeContext <= input.Model.MaxOutputTokens)
            throw new ContextPackException("contextTooSmall");

        var pool = overview ? input.OverviewCandidates : input.Candidates;
        var duplicates = pool.GroupBy(p => p.ChunkId).Where(g => g.Count() > 1).Select(g => g.Key).Order().ToArray();
        var unique = pool.DistinctBy(p => p.ChunkId).ToArray();
        bool single = input.Scope.Kind == "selection" && input.Scope.SourceIds.Distinct().Count() == 1 && input.Scope.FolderIds.Length == 0;
        var direct = overview ? ContextPackAlgorithms.OverviewOrder(unique) : ContextPackAlgorithms.Diversity(unique, single);
        long mapCeiling = Share(remaining, RagContractV1.Pack.MapMaxShareBp);
        // retrieval-paths v2 (§6): an inventory question reserves a larger map share for its matches.
        bool inventory = input.PathInventory == true
            && input.FolderMap.Any(f => f.PathRank is not null && f.PublishedRevisionId is not null);
        var matchingBudget = inventory ? new MatchingBudget(Share(remaining, ContextPackInventory.MapShareBp),
            Share(remaining, ContextPackInventory.FloorMaxShareBp)) : null;
        var map = RenderMap(input, mapCeiling, direct, estimator, matchingBudget);
        int mapCost = map.Section?.Tokens ?? 0;
        long externalCeiling = Share(remaining, RagContractV1.Pack.NoteWebMaxShareBp);
        var externalOrder = input.External.OrderBy(e => e.Kind == "note" ? 0 : 1).ToArray();
        var externalSections = new List<PackSection>();
        var externalIds = new HashSet<string>(StringComparer.Ordinal);
        int externalCost = 0;
        foreach (var item in externalOrder)
        {
            var section = Section(item.Kind, item.Text, estimator, item.Language,
                item.Kind.ToUpperInvariant() + " — NOT CONTENT OF THE SELECTED FOLDER");
            if ((long)externalCost + section.Tokens > externalCeiling) continue;
            externalSections.Add(section);
            externalCost = checked(externalCost + section.Tokens);
            externalIds.Add(item.Id);
        }
        var history = input.History.Reverse().ToArray();
        var historyCosts = history.Select(h => checked(24 + estimator.Estimate(h.User, "und") + estimator.Estimate(h.Assistant, "und"))).ToArray();
        var budgetPassages = direct.Select(p => new PackBudgetPassage(p.ChunkId, EvidenceTokens(p, estimator),
            overview ? [] : Prefixes(p, estimator).Select(v => new PackBudgetPrefix(v.End - (p.Start ?? 0), v.Tokens)).ToArray())).ToArray();
        var selected = ContextPackAlgorithms.Budget(new(input.Model.RuntimeContext, input.Model.MaxOutputTokens,
            mandatory, input.EvidenceBudgetCap, input.TopK, budgetPassages, mapCost, externalCost, historyCosts,
            inventory ? mapCost : null, inventory ? checked((int)(remaining - mapCost - externalCost)) : null), evidenceShareBp);
        var selectedIds = selected.IncludedPassageIds.ToHashSet();
        int historyCount = selected.HistoryTurnsIncluded;
        long historyCost = selected.HistoryTokens;
        long ceiling = Math.Min(input.EvidenceBudgetCap ?? remaining, remaining - mapCost - externalCost - historyCost);
        var initial = new List<PackEvidenceBlock>();
        string? clipped = null;
        for (int rank = 0; rank < direct.Length; rank++)
        {
            var p = direct[rank];
            if (!selectedIds.Contains(p.ChunkId)) continue;
            bool truncated = p.ChunkId == selected.TruncatedPassageId;
            if (truncated)
            {
                long end = checked((p.Start ?? 0) + selected.TruncatedPassageEndScalar!.Value);
                p = Clip(p, end);
                clipped = Id(p.ChunkId) + ":" + Id(end);
            }
            initial.Add(Block(p, rank, truncated));
        }
        var blocks = MergeBlocks(initial, ceiling, estimator);
        bool TryAdd(PackPassage p, int rank)
        {
            var trial = MergeBlocks([.. blocks, Block(p, rank)], ceiling, estimator);
            if (trial.Length > RagContractV1.Pack.MaxPassages || trial.Sum(b => (long)EvidenceTokens(b, estimator)) > ceiling) return false;
            blocks = trial;
            return true;
        }
        int directLimit = Math.Min(input.TopK, RagContractV1.Pack.MaxPassages);
        if (selected.EvidenceTarget > 0)
            for (int rank = 0; rank < direct.Length && selectedIds.Count < directLimit; rank++)
                if (!selectedIds.Contains(direct[rank].ChunkId) && TryAdd(direct[rank], rank)) selectedIds.Add(direct[rank].ChunkId);

        var neighbourIds = new HashSet<long>();
        var neighbourReasons = new Dictionary<long, string>();
        var seenNeighbours = new HashSet<long>();
        var neighbours = input.Neighbours.OrderBy(n => n.ChunkId).ToArray();
        if (!overview)
            for (int rank = 0; rank < direct.Length; rank++)
            {
                var p = direct[rank];
                if (!selectedIds.Contains(p.ChunkId)) continue;
                foreach (int delta in new[] { -1, 1 })
                    foreach (var n in neighbours)
                    {
                        if (n.SourceId != p.SourceId || (long)n.Ordinal != (long)p.Ordinal + delta
                            || selectedIds.Contains(n.ChunkId) || seenNeighbours.Contains(n.ChunkId)) continue;
                        if (n.RevisionId != p.RevisionId || !input.SourceRevisions.TryGetValue(Id(p.SourceId), out long published) || published != p.RevisionId)
                        {
                            // An older manifest hit must not consume a published-revision neighbour's attempt.
                            neighbourReasons[n.ChunkId] = "revisionMismatch";
                            continue;
                        }
                        seenNeighbours.Add(n.ChunkId);
                        string reason = "neighbourBudget";
                        if (p.ChunkId == selected.TruncatedPassageId && (n.End is null || p.Start is null
                            || n.End > blocks.First(b => b.Members.Any(m => m.ChunkId == p.ChunkId)).Passage.End))
                            reason = "truncated";
                        else if (selected.EvidenceTarget > 0 && TryAdd(n, rank))
                        {
                            neighbourIds.Add(n.ChunkId);
                            continue;
                        }
                        neighbourReasons[n.ChunkId] = reason;
                    }
            }
        long used = blocks.Sum(b => (long)EvidenceTokens(b, estimator));
        while (historyCount < history.Length && historyCosts[historyCount] <= remaining - used - mapCost - externalCost - historyCost)
            historyCost = checked(historyCost + historyCosts[historyCount++]);

        var firstSource = new Dictionary<long, int>();
        for (int rank = 0; rank < direct.Length; rank++)
            if (selectedIds.Contains(direct[rank].ChunkId)) firstSource.TryAdd(direct[rank].SourceId, rank);
        blocks = blocks.OrderBy(b => firstSource[b.Passage.SourceId]).ThenBy(b => b.Rank)
            .ThenBy(b => b.Passage.Start ?? -1).ThenBy(b => b.Passage.ChunkId).ToArray();
        var citations = blocks.Select((b, i) => SnapshotCitation(b, i + 1)).ToArray();
        var includedFiles = blocks.Select(b => b.Passage.SourceId).ToHashSet();
        var sections = new List<PackSection> { Section("scope", ScopeBody(input, blocks.Length, includedFiles.Count), estimator, label: "SCOPE", tokens: reservedScope) };
        if (map.Section is not null) sections.Add(map.Section);
        sections.AddRange(blocks.Select((b, i) => new PackSection("evidence", "[" + Id(i + 1) + "] " + Metadata(b.Passage) + "\n" + b.Passage.Text
            + (b.Truncated ? "\n[truncated]" : ""), EvidenceTokens(b, estimator))));
        sections.AddRange(externalSections);
        sections.Add(question);
        var messages = new List<PackMessage> { new("system", system) };
        foreach (var h in history.Take(historyCount).Reverse())
        {
            messages.Add(new("user", [Section("history", h.User, estimator)]));
            messages.Add(new("assistant", [Section("history", h.Assistant, estimator)]));
        }
        messages.Add(new("user", sections.ToArray()));
        var included = new List<PackItem>();
        var omitted = new List<PackOmission>();
        void Ledger(string kind, string id, bool yes, string reason)
        {
            if (yes) included.Add(new(kind, id));
            else omitted.Add(new(kind, id, reason));
        }
        foreach (var p in empty ? originalPassages.OrderBy(p => p.ChunkId).ToArray() : direct)
            Ledger("passage", Id(p.ChunkId), selectedIds.Contains(p.ChunkId), empty ? "emptySelection" : selectedIds.Count >= directLimit ? "topK" : "evidenceBudget");
        foreach (long id in duplicates) Ledger("passage", Id(id), false, "duplicate");
        if (clipped is not null) Ledger("passage", clipped, false, "truncated");
        var fileOrder = direct.Select(p => p.SourceId).Distinct().ToArray();
        foreach (long sid in fileOrder.Concat(originalFiles.Except(fileOrder)))
            Ledger("file", Id(sid), includedFiles.Contains(sid), empty ? "emptySelection" : "evidenceBudget");
        var retainedHistory = history.Take(historyCount).Select(h => h.Id).ToHashSet();
        foreach (var h in input.History) Ledger("history", Id(h.Id), retainedHistory.Contains(h.Id), "historyBudget");
        foreach (var n in neighbours.DistinctBy(n => n.ChunkId).OrderBy(n => n.SourceId).ThenBy(n => n.Ordinal).ThenBy(n => n.ChunkId))
            if (!selectedIds.Contains(n.ChunkId)) Ledger("neighbour", Id(n.ChunkId), neighbourIds.Contains(n.ChunkId), neighbourReasons.GetValueOrDefault(n.ChunkId, "neighbourBudget"));
        foreach (var e in externalOrder) Ledger("external", e.Id, externalIds.Contains(e.Id), "externalBudget");
        foreach (string id in map.Included) Ledger("map", id, true, "mapBudget");
        foreach (string id in map.Omitted) Ledger("map", id, false, "mapBudget");
        var pairs = empty ? new HashSet<PackSourceRevision>() : input.SourceRevisions.Select(p => new PackSourceRevision(long.Parse(p.Key, CultureInfo.InvariantCulture), p.Value)).ToHashSet();
        foreach (var c in citations) pairs.Add(new(c.SourceId, c.RevisionId!.Value));
        var model = input.Model;
        var request = new PreparedContextRequest(estimator.Version, new(model.ProviderId, model.Model, model.RuntimeContext, model.MaxOutputTokens, model.ContextWindowKnown),
            messages.ToArray(), new(model.ProviderType == "ollama" ? model.RuntimeContext : null, model.MaxOutputTokens), citations,
            included.ToArray(), omitted.ToArray(), new(input.Coverage, new(blocks.Length, includedFiles.Count, input.OverviewCandidates.Length, overview)),
            input.GenerationId, pairs.OrderBy(p => p.SourceId).ThenBy(p => p.RevisionId).ToArray());
        if (messages.Sum(m => 4L + m.Sections.Sum(s => (long)s.Tokens)) > (long)model.RuntimeContext - model.MaxOutputTokens) throw Invalid();
        return request;
    }

    private static void Validate([NotNull] ContextPackInput? x, IContextTokenEstimator estimator)
    {
        if (x is null || x.Model is null || x.Scope is null || x.Coverage is null || estimator.Version <= 0) throw Invalid();
        if (x.Model.RuntimeContext <= 0 || x.Model.MaxOutputTokens <= 0 || x.TopK <= 0 || x.FetchK < x.TopK || x.EvidenceBudgetCap is < 0
            || x.Mode is not ("answer" or "overview") || x.Model.ProviderType is not ("ollama" or "anthropic" or "openai" or "openai_compatible" or "openwebui")) throw Invalid();
        Text(x.Question); Text(x.UserInstructions); Text(x.Model.ProviderId); Text(x.Model.Model);
        if (x.GenerationId is long generation) Number(generation);
        var s = x.Scope;
        if (s.Kind is not ("all" or "selection") || s.Languages.Any(l => !Languages.Contains(l))) throw Invalid();
        Text(s.Name); Text(s.ScanState); if (s.LastFullScan is not null) Text(s.LastFullScan);
        foreach (long id in s.SourceIds.Concat(s.FolderIds)) Number(id);
        var c = x.Coverage;
        int[] counts = [c.FilesInScope, c.Searchable, c.Pending, c.Error, c.Skipped, c.Missing, c.Unavailable, c.RefreshPending, c.RefreshError];
        if (counts.Any(n => n < 0) || (long)c.Searchable + c.Pending + c.Error != c.FilesInScope || (long)c.RefreshPending + c.RefreshError > c.FilesInScope) throw Invalid();
        foreach (var pair in x.SourceRevisions)
        {
            if (!long.TryParse(pair.Key, NumberStyles.None, CultureInfo.InvariantCulture, out long sid) || Id(sid) != pair.Key) throw Invalid();
            Number(sid); Number(pair.Value);
        }
        var history = x.History;
        if (history.Any(h => h is null) || history.Select(h => h.Id).Distinct().Count() != history.Length) throw Invalid();
        foreach (var h in history) { Number(h.Id); Text(h.User); Text(h.Assistant); }
        var external = x.External;
        if (external.Any(e => e is null) || external.Select(e => e.Id).Distinct(StringComparer.Ordinal).Count() != external.Length || external.Count(e => e.Kind == "note") > 1) throw Invalid();
        foreach (var e in external)
        {
            Text(e.Id); Text(e.Text);
            if (e.Kind is not ("note" or "web") || !Languages.Contains(e.Language)) throw Invalid();
        }
        var all = x.Candidates.Concat(x.Neighbours).Concat(x.OverviewCandidates).ToArray();
        var files = x.FolderMap;
        if (all.Any(p => p is null) || files.Any(f => f is null)) throw Invalid();
        bool empty = s.Kind == "selection" && s.SourceIds.Length == 0 && s.FolderIds.Length == 0;
        if (!empty && all.Select(p => p.SourceId).Concat(files.Select(f => f.SourceId)).Distinct().Count() > c.FilesInScope) throw Invalid();
        foreach (var f in files)
        {
            MetadataValid(f.SourceId, f.FolderId, f.RelPath, f.DisplayName); Text(f.Descriptor);
            if (f.PublishedRevisionId is long revision)
            {
                Number(revision);
                if (!x.SourceRevisions.TryGetValue(Id(f.SourceId), out long published) || revision != published) throw Invalid();
            }
        }
        if (files.Select(f => f.SourceId).Distinct().Count() != files.Length) throw Invalid();
        var identities = new Dictionary<long, PackPassage>();
        foreach (var p in all)
        {
            MetadataValid(p.SourceId, p.FolderId, p.RelPath, p.DisplayName); Number(p.ChunkId); Number(p.RevisionId); Text(p.Text);
            if (p.Ordinal < 0 || p.RrfMicro is < 0 or > 2_000_000 || !Languages.Contains(p.Language) || p.PageFrom is < 0 || p.PageTo is < 0
                || p.PageFrom > p.PageTo || (p.Start is null) != (p.End is null)) throw Invalid();
            if (p.Start is long start)
            {
                Number(start); Number(p.End!.Value);
                if (p.End <= start || p.End - start != p.Text.EnumerateRunes().LongCount()) throw Invalid();
            }
            foreach (var prefix in p.TruncationCandidates)
            {
                if (prefix is null || prefix.Tokens <= 0) throw Invalid();
                Number(prefix.End);
            }
            _ = Prefixes(p, estimator);
            if (identities.TryGetValue(p.ChunkId, out var prior) && !SamePassage(prior, p)) throw Invalid();
            identities[p.ChunkId] = p;
        }
        foreach (var group in all.Where(p => p.Start is not null).GroupBy(p => (p.SourceId, p.RevisionId)))
        {
            var parts = group.OrderBy(p => p.Start).ToArray();
            for (int i = 0; i < parts.Length; i++)
                for (int j = i + 1; j < parts.Length && parts[j].Start < parts[i].End; j++)
                {
                    long lo = Math.Max(parts[i].Start!.Value, parts[j].Start!.Value), hi = Math.Min(parts[i].End!.Value, parts[j].End!.Value);
                    if (lo < hi && Slice(parts[i].Text, lo - parts[i].Start!.Value, hi - lo) != Slice(parts[j].Text, lo - parts[j].Start!.Value, hi - lo)) throw Invalid();
                }
        }
        var overviewSources = new HashSet<long>();
        foreach (var p in x.OverviewCandidates)
            if (!overviewSources.Add(p.SourceId) || p.Ordinal != 0 || !x.SourceRevisions.TryGetValue(Id(p.SourceId), out long published) || published != p.RevisionId) throw Invalid();
    }

    internal static bool SamePassage(PackPassage a, PackPassage b) =>
        (a.ChunkId, a.SourceId, a.RevisionId, a.FolderId, a.RelPath, a.DisplayName, a.Language, a.Text, a.Ordinal, a.Start, a.End, a.PageFrom, a.PageTo, a.RrfMicro)
        == (b.ChunkId, b.SourceId, b.RevisionId, b.FolderId, b.RelPath, b.DisplayName, b.Language, b.Text, b.Ordinal, b.Start, b.End, b.PageFrom, b.PageTo, b.RrfMicro)
        && a.TruncationCandidates.SequenceEqual(b.TruncationCandidates);
    private sealed class ValidatedEstimator(IContextTokenEstimator inner) : IContextTokenEstimator
    {
        public int Version { get; } = inner.Version;
        public int Estimate(string text, string language)
        {
            int cost = inner.Estimate(text, language);
            return cost >= 0 ? cost : throw Invalid();
        }
    }

    private static void MetadataValid(long sourceId, long? folderId, string path, string name)
    {
        Number(sourceId); if (folderId is long folder) Number(folder);
        Text(path); Text(name);
        if (path.Length == 0 || path.StartsWith('/') || path.Any(ch => ch is '\\' or ':' || ch < 32 || ch is >= (char)127 and <= (char)159)
            || path.Split('/').Any(part => part is "" or "." or "..")) throw Invalid();
        if (name.Length == 0 || name.Any(ch => ch is '/' or '\\' or ':' or '\0' || ch < 32 && ch is not ('\r' or '\n' or '\t') || ch is >= (char)127 and <= (char)159)) throw Invalid();
    }
    private static void Text(string? text)
    {
        if (text is null) throw Invalid();
        for (int i = 0; i < text.Length; i++)
            if (char.IsSurrogate(text[i]))
            {
                if (!char.IsHighSurrogate(text[i]) || i + 1 == text.Length || !char.IsLowSurrogate(text[++i])) throw Invalid();
            }
    }
    private static void Number(long n) { if (n is < 0 or > MaxId) throw Invalid(); }
    private static string Id(long n) => n.ToString(CultureInfo.InvariantCulture);
    private static long Share(long total, int bp) => checked(total * bp) / 10_000;
    private static ContextPackException Invalid() => new("invalidInput");
}

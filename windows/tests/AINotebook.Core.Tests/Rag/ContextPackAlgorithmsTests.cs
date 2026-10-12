using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public sealed class ContextPackAlgorithmsTests
{
    [Fact]
    public void EstimatorSharedCases()
    {
        var estimator = new PlaceholderTokenEstimatorV1();
        Assert.Equal(1, estimator.Version);
        var rows = ContextPackFixtures.Cases("estimate");
        Assert.Equal(8, rows.Length);
        foreach (var row in rows)
        {
            var input = row.GetProperty("input");
            int actual = estimator.Estimate(input.GetProperty("text").GetString()!,
                input.GetProperty("language").GetString()!);
            Assert.True(actual == row.GetProperty("expected").GetInt32(),
                row.GetProperty("name").GetString());
        }
    }

    [Fact]
    public void CorrectedBudgetSharedCases()
    {
        var rows = SharedFixtures.Json("contracts/budget-v1.json").GetProperty("cases");
        Assert.Equal(17, rows.GetArrayLength());
        foreach (var row in rows.EnumerateArray())
        {
            string name = row.GetProperty("name").GetString()!;
            var input = row.GetProperty("input").Deserialize<PackBudgetInput>(ContextPackFixtures.Options)!;
            var expected = row.GetProperty("expected");
            if (expected.TryGetProperty("error", out var error))
            {
                string code = Assert.Throws<ContextPackException>(() => ContextPackAlgorithms.Budget(input)).Code;
                Assert.True(code == error.GetString(), name);
            }
            else
            {
                var actual = ContextPackAlgorithms.Budget(input);
                var json = JsonSerializer.SerializeToElement(actual, ContextPackFixtures.Options);
                Assert.True(JsonElement.DeepEquals(expected, json), $"{name}: {json.GetRawText()}");
                Assert.True(actual.Remainder == actual.EvidenceTokens + actual.MapTokens
                    + actual.NoteWebTokens + actual.HistoryTokens + actual.UnusedTokens, name);
            }
        }
    }

    [Fact]
    public void ActualCostTruncationContinues()
    {
        var result = ContextPackAlgorithms.Budget(new(200, 20, 80, 60, 3,
            [new(1, 90, [new(12, 35), new(25, 65)]), new(2, 20, []), new(3, 70, [])], 0, 0, []));
        Assert.Equal(new long[] { 1, 2 }, result.IncludedPassageIds);
        Assert.Equal(1, result.TruncatedPassageId);
        Assert.Equal(12, result.TruncatedPassageEndScalar);
        Assert.Equal(35, result.TruncatedPassageTokens);
        Assert.Equal(55, result.EvidenceTokens);
        Assert.Equal(45, result.UnusedTokens);
    }

    [Fact]
    public void DiversitySharedCases()
    {
        var rows = SharedFixtures.Json("contracts/diversity-v1.json").GetProperty("cases");
        Assert.Equal(5, rows.GetArrayLength());
        foreach (var row in rows.EnumerateArray())
        {
            string name = row.GetProperty("name").GetString()!;
            int rrfK = row.GetProperty("rrfK").GetInt32();
            var passages = row.GetProperty("candidates").EnumerateArray().Select(candidate =>
            {
                long score = 0;
                foreach (string branch in new[] { "vectorRank", "ftsRank" })
                    if (candidate.GetProperty(branch).ValueKind != JsonValueKind.Null)
                        score += 1_000_000 / (rrfK + candidate.GetProperty(branch).GetInt32());
                Assert.True(score == candidate.GetProperty("rrfMicro").GetInt64(), name);
                return Passage(candidate.GetProperty("chunkId").GetInt64(),
                    candidate.GetProperty("sourceId").GetInt64(), score: score);
            }).ToArray();
            var expected = row.GetProperty("expectedOrder").EnumerateArray().Select(id => id.GetInt64());
            bool singleSource = row.GetProperty("singleSourceScope").GetBoolean();
            var actual = ContextPackAlgorithms.Diversity(passages, singleSource);
            Assert.True(expected.SequenceEqual(actual.Select(passage => passage.ChunkId)), name);
            Assert.True(expected.SequenceEqual(ContextPackAlgorithms.Diversity(passages.Reverse().ToArray(), singleSource)
                .Select(passage => passage.ChunkId)), $"{name}: permuted");
        }
    }

    [Fact]
    public void OverviewSharedCases()
    {
        var rows = SharedFixtures.Json("contracts/overview-v1.json").GetProperty("cases");
        Assert.Equal(7, rows.GetArrayLength());
        foreach (var row in rows.EnumerateArray())
        {
            string name = row.GetProperty("name").GetString()!;
            var files = row.GetProperty("files").EnumerateArray().ToArray();
            var published = files.Where(file => file.GetProperty("firstChunkId").ValueKind != JsonValueKind.Null).ToArray();
            var passages = published.Select(file => Passage(file.GetProperty("firstChunkId").GetInt64(),
                file.GetProperty("sourceId").GetInt64(),
                file.GetProperty("folderId").ValueKind == JsonValueKind.Null ? null : file.GetProperty("folderId").GetInt64(),
                file.GetProperty("relPath").GetString()!)).ToArray();
            var expected = row.GetProperty("expected");
            var order = ContextPackAlgorithms.OverviewOrder(passages);
            var visit = expected.GetProperty("visitOrder").EnumerateArray().Select(id => id.GetInt64()).ToArray();
            Assert.True(visit.SequenceEqual(order.Select(passage => passage.SourceId)), name);
            Assert.True(visit.SequenceEqual(ContextPackAlgorithms.OverviewOrder(passages.Reverse().ToArray())
                .Select(passage => passage.SourceId)), $"{name}: permuted");

            var costs = published.ToDictionary(file => file.GetProperty("sourceId").GetInt64(),
                file => file.GetProperty("firstChunkTokens").GetInt32());
            int remaining = row.GetProperty("evidenceBudget").GetInt32();
            int maxPassages = row.GetProperty("maxPassages").GetInt32();
            var included = new List<long>();
            foreach (var passage in order)
                if (included.Count < maxPassages && costs[passage.SourceId] <= remaining)
                {
                    included.Add(passage.SourceId);
                    remaining -= costs[passage.SourceId];
                }
            var actual = JsonSerializer.SerializeToElement(new
            {
                visitOrder = order.Select(passage => passage.SourceId).ToArray(),
                includedSourceIds = included,
                filesIncluded = included.Count,
                filesWithPublishedChunks = published.Length,
                filesInScope = files.Length,
                evidenceTokens = row.GetProperty("evidenceBudget").GetInt32() - remaining,
            });
            Assert.True(JsonElement.DeepEquals(expected, actual), $"{name}: {actual.GetRawText()}");
        }
    }

    [Fact]
    public void BudgetRejectsInvalidRangesAndPrefixOrdering()
    {
        var valid = new PackBudgetInput(200, 20, 80, null, 3,
            [new(1, 90, [new(12, 35), new(25, 65)])], 0, 0, []);
        PackBudgetInput[] invalid =
        [
            valid with { RuntimeContext = -1 },
            valid with { MaxOutputTokens = -1 },
            valid with { MandatoryTokens = -1 },
            valid with { EvidenceBudgetCap = -1 },
            valid with { TopK = 0 },
            valid with { MapTokensDesired = -1 },
            valid with { NoteWebTokensDesired = -1 },
            valid with { HistoryTurnTokensNewestFirst = [-1] },
            valid with { Passages = [new(-1, 90, [])] },
            valid with { Passages = [new(9_007_199_254_740_992, 90, [])] },
            valid with { Passages = [new(1, -1, [])] },
            valid with { Passages = [new(1, 90, [new(0, 20)])] },
            valid with { Passages = [new(1, 90, [new(9_007_199_254_740_992, 20)])] },
            valid with { Passages = [new(1, 90, [new(12, 0)])] },
            valid with { Passages = [new(1, 90, [new(12, 90)])] },
            valid with { Passages = [new(1, 90, [new(12, 35), new(12, 65)])] },
            valid with { Passages = [new(1, 90, [new(12, 65), new(25, 35)])] },
        ];
        foreach (var input in invalid)
            Assert.Equal("invalidInput", Assert.Throws<ContextPackException>(() => ContextPackAlgorithms.Budget(input)).Code);
    }

    [Fact]
    public void BudgetUsesWideIntermediatesAndAcceptsJsonSafeIds()
    {
        const long largestId = 9_007_199_254_740_991;
        var output = ContextPackAlgorithms.Budget(new(int.MaxValue, 1, 0, null, int.MaxValue,
            [new(largestId, 1, [])], int.MaxValue, int.MaxValue, []));
        Assert.Equal(int.MaxValue - 1, output.Remainder);
        Assert.Equal(new[] { largestId }, output.IncludedPassageIds);
        Assert.Equal(output.Remainder, (long)output.EvidenceTokens + output.MapTokens
            + output.NoteWebTokens + output.HistoryTokens + output.UnusedTokens);
    }

    [Fact]
    public void ScalarOrderingUsesCodePointsRatherThanUtf16()
    {
        Assert.True(ContextPackAlgorithms.CompareScalars("\uE000", "\U00010000") < 0);
        Assert.True(ContextPackAlgorithms.CompareScalars("a", "aa") < 0);
        Assert.Equal(0, ContextPackAlgorithms.CompareScalars("😀e\u0301", "😀e\u0301"));
        var ordered = ContextPackAlgorithms.OverviewOrder(
            [Passage(1, 1, path: "\U00010000.txt"), Passage(2, 2, path: "\uE000.txt")]);
        Assert.Equal(new long[] { 2, 1 }, ordered.Select(passage => passage.SourceId));
    }

    [Fact]
    public void InputAndBudgetCollectionsAreDefensiveCopies()
    {
        var input = ContextPackFixtures.Input("basic-cs");
        var candidates = input.Candidates;
        var original = candidates[0];
        var revisions = new Dictionary<string, long> { ["10"] = 11 };
        var copied = input with { Candidates = candidates, SourceRevisions = revisions };
        candidates[0] = original with { Text = "changed before read" };
        revisions["10"] = 999;
        Assert.Equal(original.Text, copied.Candidates[0].Text);
        Assert.Equal(11, copied.SourceRevisions["10"]);
        var returned = copied.Candidates;
        returned[0] = original with { Text = "changed after read" };
        Assert.Equal(original.Text, copied.Candidates[0].Text);

        var sourceIds = copied.Scope.SourceIds;
        var scope = copied.Scope with { SourceIds = [10] };
        scope.SourceIds[0] = 99;
        Assert.Equal(10, scope.SourceIds[0]);

        PackBudgetPrefix[] prefixes = [new(12, 35)];
        PackBudgetPassage[] passages = [new(1, 90, prefixes)];
        int[] history = [10];
        var budget = new PackBudgetInput(200, 20, 80, null, 3, passages, 0, 0, history);
        prefixes[0] = new(20, 50);
        passages[0] = new(2, 80, []);
        history[0] = 999;
        budget.Passages[0].TruncationCandidates[0] = new(30, 60);
        Assert.Equal(1, budget.Passages[0].Id);
        Assert.Equal(12, budget.Passages[0].TruncationCandidates[0].EndScalar);
        Assert.Equal(10, budget.HistoryTurnTokensNewestFirst[0]);
    }

    [Fact]
    public void PreparedCollectionsAndNestedCitationsAreDefensiveCopies()
    {
        var row = ContextPackFixtures.Cases("build").Single(row => row.GetProperty("name").GetString() == "basic-cs");
        var request = row.GetProperty("expected").Deserialize<PreparedContextRequest>(ContextPackFixtures.Options)!;
        var originalMessage = request.Messages[0];
        var originalCitation = request.CitationMap[0];
        CitationSpan[] spans = [new(0, 1, null, null)];
        long[] chunkIds = [101];
        Citation[] citations = [originalCitation with { Spans = spans, ChunkIds = chunkIds }];
        PackSourceRevision[] revisions = [new(10, 11)];
        var copied = request with { CitationMap = citations, SourceRevisions = revisions };
        spans[0] = new(50, 51, null, null);
        chunkIds[0] = 999;
        citations[0] = originalCitation with { Marker = 99 };
        revisions[0] = new(10, 999);
        copied.Messages[0].Sections[0] = new("rules", "changed", 1);
        copied.Messages[0] = new("assistant", []);
        Assert.Equal(originalMessage.Role, copied.Messages[0].Role);
        Assert.Equal(originalMessage.Sections[0].Text, copied.Messages[0].Sections[0].Text);
        Assert.Equal(1, copied.CitationMap[0].Marker);
        Assert.Equal(0, copied.CitationMap[0].Spans[0].Start);
        Assert.Equal(101, copied.CitationMap[0].ChunkIds[0]);
        Assert.Equal(11, copied.SourceRevisions[0].RevisionId);
        Assert.Throws<NotSupportedException>(() => ((IList<CitationSpan>)copied.CitationMap[0].Spans)[0] = new(1, 2, null, null));
        Assert.Throws<NotSupportedException>(() => ((IList<long>)copied.CitationMap[0].ChunkIds)[0] = 999);
    }

    private static PackPassage Passage(long chunkId, long sourceId, long? folderId = null,
        string path = "file.txt", long score = 0) =>
        new(chunkId, sourceId, sourceId, folderId, path, "file.txt", "en", "text", 0,
            0, 4, null, null, score, []);
}

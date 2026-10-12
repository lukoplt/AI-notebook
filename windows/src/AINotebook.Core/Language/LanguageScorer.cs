using System.Collections.ObjectModel;
using System.Text.Json.Serialization;

namespace AINotebook.Core.Language;

/// <summary>Per-call diagnostic snapshots; arrays never alias the model or another result.</summary>
public sealed record LanguageFeatureCount(
    [property: JsonPropertyName("symbols")] int[] Symbols,
    [property: JsonPropertyName("count")] long Count);
public sealed record LanguageProfileScore(
    [property: JsonPropertyName("weightedSums")] long[] WeightedSums,
    [property: JsonPropertyName("orderScores")] long[] OrderScores,
    [property: JsonPropertyName("combinedScore")] long CombinedScore);
public sealed record LanguageTextResult(
    [property: JsonPropertyName("words")] string[] Words,
    [property: JsonPropertyName("wordScalars")] int[][] WordScalars,
    [property: JsonPropertyName("letterCount")] long LetterCount,
    [property: JsonPropertyName("wordCount")] long WordCount,
    [property: JsonPropertyName("bucketStart"), JsonIgnore(Condition = JsonIgnoreCondition.Never)] int? BucketStart,
    [property: JsonPropertyName("features")] LanguageFeatureCount[][] Features,
    [property: JsonPropertyName("featureCounts")] long[] FeatureCounts,
    [property: JsonPropertyName("knownCounts")] long[] KnownCounts,
    [property: JsonPropertyName("unknownCounts")] long[] UnknownCounts,
    [property: JsonPropertyName("profiles")] IReadOnlyDictionary<string, LanguageProfileScore> Profiles,
    [property: JsonPropertyName("winner")] string Winner,
    [property: JsonPropertyName("runnerUp")] string RunnerUp,
    [property: JsonPropertyName("margin")] long Margin,
    [property: JsonPropertyName("coverageBp")] long CoverageBp,
    [property: JsonPropertyName("label")] string Label,
    [property: JsonPropertyName("reason")] string Reason);

internal sealed class LanguageScorer
{
    internal LanguageModel Model { get; }
    internal UnicodeTables Tables { get; }
    private readonly Dictionary<Feature, int>[] _vocabulary;
    /// <summary>Label-only path used by ingestion; same decisions as <see cref="Score"/>.</summary>
    internal LanguageFastScorer Fast { get; }

    internal LanguageScorer(LanguageModel model, UnicodeTables tables)
    {
        Model = model;
        Tables = tables;
        Fast = new LanguageFastScorer(model, tables);
        _vocabulary = model.Vocabulary.Select(v => v.Features.Select((f, i) =>
            (Feature: Feature.From(f, 0, v.Order), Index: i)).ToDictionary(x => x.Feature, x => x.Index)).ToArray();
    }

    internal static long FloorDiv(long a, long b)
    {
        if (b <= 0) throw new ArgumentOutOfRangeException(nameof(b));
        return a / b - (a < 0 && a % b != 0 ? 1 : 0);
    }

    internal readonly record struct Feature(int Length, int A, int B, int C)
    {
        internal static Feature From(IReadOnlyList<int> p, int start, int length) =>
            new(length, p[start], length > 1 ? p[start + 1] : 0, length > 2 ? p[start + 2] : 0);
        internal int[] Symbols() => Length switch
        {
            1 => new[] { A }, 2 => new[] { A, B }, 3 => new[] { A, B, C },
            _ => throw new InvalidOperationException("Invalid feature length.")
        };
    }

    internal LanguageTextResult Score(IReadOnlyList<int> scalars)
    {
        ArgumentOutOfRangeException.ThrowIfGreaterThan(scalars.Count, Model.Parameters.TextCapScalars);
        var words = LanguageNormalization.Classify(scalars, Tables);
        var counts = Enumerable.Range(0, 3).Select(_ => new Dictionary<Feature, long>()).ToArray();
        foreach (var padded in words.BoundaryWords)
            for (int order = 1; order <= 3; order++)
                for (int start = 0; start <= padded.Length - order; start++)
                {
                    var feature = Feature.From(padded, start, order);
                    counts[order - 1][feature] = checked(counts[order - 1].GetValueOrDefault(feature) + 1);
                }
        var features = counts.Select(order => order.OrderBy(x => x.Key.A).ThenBy(x => x.Key.B).ThenBy(x => x.Key.C)
            .Select(x => new LanguageFeatureCount(x.Key.Symbols(), x.Value)).ToArray()).ToArray();
        var featureCounts = counts.Select(order => order.Values.Sum()).ToArray();
        var knownCounts = counts.Select((order, n) => order.Where(x => _vocabulary[n].ContainsKey(x.Key)).Sum(x => x.Value)).ToArray();
        var unknownCounts = featureCounts.Select((total, n) => total - knownCounts[n]).ToArray();
        var profiles = new Dictionary<string, LanguageProfileScore>(StringComparer.Ordinal);
        foreach (var profile in Model.Profiles)
        {
            var sums = new long[3];
            var orderScores = new long[3];
            long combined = profile.PriorWeight;
            for (int n = 0; n < 3; n++)
            {
                foreach (var (feature, count) in counts[n])
                {
                    long weight = _vocabulary[n].TryGetValue(feature, out int index)
                        ? profile.Orders[n].Weights[index] : profile.Orders[n].UnknownWeight;
                    sums[n] = checked(sums[n] + count * weight);
                }
                orderScores[n] = featureCounts[n] == 0 ? 0 : FloorDiv(sums[n], featureCounts[n]);
                combined = checked(combined + Model.Parameters.OrderWeights[n] * orderScores[n]);
            }
            profiles.Add(profile.Id, new(sums, orderScores, combined));
        }
        var ranking = profiles.OrderByDescending(x => x.Value.CombinedScore)
            .ThenBy(x => x.Key == "background" ? 0 : 1).ThenBy(x => x.Key, StringComparer.Ordinal).ToArray();
        string winner = ranking[0].Key, runnerUp = ranking[1].Key;
        long margin = checked(ranking[0].Value.CombinedScore - ranking[1].Value.CombinedScore);
        long totalFeatures = featureCounts.Sum();
        long coverage = totalFeatures == 0 ? 0 : checked(10000 * knownCounts.Sum()) / totalFeatures;
        var bucket = Model.Thresholds.LastOrDefault(t => t.Start <= words.LetterCount);
        string reason = words.LetterCount < Model.Parameters.MinLetters ? "minLetters"
            : words.WordCount < Model.Parameters.MinWords ? "minWords"
            : bucket!.Enabled == 0 ? "bucketDisabled"
            : winner == "background" ? "background"
            : ranking[0].Value.CombinedScore < bucket.MinWinningScore ? "minWinningScore"
            : margin < bucket.MinMargin ? "minMargin"
            : coverage < bucket.MinKnownCoverageBp ? "minKnownCoverageBp"
            : "accepted";
        return new(words.Words, words.WordScalars, words.LetterCount, words.WordCount, bucket?.Start, features,
            featureCounts, knownCounts, unknownCounts, new ReadOnlyDictionary<string, LanguageProfileScore>(profiles),
            winner, runnerUp, margin, coverage, reason == "accepted" ? winner : "und", reason);
    }
}

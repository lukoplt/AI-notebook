using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AINotebook.Core.Language;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Language;

public sealed class LanguageScorerTests
{
    private static LanguageScorer Scorer(JsonElement? overrides = null)
    {
        var model = JsonNode.Parse(SharedFixtures.Json("contracts/lang-score-v1.json").GetProperty("model").GetRawText())!;
        if (overrides is JsonElement changes)
            foreach (var change in changes.EnumerateObject())
            {
                if (change.Name == "parameters")
                    foreach (var parameter in change.Value.EnumerateObject())
                        model["parameters"]![parameter.Name] = JsonNode.Parse(parameter.Value.GetRawText());
                else model[change.Name] = JsonNode.Parse(change.Value.GetRawText());
            }
        var tables = UnicodeTables.LoadBundled();
        return new(LanguageModel.Parse(Encoding.UTF8.GetBytes(model.ToJsonString() + "\n"), tables, true), tables);
    }

    [Fact]
    public void EveryTextIntermediate()
    {
        var scorer = Scorer();
        var cases = SharedFixtures.Json("contracts/lang-score-v1.json").GetProperty("cases").EnumerateArray()
            .Where(c => c.GetProperty("mode").GetString() == "text").ToArray();
        Assert.Equal(23, cases.Length);
        foreach (var c in cases)
        {
            var stream = LanguageNormalization.Stream(c.GetProperty("input").GetString()!, scorer.Tables, scorer.Model.Parameters.InputCapScalars);
            var result = scorer.Score(stream.Take(scorer.Model.Parameters.TextCapScalars).ToArray());
            LanguageFixtureAssert.Equal(c.GetProperty("expected"), result, c.GetProperty("name").GetString()!);
        }
    }

    [Theory]
    [InlineData(-7L, 3L, -3L)]
    [InlineData(-6L, 3L, -2L)]
    [InlineData(7L, 3L, 2L)]
    public void SignedFloorDivision(long a, long b, long expected) => Assert.Equal(expected, LanguageScorer.FloorDiv(a, b));

    [Fact]
    public void SupplementalEqualityAndTextCapCases()
    {
        var cases = SharedFixtures.Json("contracts/lang-runtime-v1.json").GetProperty("cases").EnumerateArray()
            .Where(c => c.GetProperty("operation").GetString() == "score").ToArray();
        Assert.Equal(6, cases.Length);
        foreach (var c in cases)
        {
            var scorer = Scorer(c.GetProperty("modelOverrides"));
            var stream = LanguageNormalization.Stream(c.GetProperty("input").GetString()!, scorer.Tables, scorer.Model.Parameters.InputCapScalars);
            LanguageFixtureAssert.Equal(c.GetProperty("expected"), scorer.Score(stream.Take(scorer.Model.Parameters.TextCapScalars).ToArray()),
                c.GetProperty("name").GetString()!);
        }
    }

    [Fact]
    public void EmptyFeaturesRetainPriorAndDiagnostics()
    {
        var scorer = Scorer();
        var result = scorer.Score(Array.Empty<int>());
        Assert.All(result.Profiles.Values, p =>
        {
            Assert.Equal(new long[] { 0, 0, 0 }, p.WeightedSums);
            Assert.Equal(new long[] { 0, 0, 0 }, p.OrderScores);
            Assert.Equal(-1125, p.CombinedScore);
        });
        Assert.Equal("background", result.Winner);
        Assert.Equal("xa", result.RunnerUp);
        Assert.Null(result.BucketStart);
        Assert.Equal("minLetters", result.Reason);
    }

    [Fact]
    public void ResultsCannotMutateScorerOrOtherSnapshots()
    {
        var scorer = Scorer();
        var stream = LanguageNormalization.Stream("aaaa aaaa aaaa", scorer.Tables, scorer.Model.Parameters.InputCapScalars);
        var first = scorer.Score(stream);
        var second = scorer.Score(stream);
        var expected = JsonSerializer.SerializeToElement(second, LanguageFixtureAssert.Json);
        first.Words[0] = "changed";
        first.WordScalars[0][0] = 0;
        first.Features[0][0].Symbols[0] = 0;
        first.FeatureCounts[0] = 0;
        first.KnownCounts[0] = 0;
        first.UnknownCounts[0] = 999;
        first.Profiles["xa"].WeightedSums[0] = 0;
        first.Profiles["xa"].OrderScores[0] = 0;
        LanguageFixtureAssert.Equal(expected, second, "previous snapshot");
        LanguageFixtureAssert.Equal(expected, scorer.Score(stream), "subsequent snapshot");
    }
}

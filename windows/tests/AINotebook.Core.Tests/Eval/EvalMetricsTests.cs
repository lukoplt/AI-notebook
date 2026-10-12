using System.Text.Json;
using AINotebook.Core.Eval;
using Xunit;

namespace AINotebook.Core.Tests.Eval;

public sealed class EvalMetricsTests
{
    [Fact]
    public void OccurrenceIdentityOverlapAndTruncatedPack()
    {
        var hash = new string('a', 64);
        var first = new EvalSpan("d", hash, 0, 3);
        var second = new EvalSpan("d", hash, 4, 7);
        var full = new EvalSpan("d", hash, 0, 8);
        Assert.Equal(0, EvalMetrics.Recall([second], [first]).RecallBp);
        Assert.Equal(1, EvalMetrics.Recall([second], [full, full]).Found);
        var scores = EvalMetrics.Measure([second], [first], [first, full], 1, true, [first]);
        Assert.Equal(0, scores["hybrid_recall_at_top_k"].RecallBp);
        Assert.Equal(10000, scores["candidate_recall_at_fetch_k"].RecallBp);
        Assert.Equal(0, scores["packed_evidence_recall"].RecallBp);
        var absent = EvalMetrics.Recall([], [full]);
        Assert.Equal("not_applicable", absent.Status);
        Assert.Null(absent.RecallBp);
        Assert.Equal(1, EvalMetrics.Aggregate([absent, scores["candidate_recall_at_fetch_k"]]).Total);
        Assert.Equal("invalid_top_k", Assert.Throws<EvalFailure>(() => EvalMetrics.Measure([], [], [], 0, false, null)).Code);
    }

    [Fact]
    public void SharedMetricCases()
    {
        var all = EvalRetrievalTests.Cases().ToArray();
        Assert.Equal(28, all.Length);
        Assert.Equal(18, all.Count(c => c.GetProperty("kind").GetString() == "retrieval"));
        var visited = new HashSet<string>(StringComparer.Ordinal);
        foreach (var c in all.Where(c => c.GetProperty("kind").GetString() == "metrics"))
        {
            Assert.True(visited.Add(c.GetProperty("name").GetString()!));
            var input = c.GetProperty("input");
            var packed = input.GetProperty("packed");
            var actual = EvalMetrics.Measure(Spans(input.GetProperty("gold")), Spans(input.GetProperty("lexical")),
                Spans(input.GetProperty("fused")), input.GetProperty("top_k").GetInt32(),
                input.GetProperty("include_vectors").GetBoolean(), packed.ValueKind == JsonValueKind.Null ? null : Spans(packed));
            var expected = c.GetProperty("expected");
            Assert.Equal(expected.EnumerateObject().Select(p => p.Name).Order(), actual.Keys.Order());
            foreach (var entry in expected.EnumerateObject())
            {
                var e = entry.Value;
                int? Value(string key) => e.GetProperty(key).ValueKind == JsonValueKind.Null ? null : e.GetProperty(key).GetInt32();
                Assert.Equal(new EvalMetric(e.GetProperty("status").GetString()!, Value("found"), Value("total"), Value("recall_bp")), actual[entry.Name]);
            }
        }
        Assert.Equal(10, visited.Count);
    }

    private static EvalSpan[] Spans(JsonElement array) => array.EnumerateArray().Select(s => new EvalSpan(
        s.GetProperty("document_id").GetString()!, s.GetProperty("content_hash").GetString()!,
        s.GetProperty("start").GetInt32(), s.GetProperty("end").GetInt32())).ToArray();

    [Fact]
    public void AggregationPoolsEvidenceAndKeepsUnavailableDistinct()
    {
        var notApplicable = new EvalMetric("not_applicable", 0, 0, null);
        var scores = new[] { new EvalMetric("measured", 1, 1, 10000), new EvalMetric("measured", 0, 3, 0), notApplicable, EvalMetric.Unavailable };
        Assert.Equal(new EvalMetric("measured", 1, 4, 2500), EvalMetrics.Aggregate(scores));
        Assert.Equal(EvalMetric.Unavailable, EvalMetrics.Aggregate([notApplicable, EvalMetric.Unavailable]));
        Assert.Equal(notApplicable, EvalMetrics.Aggregate([notApplicable]));
        Assert.Equal(notApplicable, EvalMetrics.Aggregate([]));
        Assert.Equal(3333, EvalMetrics.Aggregate([new("measured", 1, 3, 3333)]).RecallBp);
    }
}

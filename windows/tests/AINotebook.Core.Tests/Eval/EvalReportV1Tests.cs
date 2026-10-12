using System.Globalization;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Eval;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Eval;

public sealed class EvalReportV1Tests
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower
    };

    [Fact]
    public void SharedReports()
    {
        foreach (var fixture in SharedFixtures.Json("contracts/eval-report-v1.json")
                     .GetProperty("cases").EnumerateArray())
            CheckReport(fixture);
    }

    [Fact]
    public void SharedReportsAreCultureIndependent()
    {
        var originalCulture = CultureInfo.CurrentCulture;
        var originalUiCulture = CultureInfo.CurrentUICulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("cs-CZ");
            CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("cs-CZ");
            foreach (var fixture in SharedFixtures.Json("contracts/eval-report-v1.json")
                         .GetProperty("cases").EnumerateArray())
                CheckReport(fixture);
        }
        finally
        {
            CultureInfo.CurrentCulture = originalCulture;
            CultureInfo.CurrentUICulture = originalUiCulture;
        }
    }

    private static void CheckReport(JsonElement fixture)
    {
        var report = fixture.GetProperty("input").Deserialize<EvalReportV1>(JsonOptions)!;
        var bytes = report.JsonBytes();
        using var actual = JsonDocument.Parse(bytes);
        Assert.True(JsonElement.DeepEquals(actual.RootElement, fixture.GetProperty("expected_json")),
            fixture.GetProperty("name").GetString());
        AssertSortedKeys(actual.RootElement);
        Assert.Equal(bytes, report.JsonBytes());
        var json = new UTF8Encoding(false, true).GetString(bytes);
        Assert.False(bytes.AsSpan().StartsWith(new byte[] { 0xef, 0xbb, 0xbf }));
        Assert.EndsWith("\n", json);
        Assert.False(json.EndsWith("\n\n", StringComparison.Ordinal));
        Assert.DoesNotContain("\r", json);
        Assert.Contains("café", json);
        var markdown = report.Markdown();
        Assert.Equal(fixture.GetProperty("expected_markdown").GetString(), markdown);
        Assert.DoesNotContain("\r", markdown);
    }

    private static void AssertSortedKeys(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var properties = element.EnumerateObject().ToArray();
            Assert.Equal(properties.Select(p => p.Name).Order(StringComparer.Ordinal),
                properties.Select(p => p.Name));
            foreach (var property in properties) AssertSortedKeys(property.Value);
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in element.EnumerateArray()) AssertSortedKeys(item);
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void AssemblePoolsEvidenceCountsAndPreservesEmptyGroupStatuses(bool measured)
    {
        var root = Path.Combine(AppContext.BaseDirectory, "EvalMultilingual");
        var corpus = EvalCorpus.Load(File.ReadAllBytes(Path.Combine(root, "manifest.json")),
            File.ReadAllBytes(Path.Combine(root, "queries.json")),
            path => File.ReadAllBytes(Path.Combine(root, path)));
        var first = corpus.Questions.First(q => q.CaseType == "answer");
        var second = corpus.Questions.First(q => q.CaseType == "exact_identifier" && q.Language != first.Language);
        var rows = corpus.Questions.Select(question =>
        {
            var overview = question.CaseType == "overview";
            var metric = question.QueryId == first.QueryId ? new EvalMetric("measured", 1, 1, 10000)
                : question.QueryId == second.QueryId ? new EvalMetric("measured", 0, 3, 0)
                : EvalMetric.NotApplicable;
            var metrics = EvalMetrics.Names.ToDictionary(name => name,
                name => !overview && !measured && name is "hybrid_recall_at_top_k" or "packed_evidence_recall"
                    ? EvalMetric.Unavailable : metric, StringComparer.Ordinal);
            var selected = corpus.SelectedDocuments(question);
            return new EvalQueryRow(question.QueryId, question.Text, question.Language, question.CaseType,
                overview ? "deferred_overview_wp8" : "measured", selected.Count,
                selected.Count(document => document.Text.Length > 0), [], [], [], metrics);
        }).ToArray();

        var report = EvalReportV1.Assemble(corpus, new string('a', 64), "windows",
            measured ? "ollama" : "lexical", measured ? "fixture-model" : null,
            measured ? 2 : null, 1, 2, rows, measured);

        Assert.Equal(1, report.SchemaVersion);
        Assert.Equal("multilingual-v1", report.CorpusId);
        Assert.Equal(new string('a', 64), report.CorpusHash);
        Assert.Equal("windows", report.Platform);
        Assert.Equal("legacy-fts-eval-rrf-v1", report.RetrievalVersion);
        Assert.Equal("eval-scalars-v1", report.ChunkerVersion);
        Assert.Equal(measured ? "ollama" : "lexical", report.Mode);
        Assert.Equal(measured ? "fixture-model" : null, report.Model);
        Assert.Equal(measured ? 2 : (int?)null, report.Dimensions);
        Assert.Equal(1, report.TopK);
        Assert.Equal(2, report.FetchK);
        Assert.Equal(44, report.Documents);
        Assert.Equal(144, report.QueriesTotal);
        Assert.Equal(4, report.AbsentQueries);
        Assert.Equal(4, report.EmptySelectionQueries);
        Assert.Equal(4, report.OverviewQueries);
        Assert.Equal(rows.Select(r => r.QueryId), report.Queries.Select(r => r.QueryId));
        Assert.Equal(measured ? "measured" : "not_available", report.Capabilities.PackedEvidence);
        Assert.Equal("not_available", report.Capabilities.Overview);
        Assert.Null(report.Timing.ColdCacheMs);
        Assert.Null(report.Timing.WarmRetrievalMs);
        Assert.Null(report.Timing.EndToEndMs);

        Assert.Equal(corpus.Questions.Select(q => q.Language).Distinct().Order(StringComparer.Ordinal),
            report.ByLanguage.Keys);
        Assert.Equal(corpus.Questions.Select(q => q.CaseType).Distinct().Order(StringComparer.Ordinal),
            report.ByCaseType.Keys);
        foreach (var name in EvalMetrics.Names)
        {
            var unavailable = !measured && name is "hybrid_recall_at_top_k" or "packed_evidence_recall";
            Assert.Equal(unavailable ? EvalMetric.Unavailable : new EvalMetric("measured", 1, 4, 2500),
                report.Metrics[name]);
            Assert.Equal(EvalMetric.NotApplicable, report.ByCaseType["overview"][name]);
            Assert.Equal(unavailable ? EvalMetric.Unavailable : EvalMetric.NotApplicable,
                report.ByCaseType["empty_selection"][name]);
            Assert.Equal(unavailable ? EvalMetric.Unavailable : EvalMetric.NotApplicable,
                report.ByCaseType["absent"][name]);
            if (unavailable) continue;
            Assert.Equal(new EvalMetric("measured", 1, 1, 10000), report.ByCaseType["answer"][name]);
            Assert.Equal(new EvalMetric("measured", 0, 3, 0), report.ByCaseType["exact_identifier"][name]);
            foreach (var groups in new[] { report.ByLanguage, report.ByCaseType })
            {
                Assert.Equal(report.Metrics[name].Found, groups.Values.Sum(group => group[name].Found ?? 0));
                Assert.Equal(report.Metrics[name].Total, groups.Values.Sum(group => group[name].Total ?? 0));
            }
        }

        var overviewOnly = EvalReportV1.Assemble(corpus, new string('a', 64), "windows",
            "lexical", null, null, 1, 2, rows.Where(row => row.CaseType == "overview").ToArray(), false);
        Assert.All(overviewOnly.Metrics.Values, metric => Assert.Equal(EvalMetric.NotApplicable, metric));
        Assert.All(overviewOnly.ByLanguage.Values.SelectMany(group => group.Values),
            metric => Assert.Equal(EvalMetric.NotApplicable, metric));
    }
}

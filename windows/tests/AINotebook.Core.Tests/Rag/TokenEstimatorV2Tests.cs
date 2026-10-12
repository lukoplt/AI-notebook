using System.Text.Json;
using AINotebook.Core.Eval;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public sealed class TokenEstimatorV2Tests
{
    private static readonly JsonElement Root = SharedFixtures.Json("contracts/token-estimate-v2.json");

    private static IEnumerable<JsonElement> Cases(string kind) =>
        Root.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("kind").GetString() == kind);

    private static TokenSample Sample(JsonElement s) => new(s.GetProperty("id").GetString()!, s.GetProperty("family").GetString()!,
        s.GetProperty("language").GetString()!, s.GetProperty("split").GetString()!, s.GetProperty("scalars").GetInt32(),
        s.GetProperty("tokens").GetInt32());

    private static TokenRate Rate(JsonElement r) => new(r.GetProperty("family").GetString()!, r.GetProperty("language").GetString()!,
        r.GetProperty("tokensPerScalarBp").GetInt32());

    private static TokenRate[] Rates(JsonElement rates) => rates.EnumerateArray().Select(Rate).ToArray();

    private static string Code(Action action) => Assert.Throws<BenchmarkException>(action).Code;

    [Fact]
    public void SharedFits()
    {
        int n = 0;
        foreach (var c in Cases("fit"))
        {
            var samples = c.GetProperty("samples").EnumerateArray().Select(Sample).ToArray();
            if (c.TryGetProperty("error", out var error))
                Assert.Equal(error.GetString(), Code(() => TokenCalibration.Fit(samples)));
            else Assert.Equal(Rates(c.GetProperty("expected")), TokenCalibration.Fit(samples));
            n++;
        }
        Assert.Equal(12, n);
    }

    [Fact]
    public void SharedEstimates()
    {
        int n = 0;
        foreach (var c in Cases("estimate"))
        {
            string lang = c.GetProperty("language").GetString()!;
            var e = new TokenEstimatorV2("fixture-only", [new("fixture-only", lang, c.GetProperty("rateBp").GetInt32())]);
            Assert.Equal(c.GetProperty("expected").GetInt32(), e.Estimate(c.GetProperty("text").GetString()!, lang));
            Assert.Equal(2, e.Version);
            n++;
        }
        Assert.Equal(6, n);
    }

    [Fact]
    public void SharedEstimatorsUseFamilyMaximumOrUtf8Fallback()
    {
        int n = 0;
        foreach (var c in Cases("estimator"))
        {
            var e = new TokenEstimatorV2(c.GetProperty("family").GetString()!, Rates(c.GetProperty("rates")));
            Assert.Equal(c.GetProperty("expected").GetInt32(), e.Estimate(c.GetProperty("text").GetString()!, c.GetProperty("language").GetString()!));
            n++;
        }
        Assert.Equal(5, n);
        foreach (var c in Cases("estimatorBound"))
        {
            var e = new TokenEstimatorV2(c.GetProperty("family").GetString()!, Rates(c.GetProperty("rates")));
            string text = new('a', c.GetProperty("scalars").GetInt32());
            Assert.Equal(c.GetProperty("expected").GetInt32(), e.Estimate(text, c.GetProperty("language").GetString()!));
            n++;
        }
        Assert.Equal(6, n);
    }

    [Fact]
    public void SharedUndercounts()
    {
        int n = 0;
        foreach (var c in Cases("undercount"))
        {
            var samples = c.GetProperty("samples").EnumerateArray().Select(Sample).ToArray();
            var rates = Rates(c.GetProperty("rates"));
            if (c.TryGetProperty("error", out var error))
                Assert.Equal(error.GetString(), Code(() => TokenCalibration.Undercounts(samples, rates)));
            else
            {
                Assert.Equal(c.GetProperty("undercounts").GetInt32(), TokenCalibration.Undercounts(samples, rates));
                var rows = TokenCalibration.UndercountRows(samples, rates);
                Assert.Equal(c.GetProperty("rows").EnumerateArray().Select(r => new TokenUndercountRow(r.GetProperty("id").GetString()!,
                    r.GetProperty("estimated").GetInt32(), r.GetProperty("actual").GetInt32(), r.GetProperty("undercount").GetInt32())), rows);
            }
            n++;
        }
        Assert.Equal(2, n);
    }

    [Fact]
    public void SharedConstructorValidation()
    {
        int n = 0;
        foreach (var c in Cases("constructor"))
        {
            var rates = Rates(c.GetProperty("rates"));
            void Make() => _ = new TokenEstimatorV2(c.GetProperty("family").GetString()!, rates);
            if (c.GetProperty("error").ValueKind == JsonValueKind.Null) Make();
            else Assert.Equal(c.GetProperty("error").GetString(), Code(Make));
            n++;
        }
        Assert.Equal(6, n);
        var copied = new List<TokenRate> { new("fixture-only", "cs", 10000) };
        var estimator = new TokenEstimatorV2("fixture-only", copied);
        copied[0] = new("fixture-only", "cs", 0);
        Assert.Equal(4, estimator.Estimate("abc", "cs"));
    }

    [Fact]
    public void SharedBindingsResolveOnlyExactModelAndDigest()
    {
        int n = 0;
        foreach (var c in Cases("binding"))
        {
            var bindings = c.GetProperty("bindings").EnumerateArray().Select(b => new TokenFamilyBinding(
                b.GetProperty("model").GetString()!, b.GetProperty("modelDigest").GetString()!, b.GetProperty("family").GetString()!)).ToArray();
            string? digest = c.GetProperty("modelDigest").ValueKind == JsonValueKind.Null ? null : c.GetProperty("modelDigest").GetString();
            string? expected = c.GetProperty("expected").ValueKind == JsonValueKind.Null ? null : c.GetProperty("expected").GetString();
            Assert.Equal(expected, TokenEstimatorV2.ResolveFamily(c.GetProperty("model").GetString()!, digest, bindings));
            n++;
        }
        Assert.Equal(5, n);
    }

    [Fact]
    public void MutableModelAliasDoesNotSelectUnprovenRates()
    {
        var rows = new[] { new TokenFamilyBinding("llama3.2:3b", "sha256:" + new string('a', 64), "fixture-only") };
        Assert.Null(TokenEstimatorV2.ResolveFamily("llama3.2:3b", null, rows));
        Assert.Null(TokenEstimatorV2.ResolveFamily("llama3.2:3b", "sha256:" + new string('b', 64), rows));
        Assert.Equal("fixture-only", TokenEstimatorV2.ResolveFamily("llama3.2:3b", rows[0].ModelDigest, rows));
        Assert.Equal(7, new TokenEstimatorV2("unverified", []).Estimate("a😀b", "cs"));
    }

    [Fact]
    public void SharedResourcesValidateHashStatusAndFixtureFamily()
    {
        int n = 0;
        foreach (var c in Cases("resource"))
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(c.GetProperty("input"));
            bool production = c.GetProperty("production").GetBoolean();
            if (c.TryGetProperty("error", out var error))
                Assert.Equal(error.GetString(), Code(() => TokenEstimateResource.Parse(bytes, production)));
            else
            {
                var resource = TokenEstimateResource.Parse(bytes, production);
                Assert.Equal(c.GetProperty("expected").GetProperty("payloadHash").GetString(), resource.PayloadHash);
                Assert.Equal(c.GetProperty("expected").GetProperty("status").GetString(), resource.Status);
            }
            n++;
        }
        Assert.Equal(6, n);
    }

    [Fact]
    public void BundledPendingResourceKeepsTheConservativeFallback()
    {
        var bundled = TokenEstimateResource.Bundled();
        Assert.Equal("pending", bundled.Status);
        Assert.Equal(Root.GetProperty("payloadHash").GetString(), bundled.PayloadHash);
        Assert.Empty(bundled.Rates);
        var estimator = TokenEstimatorV2.Bundled("llama3.2:3b", "sha256:" + new string('a', 64));
        Assert.Equal(2, estimator.Version);
        Assert.Equal(7, estimator.Estimate("a😀b", "cs"));
        Assert.Equal(7, TokenEstimatorV2.Bundled("llama3.2:3b").Estimate("a😀b", "cs"));
    }

    [Fact]
    public void SharedCalibrationObservationsFitOnlyTrainBodies()
    {
        var c = Assert.Single(Cases("calibration-observations"));
        var observations = c.GetProperty("observations").EnumerateArray().Select(o => new TokenObservation(
            o.GetProperty("kind").GetString()!, o.GetProperty("method").GetString()!, Sample(o.GetProperty("sample")))).ToArray();
        var training = TokenCalibration.TrainingSamples(observations);
        Assert.Equal(c.GetProperty("expected").GetProperty("trainingIds").EnumerateArray().Select(x => x.GetString()), training.Select(s => s.Id));
        Assert.Equal(Rates(c.GetProperty("expected").GetProperty("rates")), TokenCalibration.Fit(training));
    }

    [Fact]
    public void SharedSamplePlan()
    {
        var c = Assert.Single(Cases("sample-plan"));
        var documents = c.GetProperty("documents").EnumerateArray().Select(d => new CalibrationDocument(
            d.GetProperty("document_id").GetString()!, d.GetProperty("language").GetString()!, d.GetProperty("text").GetString()!)).ToArray();
        var queries = c.GetProperty("queries").EnumerateArray().Select(q => new CalibrationQuery(
            q.GetProperty("query_id").GetString()!, q.GetProperty("language").GetString()!, q.GetProperty("case_type").GetString()!,
            q.GetProperty("text").GetString()!, q.GetProperty("gold_document_ids").EnumerateArray().Select(x => x.GetString()!).ToArray())).ToArray();
        var plan = TokenCalibration.SamplePlan(documents, queries);
        var actual = JsonSerializer.SerializeToElement(plan, BenchmarkJson.Options);
        Assert.True(JsonElement.DeepEquals(c.GetProperty("expected"), actual), actual.GetRawText());
    }

    [Fact]
    public void SharedCalibrationReports()
    {
        int n = 0;
        foreach (var c in Cases("calibration-report"))
        {
            string name = c.GetProperty("name").GetString()!;
            var report = c.GetProperty("input").Deserialize<TokenCalibrationReportV1>(BenchmarkJson.Options)!;
            if (c.TryGetProperty("error", out var error)) { Assert.Equal(error.GetString(), Code(report.Validate)); n++; continue; }
            report.Validate();
            var bytes = report.JsonBytes();
            Assert.Equal((byte)'\n', bytes[^1]);
            using var actual = JsonDocument.Parse(bytes);
            Assert.True(JsonElement.DeepEquals(c.GetProperty("expectedJson"), actual.RootElement), name);
            Assert.Equal(c.GetProperty("expectedMarkdown").GetString(), report.Markdown());
            n++;
        }
        Assert.Equal(7, n);
    }
}

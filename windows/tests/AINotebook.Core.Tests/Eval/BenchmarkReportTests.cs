using System.Text.Json;
using AINotebook.Core.Eval;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Eval;

public sealed class BenchmarkReportTests
{
    private static readonly JsonElement Root = SharedFixtures.Json("contracts/benchmark-report-v1.json");

    private static IEnumerable<JsonElement> Cases(string kind) =>
        Root.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("kind").GetString() == kind);

    private static string Code(Action action) => Assert.Throws<BenchmarkException>(action).Code;

    [Fact]
    public void SharedReports()
    {
        int n = 0;
        foreach (var c in Cases("report"))
        {
            string name = c.GetProperty("name").GetString()!;
            var r = c.GetProperty("input").Deserialize<BenchmarkReportV1>(BenchmarkJson.Options)!;
            if (c.TryGetProperty("error", out var error)) { Assert.True(error.GetString() == Code(r.Validate), name); n++; continue; }
            r.Validate();
            var bytes = r.JsonBytes();
            Assert.Equal((byte)'\n', bytes[^1]);
            using var actual = JsonDocument.Parse(bytes);
            Assert.True(JsonElement.DeepEquals(c.GetProperty("expectedJson"), actual.RootElement), name);
            Assert.Equal(c.GetProperty("expectedMarkdown").GetString(), r.Markdown());
            n++;
        }
        Assert.Equal(16, n);
    }

    [Fact]
    public void NearestRankAndStrictGate()
    {
        var samples = Enumerable.Range(1, 200).Select(x => (long)x).ToArray();
        Assert.Equal(190, BenchmarkMath.Percentile(samples, 9500));
        Assert.Equal(100, BenchmarkMath.Percentile(samples, 5000));
        Assert.False(BenchmarkMath.WarmGate(100000, false, 200, 300000));
        Assert.Null(BenchmarkMath.WarmGate(200000, false, 200, 900000));
    }

    [Fact]
    public void SharedPercentiles()
    {
        int n = 0;
        foreach (var c in Cases("percentile"))
        {
            var samples = c.GetProperty("input").GetProperty("samples").EnumerateArray().Select(x => x.GetInt64()).ToArray();
            if (c.TryGetProperty("error", out var error))
                Assert.Equal(error.GetString(), Code(() => BenchmarkMath.Percentile(samples, 5000)));
            else
            {
                Assert.Equal(c.GetProperty("expected").GetProperty("p50").GetInt64(), BenchmarkMath.Percentile(samples, 5000));
                Assert.Equal(c.GetProperty("expected").GetProperty("p95").GetInt64(), BenchmarkMath.Percentile(samples, 9500));
            }
            n++;
        }
        Assert.Equal(5, n);
    }

    [Fact]
    public void SharedGates()
    {
        int n = 0;
        foreach (var c in Cases("gate"))
        {
            var i = c.GetProperty("input");
            bool? expected = c.GetProperty("expected").ValueKind == JsonValueKind.Null ? null : c.GetProperty("expected").GetBoolean();
            Assert.Equal(expected, BenchmarkMath.WarmGate(i.GetProperty("chunks").GetInt32(), i.GetProperty("concurrent").GetBoolean(),
                i.GetProperty("queries").GetInt32(), i.GetProperty("p95Us").GetInt64()));
            n++;
        }
        Assert.Equal(5, n);
    }

    [Fact]
    public void SharedThroughput()
    {
        int n = 0;
        foreach (var c in Cases("throughput"))
        {
            var i = c.GetProperty("input");
            long tokens = i.GetProperty("tokens").GetInt64(), elapsed = i.GetProperty("elapsedUs").GetInt64();
            if (c.TryGetProperty("error", out var error))
                Assert.Equal(error.GetString(), Code(() => BenchmarkMath.TokensPerSecondMilli(tokens, elapsed)));
            else
            {
                var e = c.GetProperty("expected").GetProperty("tokensPerSecondMilli");
                Assert.Equal(e.ValueKind == JsonValueKind.Null ? null : e.GetInt64(), BenchmarkMath.TokensPerSecondMilli(tokens, elapsed));
            }
            n++;
        }
        Assert.Equal(4, n);
    }

    [Fact]
    public void SharedMarkdownEscapingAndRecallFormat()
    {
        int n = 0;
        foreach (var c in Cases("escape"))
        {
            Assert.Equal(c.GetProperty("expected").GetString(), BenchmarkMarkdown.Escape(c.GetProperty("input").GetString()!));
            n++;
        }
        foreach (var c in Cases("recallFormat"))
        {
            var metrics = c.GetProperty("input").Deserialize<EvalMetric[]>(BenchmarkJson.SnakeOptions)!;
            Assert.Equal(c.GetProperty("expected").EnumerateArray().Select(x => x.GetString()), metrics.Select(BenchmarkMarkdown.Recall));
            n++;
        }
        Assert.Equal(3, n);
    }
}

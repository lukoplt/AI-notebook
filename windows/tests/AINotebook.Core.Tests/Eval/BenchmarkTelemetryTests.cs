using System.Text.Json;
using AINotebook.Core.Eval;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using AINotebook.Core.Tests.Providers;
using Xunit;

namespace AINotebook.Core.Tests.Eval;

public sealed class BenchmarkTelemetryTests
{
    private static readonly JsonElement Root = SharedFixtures.Json("contracts/benchmark-run-v1.json");

    private static IEnumerable<JsonElement> Cases(string kind) =>
        Root.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("kind").GetString() == kind);

    private static string Code(Action action) => Assert.Throws<BenchmarkException>(action).Code;

    [Fact]
    public void CombinedPeakIsNotSumOfIndependentPeaks()
    {
        var p = BenchmarkTelemetry.Peaks([new(0, 80, 10), new(1, 20, 70)]);
        Assert.Equal(80, p.RunnerBytes); Assert.Equal(70, p.ServerBytes); Assert.Equal(90, p.CombinedBytes);
    }

    [Fact]
    public void SharedMemoryPeaks()
    {
        int n = 0;
        foreach (var c in Cases("memory"))
        {
            var samples = c.GetProperty("input").EnumerateArray().Select(s => new ProcessMemorySample(s.GetProperty("atUs").GetInt64(),
                s.GetProperty("runnerBytes").GetInt64(), s.GetProperty("serverTreeBytes").GetInt64())).ToArray();
            if (c.TryGetProperty("error", out var error)) Assert.Equal(error.GetString(), Code(() => BenchmarkTelemetry.Peaks(samples)));
            else
            {
                var e = c.GetProperty("expected");
                Assert.Equal(new ProcessMemoryPeaks(e.GetProperty("runnerBytes").GetInt64(), e.GetProperty("serverBytes").GetInt64(),
                    e.GetProperty("combinedBytes").GetInt64()), BenchmarkTelemetry.Peaks(samples));
            }
            n++;
        }
        Assert.Equal(5, n);
    }

    [Fact]
    public void SharedProcessTrees()
    {
        int n = 0;
        foreach (var c in Cases("process"))
        {
            var i = c.GetProperty("input");
            ProcessTreeSample Run() => BenchmarkTelemetry.ParseProcessTable(i.GetProperty("psOutput").GetString()!,
                i.GetProperty("rootPid").GetInt32(), i.GetProperty("runnerPid").GetInt32());
            if (c.TryGetProperty("error", out var error)) Assert.Equal(error.GetString(), Code(() => Run()));
            else
            {
                var e = c.GetProperty("expected");
                var sample = Run();
                Assert.Equal(e.GetProperty("runnerBytes").GetInt64(), sample.RunnerBytes);
                Assert.Equal(e.GetProperty("serverTreeBytes").GetInt64(), sample.ServerTreeBytes);
                Assert.Equal(e.GetProperty("serverPids").EnumerateArray().Select(x => x.GetInt32()), sample.ServerPids);
            }
            n++;
        }
        Assert.Equal(7, n);
    }

    [Fact]
    public void InjectedEnumerationBuildsOneSampleWithoutPlatformCalls()
    {
        var rows = new[] { new ProcessRow(10, 1), new ProcessRow(11, 10), new ProcessRow(99, 1), new ProcessRow(12, 11) };
        var bytes = new Dictionary<int, long> { [10] = 100, [11] = 200, [99] = 50 };
        // PID 12 vanished between enumeration and the RSS read: it is skipped, not fabricated.
        var sample = BenchmarkTelemetry.Sample(rows, pid => bytes.TryGetValue(pid, out var b) ? b : null, 10, 99, 7);
        Assert.Equal(new ProcessMemorySample(7, 50, 300), sample);
        Assert.Equal("processUnavailable", Code(() => BenchmarkTelemetry.Sample(rows, pid => bytes.TryGetValue(pid, out var b) ? b : null, 42, 99, 7)));
        Assert.Equal("processUnavailable", Code(() => BenchmarkTelemetry.Sample(rows, pid => pid == 99 ? null : 1, 10, 99, 7)));
    }

    [Fact]
    public async Task SamplerRecordsStartAndEndSamplesAndStopsCleanly()
    {
        long t = 0;
        await using var sampler = BenchmarkTelemetry.StartSampler(() => new ProcessMemorySample(Interlocked.Increment(ref t), 1, 2), TimeSpan.FromHours(1));
        var samples = await sampler.StopAsync();
        Assert.True(samples.Count >= 2);
        Assert.Equal(new ProcessMemoryPeaks(1, 2, 3), BenchmarkTelemetry.Peaks(samples));
        Assert.Same(samples, await sampler.StopAsync());
    }

    [Fact]
    public async Task EmbeddingCollectorSnapshotsMatchTheSharedTelemetryRows()
    {
        var strict = SharedFixtures.Json("contracts/embedding-strict-v1.json");
        int n = 0;
        foreach (var c in strict.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("kind").GetString() == "telemetry"))
        {
            var collector = new BenchmarkEmbeddingTelemetry();
            var events = c.GetProperty("events").EnumerateArray().Select(StrictEmbeddingPipelineTests.Event).ToArray();
            foreach (var e in events) await collector.RecordAsync(e);
            StrictEmbeddingPipelineTests.AssertSnapshot(c.GetProperty("snapshot"), collector.Snapshot(events[0].Purpose), c.GetProperty("name").GetString()!);
            n++;
        }
        Assert.Equal(2, n);
        var empty = new BenchmarkEmbeddingTelemetry();
        Assert.Equal("measured", empty.Snapshot(EmbeddingPurpose.Document).ServiceTokenStatus);
        var overflow = new BenchmarkEmbeddingTelemetry();
        await overflow.RecordAsync(new(EmbeddingTelemetryEvent.PartAccepted, EmbeddingPurpose.Document, null, 0, 1));
        Assert.Equal("invalidSamples", Code(() => overflow.Snapshot(EmbeddingPurpose.Document)));
    }
}

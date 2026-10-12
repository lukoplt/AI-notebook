using System.Text.Json;
using AINotebook.Core.Eval;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Eval;

public sealed class BenchmarkMeasurementsTests
{
    private static readonly JsonElement Root = SharedFixtures.Json("contracts/benchmark-run-v1.json");

    private static IEnumerable<JsonElement> Cases(string kind) =>
        Root.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("kind").GetString() == kind);

    private static string Code(Action action) => Assert.Throws<BenchmarkException>(action).Code;

    [Fact]
    public async Task ColdWarmupAndMeasuredQueriesAreSeparate()
    {
        var calls = new List<(int, bool)>(); var ticks = new Queue<long>([200, 900]);
        var phase = await BenchmarkMeasurements.RunAsync(3, 2, false, () => ticks.Dequeue(), () => { calls.Add((0, true)); return Task.FromResult<long?>(100); }, i =>
        {
            calls.Add((i, false)); return Task.FromResult(new BenchmarkTimingSample(i, 1000, 10, 3, 1013));
        }, (i, ct) => throw new InvalidOperationException("unexpected ingestion"));
        Assert.Equal(new[] { 0, 0, 1, 0, 1, 2 }, calls.Select(x => x.Item1));
        Assert.Equal(new[] { true, false, false, false, false, false }, calls.Select(x => x.Item2));
        Assert.Equal(100, phase.ColdCacheLoadUs);
        Assert.Equal(new long[] { 10, 10, 10 }, phase.Samples.Select(x => x.RetrievalUs));
        Assert.Equal(0, phase.CompletedWrites); Assert.Equal(0, phase.OverlapUs);
    }

    [Fact]
    public async Task InvalidCountsAndNegativeColdLoadAreRejected()
    {
        Task<BenchmarkTimingSample> Query(int i) => Task.FromResult(new BenchmarkTimingSample(i, 1, 1, 1, 3));
        Task Write(int i, CancellationToken ct) => Task.CompletedTask;
        Assert.Equal("invalidSamples", (await Assert.ThrowsAsync<BenchmarkException>(() =>
            BenchmarkMeasurements.RunAsync(0, 0, false, () => 0, () => Task.FromResult<long?>(null), Query, Write))).Code);
        Assert.Equal("invalidSamples", (await Assert.ThrowsAsync<BenchmarkException>(() =>
            BenchmarkMeasurements.RunAsync(1, -1, false, () => 0, () => Task.FromResult<long?>(null), Query, Write))).Code);
        Assert.Equal("invalidSamples", (await Assert.ThrowsAsync<BenchmarkException>(() =>
            BenchmarkMeasurements.RunAsync(1, 0, false, () => 0, () => Task.FromResult<long?>(-1), Query, Write))).Code);
        var backwards = new Queue<long>([9, 3]);
        Assert.Equal("invalidSamples", (await Assert.ThrowsAsync<BenchmarkException>(() =>
            BenchmarkMeasurements.RunAsync(1, 0, false, () => backwards.Dequeue(), () => Task.FromResult<long?>(null), Query, Write))).Code);
    }

    [Fact]
    public void SharedOverlapCases()
    {
        int n = 0;
        foreach (var c in Cases("overlap"))
        {
            var i = c.GetProperty("input");
            var completions = i.GetProperty("completionsUs").EnumerateArray().Select(x => x.GetInt64()).ToArray();
            (int, long) Run() => BenchmarkMeasurements.Overlap(completions, i.GetProperty("measuredStartUs").GetInt64(), i.GetProperty("measuredEndUs").GetInt64());
            if (c.TryGetProperty("error", out var error)) Assert.Equal(error.GetString(), Code(() => Run()));
            else
            {
                var (writes, overlap) = Run();
                Assert.Equal(c.GetProperty("expected").GetProperty("completedWrites").GetInt32(), writes);
                Assert.Equal(c.GetProperty("expected").GetProperty("overlapUs").GetInt64(), overlap);
            }
            n++;
        }
        Assert.Equal(3, n);
    }

    [Fact]
    public async Task ConcurrentWriterMustCompleteDuringMeasuredQueries()
    {
        // Barrier-controlled writer: each write completes only when a measured query releases it.
        long clock = 0;
        int calls = 0;
        var gates = new Queue<TaskCompletionSource>();
        int completed = 0;
        async Task Write(int batch, CancellationToken ct)
        {
            var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (gates) gates.Enqueue(gate);
            await gate.Task.WaitAsync(ct);
            Interlocked.Increment(ref completed);
        }
        async Task<BenchmarkTimingSample> Query(int i)
        {
            Interlocked.Add(ref clock, 10);
            if (Interlocked.Increment(ref calls) <= 1) return new BenchmarkTimingSample(i, 1, 1, 1, 3); // warmup
            TaskCompletionSource? gate = null;
            while (gate is null)
            {
                lock (gates) if (gates.Count > 0) gate = gates.Dequeue();
                if (gate is null) await Task.Yield();
            }
            int before = Volatile.Read(ref completed);
            gate.TrySetResult();
            while (Volatile.Read(ref completed) == before) await Task.Yield();
            return new BenchmarkTimingSample(i, 1, 1, 1, 3);
        }
        var phase = await BenchmarkMeasurements.RunAsync(3, 1, true, () => Interlocked.Read(ref clock), () => Task.FromResult<long?>(5), Query, Write);
        Assert.True(phase.CompletedWrites >= 2, phase.CompletedWrites.ToString());
        Assert.True(phase.OverlapUs > 0);
        Assert.Equal(3, phase.Samples.Count);

        // A writer that never completes inside the measured window fails the row.
        var none = await Assert.ThrowsAsync<BenchmarkException>(() => BenchmarkMeasurements.RunAsync(2, 0, true, () => 0,
            () => Task.FromResult<long?>(null), i => Task.FromResult(new BenchmarkTimingSample(i, 1, 1, 1, 3)),
            async (b, ct) => await Task.Delay(Timeout.Infinite, ct)));
        Assert.Equal("insufficientIngestionOverlap", none.Code);
    }

    [Fact]
    public async Task WriterErrorsPropagateAndCancellationAwaitsTheWriter()
    {
        // Barriers make the writer observably start before the measured queries finish.
        var writerFailed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var failing = await Assert.ThrowsAsync<InvalidOperationException>(() => BenchmarkMeasurements.RunAsync(2, 0, true, () => 0,
            () => Task.FromResult<long?>(null), async i => { await writerFailed.Task; return new BenchmarkTimingSample(i, 1, 1, 1, 3); },
            (b, ct) => { writerFailed.TrySetResult(); throw new InvalidOperationException("writer"); }));
        Assert.Equal("writer", failing.Message);

        using var cts = new CancellationTokenSource();
        var writerEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var writerExited = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task Write(int b, CancellationToken ct)
        {
            writerEntered.TrySetResult();
            try { await Task.Delay(Timeout.Infinite, ct); }
            finally { writerExited.TrySetResult(); }
        }
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => BenchmarkMeasurements.RunAsync(5, 0, true, () => 0,
            () => Task.FromResult<long?>(null), async i =>
            {
                await writerEntered.Task;
                if (i == 1) cts.Cancel();
                return new BenchmarkTimingSample(i, 1, 1, 1, 3);
            }, Write, cts.Token));
        Assert.True(writerExited.Task.IsCompleted, "the writer must be awaited before the phase returns");
    }

    [Fact]
    public async Task SharedColdCacheAdmission()
    {
        int n = 0;
        foreach (var c in Cases("cache"))
        {
            var i = c.GetProperty("input");
            var ticks = new Queue<long>(i.GetProperty("coldTicksUs").EnumerateArray().Select(x => x.GetInt64()));
            int fills = 0;
            var result = await BenchmarkMeasurements.ColdCacheLoadAsync(i.GetProperty("chunks").GetInt32(), i.GetProperty("dims").GetInt32(),
                i.GetProperty("budgetBytes").GetInt64(), () => ticks.Dequeue(), () => { fills++; return Task.CompletedTask; });
            var e = c.GetProperty("expected");
            Assert.Equal(e.GetProperty("chargeBytes").GetInt64(), result.ChargeBytes);
            Assert.Equal(e.GetProperty("cacheMode").GetString(), result.CacheMode);
            Assert.Equal(e.GetProperty("coldCacheLoadUs").ValueKind == JsonValueKind.Null ? null : e.GetProperty("coldCacheLoadUs").GetInt64(), result.ColdCacheLoadUs);
            Assert.Equal(result.CacheMode == "cached" ? 1 : 0, fills);
            n++;
        }
        Assert.Equal(3, n);
    }

    [Fact]
    public void SharedRoundingAndFnv()
    {
        int n = 0;
        foreach (var c in Cases("rounding"))
        {
            Assert.Equal(c.GetProperty("expected").GetProperty("us").GetInt64(),
                BenchmarkMeasurements.MillisecondsToMicroseconds(c.GetProperty("input").GetProperty("ms").GetDouble()));
            n++;
        }
        foreach (var c in Cases("fnv"))
        {
            Assert.Equal(c.GetProperty("expected").GetUInt32(), BenchmarkMeasurements.Fnv1a32(c.GetProperty("input").GetString()!));
            n++;
        }
        Assert.Equal(7, n);
        Assert.Equal(1_000_000, BenchmarkMeasurements.TicksToMicroseconds(10_000_000, 10_000_000));
        Assert.Equal(long.MaxValue / 1000, BenchmarkMeasurements.TicksToMicroseconds(long.MaxValue, 1_000_000_000));
    }

    private static CalibrationRequest Request(string id, string kind, string split, string text, string language = "cs") =>
        new(id, "ollama:sha256:" + new string('a', 64), language, split, kind, text,
            kind == "prompt" ? [new ChatTurn(ChatRole.User, text)] : []);

    [Fact]
    public async Task CalibrationMapsObservedChatCountsAndKeepsPromptsOutOfTraining()
    {
        var requests = new[]
        {
            Request("cs-a:0:3", "body", "train", "abc"),
            Request("cs-b:0:4", "body", "holdout", "abcd"),
            Request("prompt:q1", "prompt", "holdout", "Q😀"),
        };
        var seen = new List<string>();
        var rows = await BenchmarkMeasurements.CalibrateAsync(requests, "sha256:" + new string('a', 64), (r, ct) =>
        {
            seen.Add(r.Id);
            // Chat counts deliberately differ from any embedding count of the same text.
            return Task.FromResult(new ChatTokenObservation("x", r.Kind == "prompt" ? 40 : r.Text.Length + 1, 1));
        });
        Assert.Equal(requests.Select(r => r.Id), seen);
        Assert.Equal(["ollama-raw-prompt", "ollama-raw-prompt", "ollama-chat-prompt"], rows.Select(r => r.Method));
        Assert.Equal(2, rows[2].Sample.Scalars);
        Assert.Equal(EvalCorpus.Sha256(System.Text.Encoding.UTF8.GetBytes("Q😀")), rows[2].TextHash);
        Assert.All(rows, r => Assert.Null(r.TokenizerRevision));
        var training = TokenCalibration.TrainingSamples(rows.Select(r => new TokenObservation(r.Kind, r.Method, r.Sample)));
        Assert.Equal(["cs-a:0:3"], training.Select(s => s.Id));
        Assert.Equal([new TokenRate(requests[0].Family, "cs", 13334)], TokenCalibration.Fit(training));
    }

    [Fact]
    public async Task CalibrationRejectsMissingNegativeDuplicateAndPropagatesCancellation()
    {
        var digest = "sha256:" + new string('a', 64);
        async Task<string> Fail(CalibrationRequest[] requests, int? count) =>
            (await Assert.ThrowsAsync<BenchmarkException>(() => BenchmarkMeasurements.CalibrateAsync(requests, digest,
                (r, ct) => Task.FromResult(new ChatTokenObservation("x", count, 1))))).Code;
        Assert.Equal("tokenCountUnavailable", await Fail([Request("a", "body", "train", "abc")], null));
        Assert.Equal("invalidTokenCount", await Fail([Request("a", "body", "train", "abc")], -1));
        Assert.Equal("invalidCalibration", await Fail([Request("a", "body", "train", "abc"), Request("a", "body", "train", "abd")], 3));
        Assert.Equal("invalidCalibration", await Fail([Request("a", "embedding", "train", "abc")], 3));
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => BenchmarkMeasurements.CalibrateAsync(
            [Request("a", "body", "train", "abc")], digest, (r, ct) => Task.FromResult(new ChatTokenObservation("x", 1, 1)), cts.Token));
    }
}

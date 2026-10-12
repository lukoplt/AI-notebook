using System.Text.Json;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using AINotebook.Core.Tests.Rag;
using Xunit;

namespace AINotebook.Core.Tests.Providers;

public sealed class StrictEmbeddingPipelineTests
{
    private static readonly JsonElement Root = SharedFixtures.Json("contracts/embedding-strict-v1.json");

    private static IEnumerable<JsonElement> Cases(string kind) =>
        Root.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("kind").GetString() == kind);

    internal static EmbeddingProfile Profile(JsonElement p) => new(
        p.GetProperty("id").GetString()!, p.GetProperty("model").GetString()!, p.GetProperty("tokenizerId").GetString()!,
        p.GetProperty("queryPrefix").GetString()!, p.GetProperty("documentPrefix").GetString()!,
        p.GetProperty("nativeDims").GetInt32(), p.GetProperty("dims").GetInt32(), p.GetProperty("maxInputTokens").GetInt32(),
        p.GetProperty("matryoshka").GetBoolean());

    private static EmbeddingPurpose Purpose(string value) =>
        value == "query" ? EmbeddingPurpose.Query : value == "document" ? EmbeddingPurpose.Document
            : throw new InvalidOperationException(value);

    private static int? NullableInt(JsonElement e) => e.ValueKind == JsonValueKind.Null ? null : e.GetInt32();
    private static long? NullableLong(JsonElement e) => e.ValueKind == JsonValueKind.Null ? null : e.GetInt64();

    private sealed class CounterTransport : IStrictEmbeddingTransport
    {
        public int Requests;
        public Task<StrictEmbeddingResult> EmbedAsync(string model, string input, int nativeDims, int inputLimit, CancellationToken ct = default)
        {
            ct.ThrowIfCancellationRequested(); Requests++;
            int n = input.EnumerateRunes().Count();
            if (n > 5) throw new EmbeddingInputTooLongException();
            return Task.FromResult(new StrictEmbeddingResult([1, 0], n, 1000, 0));
        }
    }

    private sealed class ScriptedTransport(JsonElement[] exchanges, EmbeddingProfile profile, int limit) : IStrictEmbeddingTransport
    {
        public int Requests;
        public Task<StrictEmbeddingResult> EmbedAsync(string model, string input, int nativeDims, int inputLimit, CancellationToken ct = default)
        {
            Assert.True(Requests < exchanges.Length, "unscripted request");
            var x = exchanges[Requests++];
            Assert.Equal(x.GetProperty("input").GetString(), input);
            Assert.Equal(profile.Model, model);
            Assert.Equal(profile.NativeDims, nativeDims);
            Assert.Equal(limit, inputLimit);
            return x.GetProperty("outcome").GetString() switch
            {
                "ok" => Task.FromResult(new StrictEmbeddingResult(EmbeddingProfileTests.Vector(x.GetProperty("vector")),
                    NullableInt(x.GetProperty("promptTokens")), null, null)),
                "lengthRejected" => throw new EmbeddingInputTooLongException(),
                "httpError" => throw new EmbeddingProfileException("providerError", x.GetProperty("status").GetInt32()),
                "cancel" => throw new OperationCanceledException(),
                var o => throw new InvalidOperationException(o),
            };
        }
    }

    private sealed class FixtureCounter(JsonElement counts) : IExactTokenCounter
    {
        public readonly List<(string Text, string TokenizerId)> Calls = [];
        public Task<int> CountAsync(string text, string tokenizerId, CancellationToken ct = default)
        {
            Calls.Add((text, tokenizerId));
            return Task.FromResult(counts.GetProperty(text).GetInt32());
        }
    }

    internal sealed class RecordingObserver : IEmbeddingTelemetryObserver
    {
        public readonly List<EmbeddingTelemetryEvent> Events = [];
        public ValueTask RecordAsync(EmbeddingTelemetryEvent observation) { lock (Events) Events.Add(observation); return ValueTask.CompletedTask; }
    }

    internal static EmbeddingTelemetryEvent Event(JsonElement e) => new(e.GetProperty("kind").GetString()!,
        Purpose(e.GetProperty("purpose").GetString()!), NullableInt(e.GetProperty("tokens")),
        NullableInt(e.GetProperty("start")), NullableInt(e.GetProperty("end")));

    internal static void AssertSnapshot(JsonElement expected, EmbeddingTelemetrySnapshot actual, string name)
    {
        Assert.True(NullableLong(expected.GetProperty("serviceTokens")) == actual.ServiceTokens, name);
        Assert.Equal(expected.GetProperty("successfulTokens").GetInt64(), actual.SuccessfulTokens);
        Assert.Equal(expected.GetProperty("requestCount").GetInt32(), actual.RequestCount);
        Assert.Equal(expected.GetProperty("rejectedRequests").GetInt32(), actual.RejectedRequests);
        Assert.Equal(expected.GetProperty("splitParts").GetInt32(), actual.SplitParts);
        Assert.Equal(expected.GetProperty("uncountedRequests").GetInt32(), actual.UncountedRequests);
        Assert.Equal(expected.GetProperty("serviceTokenStatus").GetString(), actual.ServiceTokenStatus);
    }

    [Fact]
    public async Task SplitKeepsEveryScalarAndCountsPrefixes()
    {
        var t = new CounterTransport();
        var p = new EmbeddingProfile("fixture", "fixture", "fixture-only", "q:", "", 2, 2, 5, false);
        var r = await new StrictEmbeddingPipeline(t).EmbedAsync("ab😀cd", p, EmbeddingPurpose.Query, 5);
        Assert.Equal(new[] { 0, 2 }, r.Parts.Select(x => x.Start));
        Assert.Equal(new[] { 2, 5 }, r.Parts.Select(x => x.End));
        Assert.Equal(9, r.SuccessfulTokens); Assert.Equal(1, r.RejectedRequests); Assert.Equal(3, t.Requests);
    }

    [Fact]
    public async Task SharedPipelineCases()
    {
        int n = 0;
        foreach (var c in Cases("pipeline"))
        {
            string name = c.GetProperty("name").GetString()!;
            var profile = Profile(c.GetProperty("profile"));
            int limit = c.GetProperty("effectiveLimit").GetInt32();
            var purpose = Purpose(c.GetProperty("purpose").GetString()!);
            var transport = new ScriptedTransport(c.GetProperty("exchanges").EnumerateArray().ToArray(), profile, limit);
            var counter = c.GetProperty("counter").ValueKind == JsonValueKind.Null ? null : new FixtureCounter(c.GetProperty("counter"));
            var observer = new RecordingObserver();
            var expected = c.GetProperty("expected");
            var pipeline = new StrictEmbeddingPipeline(transport, counter, observer);
            EmbeddedInput? result = null;
            string? error = null;
            try { result = await pipeline.EmbedAsync(c.GetProperty("text").GetString()!, profile, purpose, limit); }
            catch (EmbeddingProfileException e) { error = e.Code; }
            catch (OperationCanceledException) { error = "cancelled"; }

            Assert.True(expected.GetProperty("error").ValueKind == JsonValueKind.Null
                ? error is null : expected.GetProperty("error").GetString() == error, $"{name}: {error}");
            Assert.Equal(expected.GetProperty("requestCount").GetInt32(), transport.Requests);
            Assert.Equal(c.GetProperty("exchanges").GetArrayLength(), transport.Requests);
            Assert.Equal(expected.GetProperty("events").EnumerateArray().Select(Event), observer.Events);
            Assert.Equal(expected.GetProperty("counterCalls").EnumerateArray()
                    .Select(x => (x.GetProperty("text").GetString()!, x.GetProperty("tokenizerId").GetString()!)),
                counter?.Calls ?? []);
            AssertSnapshot(expected.GetProperty("telemetry"), EmbeddingTelemetrySnapshot.FromEvents(observer.Events, purpose), name);
            if (result is not null)
            {
                Assert.Equal(expected.GetProperty("parts").EnumerateArray().Select(x => new EmbeddedPart(
                    x.GetProperty("start").GetInt32(), x.GetProperty("end").GetInt32(), x.GetProperty("tokens").GetInt32())), result.Parts);
                Assert.Equal(expected.GetProperty("successfulTokens").GetInt32(), result.SuccessfulTokens);
                Assert.Equal(expected.GetProperty("rejectedRequests").GetInt32(), result.RejectedRequests);
                EmbeddingProfileTests.AssertMillionths(expected.GetProperty("vectorMillionths"), result.Vector);
            }
            n++;
        }
        Assert.Equal(16, n);
    }

    [Fact]
    public void SharedTelemetrySnapshots()
    {
        int n = 0;
        foreach (var c in Cases("telemetry"))
        {
            var events = c.GetProperty("events").EnumerateArray().Select(Event).ToArray();
            var purpose = events[0].Purpose;
            AssertSnapshot(c.GetProperty("snapshot"), EmbeddingTelemetrySnapshot.FromEvents(events, purpose), c.GetProperty("name").GetString()!);
            // The other purpose sees none of these events.
            var other = EmbeddingTelemetrySnapshot.FromEvents(events, purpose == EmbeddingPurpose.Query ? EmbeddingPurpose.Document : EmbeddingPurpose.Query);
            Assert.Equal(0, other.RequestCount);
            Assert.Equal("measured", other.ServiceTokenStatus);
            n++;
        }
        Assert.Equal(2, n);
    }

    private sealed class BlockingTransport : IStrictEmbeddingTransport
    {
        public int Requests;
        public readonly TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public async Task<StrictEmbeddingResult> EmbedAsync(string model, string input, int nativeDims, int inputLimit, CancellationToken ct = default)
        {
            Interlocked.Increment(ref Requests);
            Entered.TrySetResult();
            await Task.Delay(Timeout.Infinite, ct);
            throw new InvalidOperationException("unreachable");
        }
    }

    [Fact]
    public async Task CancellationDuringRequestSendsNoSecondRequestAndPoolsNothing()
    {
        var transport = new BlockingTransport();
        var observer = new RecordingObserver();
        var p = new EmbeddingProfile("fixture", "fixture", "fixture-only", "q:", "", 2, 2, 5, false);
        using var cts = new CancellationTokenSource();
        var task = new StrictEmbeddingPipeline(transport, null, observer).EmbedAsync("ab😀cd", p, EmbeddingPurpose.Query, 5, cts.Token);
        await transport.Entered.Task;
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);
        Assert.Equal(1, transport.Requests);
        Assert.Equal(["request"], observer.Events.Select(e => e.Kind));
    }

    [Fact]
    public async Task PreCancelledTokenSendsNothing()
    {
        var transport = new CounterTransport();
        var p = new EmbeddingProfile("fixture", "fixture", "fixture-only", "q:", "", 2, 2, 5, false);
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new StrictEmbeddingPipeline(transport).EmbedAsync("abc", p, EmbeddingPurpose.Query, 5, cts.Token));
        Assert.Equal(0, transport.Requests);
    }

    [Fact]
    public async Task InvalidTextAndNegativeFallbackCountsAreRejected()
    {
        var p = new EmbeddingProfile("fixture", "fixture", "fixture-only", "q:", "", 2, 2, 5, false);
        var transport = new CounterTransport();
        var e = await Assert.ThrowsAsync<EmbeddingProfileException>(() =>
            new StrictEmbeddingPipeline(transport).EmbedAsync("a\uD800", p, EmbeddingPurpose.Query, 5));
        Assert.Equal("invalidText", e.Code);
        Assert.Equal(0, transport.Requests);

        var noCount = new NoCountTransport();
        e = await Assert.ThrowsAsync<EmbeddingProfileException>(() =>
            new StrictEmbeddingPipeline(noCount, new ConstantCounter(-3)).EmbedAsync("abc", p, EmbeddingPurpose.Query, 5));
        Assert.Equal("invalidTokenCount", e.Code);
    }

    private sealed class NoCountTransport : IStrictEmbeddingTransport
    {
        public Task<StrictEmbeddingResult> EmbedAsync(string model, string input, int nativeDims, int inputLimit, CancellationToken ct = default) =>
            Task.FromResult(new StrictEmbeddingResult([1, 0], null, null, null));
    }

    private sealed class ConstantCounter(int value) : IExactTokenCounter
    {
        public Task<int> CountAsync(string text, string tokenizerId, CancellationToken ct = default) => Task.FromResult(value);
    }
}

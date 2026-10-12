using System.Collections.Concurrent;
using System.Text;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;

namespace AINotebook.Core.Eval;

public sealed record BenchmarkPhaseMeasurement(long? ColdCacheLoadUs, IReadOnlyList<BenchmarkTimingSample> Samples,
    int CompletedWrites, long OverlapUs);

/// <summary><c>Kind</c> is <c>body</c> (raw prompt observation) or <c>prompt</c> (complete rendered chat request).</summary>
public sealed record CalibrationRequest(string Id, string Family, string Language, string Split, string Kind, string Text,
    IReadOnlyList<ChatTurn> Messages);

public sealed record CalibrationObservation(TokenSample Sample, string Kind, string TextHash, string Method, string ModelDigest,
    string? TokenizerRevision, string? AssetsSha256);

public sealed record ColdCacheMeasurement(long ChargeBytes, string CacheMode, long? ColdCacheLoadUs);

/// <summary>Phase timing and count observations (benchmark-v1 §8). Callbacks own all I/O.</summary>
public static class BenchmarkMeasurements
{
    /// <summary>
    /// One cold callback, then warmups, then measured queries. Concurrent rows run a writer child
    /// after warmup, always cancelled and awaited; only completions inside the measured window count.
    /// </summary>
    public static async Task<BenchmarkPhaseMeasurement> RunAsync(int queries, int warmup, bool concurrent,
        Func<long> nowUs, Func<Task<long?>> coldLoad, Func<int, Task<BenchmarkTimingSample>> runQuery,
        Func<int, CancellationToken, Task> writeBatch, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(nowUs);
        ArgumentNullException.ThrowIfNull(coldLoad);
        ArgumentNullException.ThrowIfNull(runQuery);
        ArgumentNullException.ThrowIfNull(writeBatch);
        if (queries <= 0 || warmup < 0) throw new BenchmarkException("invalidSamples");
        ct.ThrowIfCancellationRequested();
        long? coldElapsed = await coldLoad().ConfigureAwait(false);
        if (coldElapsed < 0) throw new BenchmarkException("invalidSamples");
        for (int i = 0; i < warmup; i++)
        {
            ct.ThrowIfCancellationRequested();
            await runQuery(i).ConfigureAwait(false);
        }
        if (!concurrent)
        {
            var (start, samples, end) = await MeasureAsync(queries, nowUs, runQuery, ct).ConfigureAwait(false);
            if (start > end) throw new BenchmarkException("invalidSamples");
            return new BenchmarkPhaseMeasurement(coldElapsed, samples, 0, 0);
        }

        var completions = new ConcurrentQueue<long>();
        using var writerCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var writer = Task.Run(async () =>
        {
            for (int batch = 0; ; batch++)
            {
                writerCts.Token.ThrowIfCancellationRequested();
                await writeBatch(batch, writerCts.Token).ConfigureAwait(false);
                completions.Enqueue(nowUs());
                await Task.Yield();
            }
        }, CancellationToken.None);
        (long Start, List<BenchmarkTimingSample> Samples, long End) measured;
        try
        {
            measured = await MeasureAsync(queries, nowUs, runQuery, ct).ConfigureAwait(false);
        }
        finally
        {
            writerCts.Cancel();
            try { await writer.ConfigureAwait(false); }
            catch (OperationCanceledException) when (writerCts.IsCancellationRequested) { /* the expected stop */ }
        }
        if (measured.Start > measured.End) throw new BenchmarkException("invalidSamples");
        var (writes, overlap) = Overlap(completions.ToArray(), measured.Start, measured.End);
        return new BenchmarkPhaseMeasurement(coldElapsed, measured.Samples, writes, overlap);
    }

    private static async Task<(long Start, List<BenchmarkTimingSample> Samples, long End)> MeasureAsync(int queries,
        Func<long> nowUs, Func<int, Task<BenchmarkTimingSample>> runQuery, CancellationToken ct)
    {
        long start = nowUs();
        var samples = new List<BenchmarkTimingSample>(queries);
        for (int i = 0; i < queries; i++)
        {
            ct.ThrowIfCancellationRequested();
            samples.Add(await runQuery(i).ConfigureAwait(false));
        }
        long end = nowUs();
        return (start, samples, end);
    }

    /// <summary>Writer completions inside <c>[start, end]</c>; fewer than two or a zero span is insufficient.</summary>
    public static (int CompletedWrites, long OverlapUs) Overlap(IReadOnlyList<long> completionsUs, long measuredStartUs, long measuredEndUs)
    {
        var inside = completionsUs.Where(t => t >= measuredStartUs && t <= measuredEndUs).Order().ToArray();
        if (inside.Length < 2 || inside[^1] - inside[0] <= 0) throw new BenchmarkException("insufficientIngestionOverlap");
        return (inside.Length, inside[^1] - inside[0]);
    }

    /// <summary>
    /// Application-cache cold load: admission charge <c>rows·(dims·4 + 32)</c> against the budget;
    /// a refused matrix is <c>streamed</c> with no cold time. Never flushes OS caches.
    /// </summary>
    public static async Task<ColdCacheMeasurement> ColdCacheLoadAsync(int chunks, int dims, long budgetBytes,
        Func<long> nowUs, Func<Task> fill)
    {
        if (chunks < 0 || dims <= 0 || budgetBytes < 0) throw new BenchmarkException("invalidSamples");
        long charge = checked((long)chunks * ((long)dims * 4 + 32));
        if (charge > budgetBytes) return new(charge, "streamed", null);
        long start = nowUs();
        await fill().ConfigureAwait(false);
        long elapsed = nowUs() - start;
        if (elapsed < 0) throw new BenchmarkException("invalidSamples");
        return new(charge, "cached", elapsed);
    }

    /// <summary>
    /// Each request is observed exactly once. Only provider counts are mapped here; a missing count
    /// is <c>tokenCountUnavailable</c> (a documented-tokenizer fallback is resolved by the caller).
    /// </summary>
    public static async Task<IReadOnlyList<CalibrationObservation>> CalibrateAsync(IReadOnlyList<CalibrationRequest> requests,
        string modelDigest, Func<CalibrationRequest, CancellationToken, Task<ChatTokenObservation>> observe, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(requests);
        ArgumentNullException.ThrowIfNull(observe);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var r in requests)
            if (r is null || r.Kind is not ("body" or "prompt") || r.Split is not ("train" or "holdout") || !ids.Add(r.Id))
                throw new BenchmarkException("invalidCalibration");
        var rows = new List<CalibrationObservation>(requests.Count);
        foreach (var request in requests)
        {
            ct.ThrowIfCancellationRequested();
            var observed = await observe(request, ct).ConfigureAwait(false);
            if (observed.PromptTokens is not int count) throw new BenchmarkException("tokenCountUnavailable");
            if (count < 0) throw new BenchmarkException("invalidTokenCount");
            var sample = new TokenSample(request.Id, request.Family, request.Language, request.Split,
                EmbeddingInput.ScalarCount(request.Text), count);
            rows.Add(new(sample, request.Kind, EvalCorpus.Sha256(Encoding.UTF8.GetBytes(request.Text)),
                request.Kind == "body" ? ChatTokenMethods.OllamaRawPrompt : ChatTokenMethods.OllamaChatPrompt, modelDigest, null, null));
        }
        return rows;
    }

    /// <summary>CLI milliseconds → integer microseconds, rounding half away from zero.</summary>
    public static long MillisecondsToMicroseconds(double ms)
    {
        if (!double.IsFinite(ms)) throw new BenchmarkException("invalidSamples");
        double v = ms * 1000;
        return checked((long)Math.Floor(Math.Abs(v) + 0.5)) * (v >= 0 ? 1 : -1);
    }

    /// <summary>Stopwatch ticks → microseconds by quotient/remainder, without intermediate overflow.</summary>
    public static long TicksToMicroseconds(long ticks, long frequency)
    {
        if (ticks < 0 || frequency <= 0) throw new BenchmarkException("invalidSamples");
        return checked(ticks / frequency * 1_000_000 + ticks % frequency * 1_000_000 / frequency);
    }

    /// <summary>FNV-1a 32 over UTF-8 (the fixture-mode transport's deterministic index).</summary>
    public static uint Fnv1a32(string text)
    {
        uint hash = 2166136261;
        foreach (byte b in Encoding.UTF8.GetBytes(text)) hash = unchecked((hash ^ b) * 16777619);
        return hash;
    }
}

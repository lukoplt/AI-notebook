using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Eval;

/// <summary>Typed WP7 benchmark/calibration error; <see cref="Code"/> is the contract code (benchmark-v1).</summary>
public sealed class BenchmarkException(string code) : Exception("BenchmarkError(" + code + ")")
{
    public string Code { get; } = code;
}

/// <summary>Shared JSON conventions: camelCase outer fields, snake_case WP1 eval objects, explicit nulls.</summary>
public static class BenchmarkJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        RespectNullableAnnotations = true,
    };

    public static readonly JsonSerializerOptions SnakeOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>UTF-8 without BOM, ordinally sorted keys, indent 2, explicit nulls and one final LF.</summary>
    public static byte[] Bytes<T>(T value)
    {
        var element = JsonSerializer.SerializeToElement(value, Options);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions
        {
            Indented = true,
            NewLine = "\n",
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        }))
        {
            WriteSorted(writer, element);
        }
        stream.WriteByte((byte)'\n');
        return stream.ToArray();
    }

    private static void WriteSorted(Utf8JsonWriter writer, JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var property in value.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(property.Name);
                    WriteSorted(writer, property.Value);
                }
                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in value.EnumerateArray()) WriteSorted(writer, item);
                writer.WriteEndArray();
                break;
            default:
                value.WriteTo(writer);
                break;
        }
    }
}

/// <summary>Serializes one embedded WP1 value with snake_case names inside a camelCase document.</summary>
public sealed class SnakeCaseJsonConverter<T> : JsonConverter<T>
{
    public override T? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        JsonSerializer.Deserialize<T>(ref reader, BenchmarkJson.SnakeOptions);

    public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options) =>
        JsonSerializer.Serialize(writer, value, BenchmarkJson.SnakeOptions);
}

/// <summary>Markdown text rules shared by benchmark and calibration reports (benchmark-v1 §6.4).</summary>
public static class BenchmarkMarkdown
{
    public static string Escape(string text) => text.Replace("\\", "\\\\").Replace("|", "\\|")
        .Replace("\r\n", "<br>").Replace("\r", "<br>").Replace("\n", "<br>");

    public static string Value(string? value) => value is null ? "not measured" : Escape(value);
    public static string Value(long? value) => value is null ? "not measured" : value.Value.ToString(CultureInfo.InvariantCulture);
    public static string Value(bool? value) => value is null ? "not measured" : value.Value ? "yes" : "no";

    public static string Recall(EvalMetric metric) => metric.RecallBp is not int bp ? "not measured"
        : (bp / 100).ToString(CultureInfo.InvariantCulture) + "." + (bp % 100).ToString("00", CultureInfo.InvariantCulture) + "%";

    public static string? Milli(long? value) => value is not long v ? null
        : (v / 1000).ToString(CultureInfo.InvariantCulture) + "." + (v % 1000).ToString("000", CultureInfo.InvariantCulture);

    public static string Unit(long? value, string suffix) =>
        value is null ? "not measured" : value.Value.ToString(CultureInfo.InvariantCulture) + " " + suffix;

    public static string Unit(string? value, string suffix) => value is null ? "not measured" : value + " " + suffix;

    public static string Int(long value) => value.ToString(CultureInfo.InvariantCulture);
}

/// <summary>Deterministic integer report math (benchmark-v1 §6.2).</summary>
public static class BenchmarkMath
{
    public const long WarmGateUs = 300_000;

    public static long CeilDiv(long a, long b) => a / b + (a % b == 0 ? 0 : 1);

    /// <summary>Nearest rank: <c>sorted[ceilDiv(n·bp, 10000) − 1]</c>.</summary>
    public static long Percentile(IReadOnlyList<long> samples, int bp)
    {
        ArgumentNullException.ThrowIfNull(samples);
        if (samples.Count == 0 || bp < 1 || bp > 10000 || samples.Any(x => x < 0))
            throw new BenchmarkException("invalidSamples");
        var sorted = samples.Order().ToArray();
        return sorted[checked((int)(CeilDiv((long)sorted.Length * bp, 10000) - 1))];
    }

    public static long? TokensPerSecondMilli(long tokens, long elapsedUs)
    {
        if (tokens < 0 || elapsedUs < 0 || tokens > long.MaxValue / 1_000_000_000)
            throw new BenchmarkException("invalidSamples");
        return elapsedUs == 0 ? null : tokens * 1_000_000_000 / elapsedUs;
    }

    /// <summary>Null unless 100K chunks, non-concurrent and 200 queries; then strictly below 300 000 µs.</summary>
    public static bool? WarmGate(int chunks, bool concurrent, int queries, long p95Us) =>
        chunks != 100_000 || concurrent || queries != 200 ? null : p95Us < WarmGateUs;
}

public sealed record BenchmarkEnvironment(string? Cpu, long? RamBytes, string? Os, string? Architecture,
    string? BuildCommit, string? OllamaVersion, string? Accelerator);

public sealed record BenchmarkCorpus(string Id, string Hash, int Documents, int Queries, string ChunkerVersion);

public sealed record BenchmarkParameters(int FetchK, int TopK, int EvidenceShareBp, int RuntimeContext,
    int MaxOutputTokens, long Seed);

public sealed record BenchmarkChat(string Model, string? ModelDigest, string? TokenFamily, string? ShowTemplateSha256);

public sealed record BenchmarkSpan(long Start, long End);

/// <summary>CitationsCodec v2 item form; null optionals are omitted.</summary>
public sealed record BenchmarkCitation(
    int Marker, long ChunkId, long SourceId, string Snippet,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] long? FolderId,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? RelPath,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? DisplayName,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] long? RevisionId,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<BenchmarkSpan>? Spans,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<long>? ChunkIds,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Text)
{
    public static BenchmarkCitation From(Citation c) => new(c.Marker, c.ChunkId, c.SourceId, c.Snippet, c.FolderId,
        c.RelPath, c.DisplayName, c.RevisionId, c.Spans.Count == 0 ? null : c.Spans.Select(s => new BenchmarkSpan(s.Start, s.End)).ToArray(),
        c.ChunkIds.Count == 0 ? null : c.ChunkIds.ToArray(), c.Text);
}

public sealed record BenchmarkTiming(long EmbeddingUs, long RetrievalUs, long HydrationUs, long EndToEndUs);

public sealed record BenchmarkOverview(int FilesInScope, int PublishedCandidateFiles, int FilesIncluded);

public sealed record BenchmarkQualityQuery(
    [property: JsonConverter(typeof(SnakeCaseJsonConverter<EvalQueryRow>))] EvalQueryRow Eval,
    [property: JsonConverter(typeof(SnakeCaseJsonConverter<IReadOnlyList<EvalSpan>>))] IReadOnlyList<EvalSpan> Packed,
    IReadOnlyList<BenchmarkCitation> CitationMap, string? AnswerText, string? PreparedHash,
    BenchmarkTiming? Timing, BenchmarkOverview? Overview);

public sealed record BenchmarkQuality(
    [property: JsonConverter(typeof(SnakeCaseJsonConverter<IReadOnlyDictionary<string, EvalMetric>>))]
    IReadOnlyDictionary<string, EvalMetric> Metrics,
    [property: JsonConverter(typeof(SnakeCaseJsonConverter<IReadOnlyDictionary<string, IReadOnlyDictionary<string, EvalMetric>>>))]
    IReadOnlyDictionary<string, IReadOnlyDictionary<string, EvalMetric>> ByLanguage,
    [property: JsonConverter(typeof(SnakeCaseJsonConverter<IReadOnlyDictionary<string, IReadOnlyDictionary<string, EvalMetric>>>))]
    IReadOnlyDictionary<string, IReadOnlyDictionary<string, EvalMetric>> ByCaseType,
    IReadOnlyList<BenchmarkQualityQuery> Queries)
{
    public static readonly IReadOnlyList<string> Languages = ["cs", "de", "en", "sk", "und", "mixed"];
    public static readonly IReadOnlyList<string> CaseTypes = ["answer", "exact_identifier", "scope", "absent", "empty_selection", "overview"];

    /// <summary>WP1 micro aggregation over the rows, with all six language and case-type keys.</summary>
    public static BenchmarkQuality Assemble(IReadOnlyList<BenchmarkQualityQuery> queries)
    {
        var (metrics, byLanguage, byCaseType) = Aggregates(queries);
        return new(metrics, byLanguage, byCaseType, queries.ToArray());
    }

    internal static (IReadOnlyDictionary<string, EvalMetric>, IReadOnlyDictionary<string, IReadOnlyDictionary<string, EvalMetric>>,
        IReadOnlyDictionary<string, IReadOnlyDictionary<string, EvalMetric>>) Aggregates(IReadOnlyList<BenchmarkQualityQuery> rows)
    {
        static IReadOnlyDictionary<string, EvalMetric> Agg(IEnumerable<BenchmarkQualityQuery> group)
        {
            var g = group.ToArray();
            return EvalMetrics.Names.ToDictionary(n => n, n => EvalMetrics.Aggregate(g.Select(r => Metric(r, n))), StringComparer.Ordinal);
        }
        return (Agg(rows),
            Languages.ToDictionary(l => l, l => Agg(rows.Where(r => r.Eval.Language == l)), StringComparer.Ordinal),
            CaseTypes.ToDictionary(t => t, t => Agg(rows.Where(r => r.Eval.CaseType == t)), StringComparer.Ordinal));
    }

    internal static EvalMetric Metric(BenchmarkQualityQuery row, string name) =>
        row.Eval.Metrics is { } m && m.TryGetValue(name, out var metric) && metric is not null
            ? metric : throw new BenchmarkException("invalidMetric");
}

public sealed record BenchmarkCitationCounts(int SnapshotsCorrect, int SnapshotsTotal, int AnswerMarkersCorrect,
    int AnswerMarkersTotal, int AnswerGoldSupported, int AnswerMarkersJudged, string SemanticReview);

public sealed record BenchmarkIngest(long? ServiceTokens, long? SuccessfulTokens, long? RejectedRequests, long? SplitParts,
    long? ElapsedUs, long? TokensPerSecondMilli, long? RunnerPeakRssBytes, long? ServerPeakRssBytes, long? CombinedPeakRssBytes,
    string ServiceTokenStatus, long? UncountedRequests, string? MemoryMethod, long? SampleIntervalMs);

public sealed record BenchmarkTimingSample(int QueryId, long EmbeddingUs, long RetrievalUs, long HydrationUs, long EndToEndUs);

public sealed record BenchmarkPerformance(int Chunks, bool Concurrent, int Queries, int WarmupQueries, long WarmP50Us,
    long WarmP95Us, long EndToEndP50Us, long EndToEndP95Us, long HydrationP95Us, long? ColdCacheLoadUs, string CacheMode,
    long ResidentBytes, long PeakPageBytes, int CompletedWrites, long OverlapUs, bool? GatePassed,
    IReadOnlyList<BenchmarkTimingSample> Samples)
{
    /// <summary>Summaries and gate recomputed from raw samples (the only way a row is assembled).</summary>
    public static BenchmarkPerformance FromSamples(int chunks, bool concurrent, int warmupQueries, IReadOnlyList<BenchmarkTimingSample> samples,
        long? coldCacheLoadUs, string cacheMode, long residentBytes, long peakPageBytes, int completedWrites, long overlapUs)
    {
        var warm = samples.Select(s => s.RetrievalUs).ToArray();
        var total = samples.Select(s => s.EndToEndUs).ToArray();
        long p95 = BenchmarkMath.Percentile(warm, 9500);
        return new(chunks, concurrent, samples.Count, warmupQueries, BenchmarkMath.Percentile(warm, 5000), p95,
            BenchmarkMath.Percentile(total, 5000), BenchmarkMath.Percentile(total, 9500),
            BenchmarkMath.Percentile(samples.Select(s => s.HydrationUs).ToArray(), 9500), coldCacheLoadUs, cacheMode,
            residentBytes, peakPageBytes, completedWrites, overlapUs, BenchmarkMath.WarmGate(chunks, concurrent, samples.Count, p95),
            samples.ToArray());
    }
}

public sealed record BenchmarkCandidate(string ProfileId, GenerationIdentity Identity, string Status, string? ErrorCode,
    BenchmarkQuality Quality, BenchmarkCitationCounts Citations, BenchmarkIngest Ingest, IReadOnlyList<BenchmarkPerformance> Performance);

/// <summary>The WP7 benchmark artifact (benchmark-v1 §6.1). JSON is structurally exact; Markdown is byte-exact.</summary>
public sealed record BenchmarkReportV1(string Contract, int Version, string Status, string Backend, string Mode, string Platform,
    BenchmarkEnvironment Environment, BenchmarkCorpus Corpus, string CalibrationHash, BenchmarkParameters Parameters,
    BenchmarkChat Chat, IReadOnlyList<BenchmarkCandidate> Candidates)
{
    public const string ContractName = "benchmark-report";
    public const string BackendName = "fts-or-pinned-rrf-v1";

    public byte[] JsonBytes() => BenchmarkJson.Bytes(this);

    internal static bool IsHex64(string? value) =>
        value is { Length: 64 } && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');

    internal static bool IsDigest(string? value) =>
        value is not null && value.StartsWith("sha256:", StringComparison.Ordinal) && IsHex64(value[7..]);

    /// <summary>benchmark-v1 §6.3, checked in order; the first failure's code is thrown.</summary>
    public void Validate()
    {
        if (Contract != ContractName || Version != 1 || Backend != BackendName || Status is not ("complete" or "incomplete")
            || Mode is not ("fixture" or "live") || Platform is not ("macos" or "windows"))
            throw new BenchmarkException("invalidReport");
        if (!IsHex64(Corpus?.Hash) || !IsHex64(CalibrationHash) || (Chat?.ModelDigest is not null && !IsDigest(Chat.ModelDigest)))
            throw new BenchmarkException("invalidHash");
        var p = Parameters ?? throw new BenchmarkException("invalidReport");
        if (!(0 < p.TopK && p.TopK <= p.FetchK && p.FetchK <= 1024 && p.EvidenceShareBp is >= 0 and <= 10000
              && 0 < p.MaxOutputTokens && p.MaxOutputTokens < p.RuntimeContext))
            throw new BenchmarkException("invalidReport");
        var ids = Candidates.Select(c => c.ProfileId).ToArray();
        if (ids.Distinct(StringComparer.Ordinal).Count() != ids.Length) throw new BenchmarkException("duplicateProfile");
        var catalog = EmbeddingProfiles.Bundled();
        if (ids.Any(id => !catalog.Any(x => x.Id == id))) throw new BenchmarkException("unknownProfile");
        var order = ids.Select(id => EmbeddingProfiles.Ids.ToList().IndexOf(id)).ToArray();
        if (!order.SequenceEqual(order.Order())) throw new BenchmarkException("invalidOrder");
        foreach (var c in Candidates) ValidateCandidate(c, catalog.First(x => x.Id == c.ProfileId));
        if (Status == "complete")
        {
            if (Chat!.ModelDigest is null || Chat.TokenFamily is null) throw new BenchmarkException("incompleteMeasurement");
            foreach (var c in Candidates)
            {
                var ig = c.Ingest;
                if (c.Status != "complete" || c.Identity.ModelDigest is null || c.Performance.Count == 0
                    || ig.SuccessfulTokens is null || ig.ElapsedUs is null || ig.CombinedPeakRssBytes is null
                    || c.Quality.Queries.Any(x => BenchmarkQuality.Metric(x, "packed_evidence_recall").Status == "not_available")
                    || c.Performance.Any(x => x.CacheMode == "cached" && x.ColdCacheLoadUs is null))
                    throw new BenchmarkException("incompleteMeasurement");
            }
        }
    }

    private static void ValidateCandidate(BenchmarkCandidate c, EmbeddingProfile profile)
    {
        var ident = c.Identity;
        try
        {
            profile.ValidateIdentity(ident.Model, ident.Dims, ident.QueryFormatVersion, ident.DocFormatVersion);
        }
        catch (EmbeddingProfileException) { throw new BenchmarkException("profileIdentityMismatch"); }
        if (ident.Normalization != "l2" || ident.ChunkerVersion != "2") throw new BenchmarkException("profileIdentityMismatch");
        if (ident.ModelDigest is not null && !IsDigest(ident.ModelDigest)) throw new BenchmarkException("invalidHash");
        if (c.Status is not ("complete" or "failed" or "incomplete") || (c.Status == "complete") != (c.ErrorCode is null))
            throw new BenchmarkException("invalidReport");
        var rows = c.Quality.Queries;
        var qids = rows.Select(x => x.Eval.QueryId).ToArray();
        if (qids.Distinct(StringComparer.Ordinal).Count() != qids.Length) throw new BenchmarkException("duplicateQuery");
        for (int i = 1; i < qids.Length; i++)
            if (ContextPackAlgorithms.CompareScalars(qids[i - 1], qids[i]) > 0) throw new BenchmarkException("invalidOrder");
        foreach (var x in rows)
        {
            foreach (var n in EvalMetrics.Names) ValidateMetric(BenchmarkQuality.Metric(x, n));
            foreach (var s in x.Packed)
                if (s.Start < 0 || s.End <= s.Start) throw new BenchmarkException("invalidMetric");
            if (x.PreparedHash is not null && !IsHex64(x.PreparedHash)) throw new BenchmarkException("invalidHash");
        }
        var (metrics, byLanguage, byCaseType) = BenchmarkQuality.Aggregates(rows);
        var groups = new[] { c.Quality.Metrics }.Concat(c.Quality.ByLanguage.Values).Concat(c.Quality.ByCaseType.Values);
        foreach (var group in groups)
            foreach (var n in EvalMetrics.Names)
                ValidateMetric(group.TryGetValue(n, out var m) && m is not null ? m : throw new BenchmarkException("invalidMetric"));
        if (!SameMetrics(metrics, c.Quality.Metrics) || !SameGroups(byLanguage, c.Quality.ByLanguage)
            || !SameGroups(byCaseType, c.Quality.ByCaseType))
            throw new BenchmarkException("inconsistentAggregate");
        var ct = c.Citations;
        if (ct.SemanticReview != "not_measured" || ct.SnapshotsCorrect < 0 || ct.SnapshotsTotal < 0 || ct.AnswerMarkersCorrect < 0
            || ct.AnswerMarkersTotal < 0 || ct.AnswerGoldSupported < 0 || ct.AnswerMarkersJudged < 0
            || ct.SnapshotsCorrect > ct.SnapshotsTotal || ct.AnswerMarkersCorrect > ct.AnswerMarkersTotal
            || ct.AnswerGoldSupported > ct.AnswerMarkersCorrect || ct.AnswerMarkersJudged > ct.AnswerMarkersTotal)
            throw new BenchmarkException("invalidCitations");
        var ig = c.Ingest;
        long?[] counters = [ig.ServiceTokens, ig.SuccessfulTokens, ig.RejectedRequests, ig.SplitParts, ig.ElapsedUs,
            ig.TokensPerSecondMilli, ig.RunnerPeakRssBytes, ig.ServerPeakRssBytes, ig.CombinedPeakRssBytes,
            ig.UncountedRequests, ig.SampleIntervalMs];
        if (counters.Any(v => v < 0)) throw new BenchmarkException("invalidSamples");
        switch (ig.ServiceTokenStatus)
        {
            case "measured":
                if (ig.UncountedRequests != 0 || (c.Status == "complete" && ig.ServiceTokens is null))
                    throw new BenchmarkException("invalidSamples");
                break;
            case "partial" or "not_available":
                if (ig.ServiceTokens is not null) throw new BenchmarkException("invalidSamples");
                break;
            default: throw new BenchmarkException("invalidSamples");
        }
        if (ig.SuccessfulTokens is long tokens && ig.ElapsedUs is long elapsed
            && ig.TokensPerSecondMilli != BenchmarkMath.TokensPerSecondMilli(tokens, elapsed))
            throw new BenchmarkException("summaryMismatch");
        if (ig.RunnerPeakRssBytes is long runner && ig.ServerPeakRssBytes is long server && ig.CombinedPeakRssBytes is long combined
            && !(Math.Max(runner, server) <= combined && combined <= runner + server))
            throw new BenchmarkException("summaryMismatch");
        var keys = c.Performance.Select(x => (x.Chunks, x.Concurrent)).ToArray();
        if (keys.Distinct().Count() != keys.Length || !keys.SequenceEqual(keys.OrderBy(k => k.Chunks).ThenBy(k => k.Concurrent)))
            throw new BenchmarkException("invalidOrder");
        foreach (var x in c.Performance)
        {
            var s = x.Samples;
            if (x.Queries <= 0 || x.WarmupQueries < 0 || s.Count != x.Queries
                || s.Select((y, i) => y.QueryId != i).Any(bad => bad)
                || s.Any(y => y.EmbeddingUs < 0 || y.RetrievalUs < 0 || y.HydrationUs < 0 || y.EndToEndUs < 0)
                || s.Any(y => y.EndToEndUs < y.EmbeddingUs + y.RetrievalUs + y.HydrationUs)
                || (x.Chunks == 100_000 && !x.Concurrent && x.Queries != 200))
                throw new BenchmarkException("invalidSamples");
            var warm = s.Select(y => y.RetrievalUs).ToArray();
            var total = s.Select(y => y.EndToEndUs).ToArray();
            if (x.WarmP50Us != BenchmarkMath.Percentile(warm, 5000) || x.WarmP95Us != BenchmarkMath.Percentile(warm, 9500)
                || x.EndToEndP50Us != BenchmarkMath.Percentile(total, 5000) || x.EndToEndP95Us != BenchmarkMath.Percentile(total, 9500)
                || x.HydrationP95Us != BenchmarkMath.Percentile(s.Select(y => y.HydrationUs).ToArray(), 9500)
                || x.GatePassed != BenchmarkMath.WarmGate(x.Chunks, x.Concurrent, x.Queries, x.WarmP95Us))
                throw new BenchmarkException("summaryMismatch");
            if (x.CacheMode is not ("cached" or "streamed") || (x.CacheMode == "streamed" && x.ColdCacheLoadUs is not null))
                throw new BenchmarkException("invalidSamples");
            if (x.Concurrent)
            {
                if (x.CompletedWrites < 2 || x.OverlapUs <= 0) throw new BenchmarkException("insufficientIngestionOverlap");
            }
            else if (x.CompletedWrites != 0 || x.OverlapUs != 0) throw new BenchmarkException("invalidSamples");
        }
    }

    internal static void ValidateMetric(EvalMetric m)
    {
        bool ok = m.Status switch
        {
            "measured" => m.Found is int f && m.Total is int t && t > 0 && f >= 0 && f <= t && m.RecallBp == (int)(10000L * f / t),
            "not_applicable" => m.Found == 0 && m.Total == 0 && m.RecallBp is null,
            "not_available" => m.Found is null && m.Total is null && m.RecallBp is null,
            _ => false,
        };
        if (!ok) throw new BenchmarkException("invalidMetric");
    }

    private static bool SameMetrics(IReadOnlyDictionary<string, EvalMetric> expected, IReadOnlyDictionary<string, EvalMetric> actual) =>
        expected.Count == actual.Count && expected.All(kv => actual.TryGetValue(kv.Key, out var v) && kv.Value == v);

    private static bool SameGroups(IReadOnlyDictionary<string, IReadOnlyDictionary<string, EvalMetric>> expected,
        IReadOnlyDictionary<string, IReadOnlyDictionary<string, EvalMetric>> actual) =>
        expected.Count == actual.Count && expected.All(kv => actual.TryGetValue(kv.Key, out var v) && SameMetrics(kv.Value, v));

    public string Markdown()
    {
        string V(string? s) => BenchmarkMarkdown.Value(s);
        string N(long? v) => BenchmarkMarkdown.Value(v);
        string I(long v) => BenchmarkMarkdown.Int(v);
        var e = Environment; var c0 = Corpus; var p = Parameters; var ch = Chat;
        var lines = new List<string>
        {
            "# Benchmark report v1", "", $"Status: {Status}", $"Mode: {Mode}", $"Platform: {Platform}", $"Backend: {Backend}", "",
            "## Environment", "", "| field | value |", "|---|---|",
            $"| cpu | {V(e.Cpu)} |", $"| ramBytes | {N(e.RamBytes)} |", $"| os | {V(e.Os)} |",
            $"| architecture | {V(e.Architecture)} |", $"| buildCommit | {V(e.BuildCommit)} |",
            $"| ollamaVersion | {V(e.OllamaVersion)} |", $"| accelerator | {V(e.Accelerator)} |", "",
            $"Corpus: {V(c0.Id)} ({c0.Hash}); documents {I(c0.Documents)}; queries {I(c0.Queries)}; chunker {V(c0.ChunkerVersion)}",
            $"Calibration: {CalibrationHash}",
            $"Parameters: fetchK {I(p.FetchK)}; topK {I(p.TopK)}; evidenceShareBp {I(p.EvidenceShareBp)}; " +
            $"runtimeContext {I(p.RuntimeContext)}; maxOutputTokens {I(p.MaxOutputTokens)}; seed {I(p.Seed)}",
            $"Chat: {V(ch.Model)} ({V(ch.ModelDigest)}); token family {V(ch.TokenFamily)}; template {V(ch.ShowTemplateSha256)}",
        };
        foreach (var c in Candidates)
        {
            var i = c.Identity; var q = c.Quality; var ct = c.Citations; var ig = c.Ingest;
            lines.AddRange([
                "", $"## Candidate {c.ProfileId}", "",
                $"Status: {c.Status}; error: {V(c.ErrorCode ?? "none")}",
                $"Identity: provider {V(i.ProviderId)}; endpoint {V(i.EndpointRevision)}; model {V(i.Model)} ({V(i.ModelDigest)}); " +
                $"dims {I(i.Dims)}; normalization {V(i.Normalization)}; chunker {V(i.ChunkerVersion)}",
                $"Query format: {V(i.QueryFormatVersion)}", $"Document format: {V(i.DocFormatVersion)}", "",
                "| metric | found | total | recall | status |", "|---|---:|---:|---:|---|",
            ]);
            foreach (var n in EvalMetrics.Names)
            {
                var m = q.Metrics[n];
                lines.Add($"| {n} | {N(m.Found)} | {N(m.Total)} | {BenchmarkMarkdown.Recall(m)} | {m.Status} |");
            }
            lines.Add("");
            lines.Add("| language | " + string.Join(" | ", EvalMetrics.Names) + " |");
            lines.Add("|---|" + string.Concat(Enumerable.Repeat("---:|", EvalMetrics.Names.Count)));
            foreach (var lang in BenchmarkQuality.Languages)
                lines.Add($"| {lang} | " + string.Join(" | ", EvalMetrics.Names.Select(n => BenchmarkMarkdown.Recall(q.ByLanguage[lang][n]))) + " |");
            lines.AddRange([
                "",
                $"Citations: snapshots {I(ct.SnapshotsCorrect)}/{I(ct.SnapshotsTotal)}; answer markers " +
                $"{I(ct.AnswerMarkersCorrect)}/{I(ct.AnswerMarkersTotal)}; gold-supported " +
                $"{I(ct.AnswerGoldSupported)}/{I(ct.AnswerMarkersJudged)} judged; semantic review {ct.SemanticReview}",
                $"Ingestion: service tokens {N(ig.ServiceTokens)} ({ig.ServiceTokenStatus}); successful tokens {N(ig.SuccessfulTokens)}; " +
                $"rejected requests {N(ig.RejectedRequests)}; split parts {N(ig.SplitParts)}; uncounted requests {N(ig.UncountedRequests)}; " +
                $"elapsed {BenchmarkMarkdown.Unit(ig.ElapsedUs, "us")}; throughput {BenchmarkMarkdown.Unit(BenchmarkMarkdown.Milli(ig.TokensPerSecondMilli), "tokens/s")}",
                $"Memory: runner peak {BenchmarkMarkdown.Unit(ig.RunnerPeakRssBytes, "bytes")}; server peak " +
                $"{BenchmarkMarkdown.Unit(ig.ServerPeakRssBytes, "bytes")}; combined peak {BenchmarkMarkdown.Unit(ig.CombinedPeakRssBytes, "bytes")}; " +
                $"method {V(ig.MemoryMethod)}; interval {BenchmarkMarkdown.Unit(ig.SampleIntervalMs, "ms")}", "",
                "| chunks | concurrent | queries | warmup | warm p50 us | warm p95 us | end-to-end p50 us | end-to-end p95 us " +
                "| hydration p95 us | cold cache us | cache | resident bytes | peak page bytes | writes | overlap us | gate |",
                "|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|---|",
            ]);
            foreach (var x in c.Performance)
            {
                string gate = x.GatePassed is null ? "not measured" : x.GatePassed.Value ? "pass" : "fail";
                lines.Add("| " + string.Join(" | ", [I(x.Chunks), BenchmarkMarkdown.Value(x.Concurrent), N(x.Queries), N(x.WarmupQueries),
                    N(x.WarmP50Us), N(x.WarmP95Us), N(x.EndToEndP50Us), N(x.EndToEndP95Us), N(x.HydrationP95Us), N(x.ColdCacheLoadUs),
                    V(x.CacheMode), N(x.ResidentBytes), N(x.PeakPageBytes), N(x.CompletedWrites), N(x.OverlapUs), gate]) + " |");
            }
        }
        return string.Join('\n', lines) + "\n";
    }
}

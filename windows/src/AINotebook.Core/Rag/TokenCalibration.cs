using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Eval;

namespace AINotebook.Core.Rag;

/// <summary>One counted calibration sample (benchmark-v1 §4).</summary>
public sealed record TokenSample(string Id, string Family, string Language, string Split, int Scalars, int Tokens);

public sealed record TokenUndercountRow(string Id, int Estimated, int Actual, int Undercount);

/// <summary>A count observation; only <c>body</c> observations with split <c>train</c> ever fit rates.</summary>
public sealed record TokenObservation(string Kind, string Method, TokenSample Sample);

public sealed record CalibrationDocument(string DocumentId, string Language, string Text);

public sealed record CalibrationQuery(string QueryId, string Language, string CaseType, string Text,
    IReadOnlyList<string> GoldDocumentIds);

/// <summary>A planned sample (benchmark-v1 §5.2); <c>Kind</c> is body, query or mixed.</summary>
public sealed record CalibrationPlanSample(string Id, string Language, string Split, string? DocumentId, int? Start, int? End,
    int Scalars, int Utf8Bytes, string Kind, IReadOnlyList<string>? Sources)
{
    /// <summary>The planned text, sliced by scalar offsets (mixed samples join their windows with LF).</summary>
    public string Text(IReadOnlyDictionary<string, CalibrationDocument> documents, IReadOnlyDictionary<string, CalibrationQuery> queries)
    {
        if (Kind == "mixed")
            return string.Join("\n", Sources!.Select(id => TokenCalibration.WindowText(id, documents)));
        if (Kind == "query") return queries[DocumentId!["query:".Length..]].Text;
        return TokenCalibration.Slice(documents[DocumentId!].Text, Start!.Value, End!.Value);
    }
}

/// <summary>Integer calibration kernels (benchmark-v1 §4–5).</summary>
public static class TokenCalibration
{
    public static readonly IReadOnlyList<string> Languages = ["cs", "de", "en", "sk", "und", "mixed"];
    public static readonly IReadOnlyList<string> BodyLanguages = ["cs", "de", "en", "sk"];
    private static readonly string[] MixedOrder = ["cs", "sk", "en", "de"];

    internal static bool ValidFamily(string? family) =>
        !string.IsNullOrEmpty(family) && !family.Any(char.IsWhiteSpace);

    public static void ValidateRates(IReadOnlyList<TokenRate> rates)
    {
        var seen = new HashSet<(string, string)>();
        foreach (var r in rates)
        {
            if (r is null || !ValidFamily(r.Family) || !Languages.Contains(r.Language)
                || r.TokensPerScalarBp is < 0 or > TokenEstimatorV2.MaxRateBp || !seen.Add((r.Family, r.Language)))
                throw new BenchmarkException("invalidCalibration");
        }
    }

    /// <summary>Per (family, language): <c>max ceilDiv(tokens·10000, scalars)</c> over training rows only.</summary>
    public static IReadOnlyList<TokenRate> Fit(IReadOnlyList<TokenSample> training)
    {
        ArgumentNullException.ThrowIfNull(training);
        if (training.Count == 0) throw new BenchmarkException("invalidCalibration");
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var groups = new Dictionary<(string Family, string Language), long>();
        foreach (var s in training)
        {
            if (s is null || s.Split != "train" || !ids.Add(s.Id) || !Languages.Contains(s.Language) || !ValidFamily(s.Family)
                || s.Scalars <= 0 || s.Scalars > TokenEstimatorV2.MaxScalars || s.Tokens < 0)
                throw new BenchmarkException("invalidCalibration");
            long rate = BenchmarkMath.CeilDiv(s.Tokens * 10_000L, s.Scalars);
            var key = (s.Family, s.Language);
            groups[key] = groups.TryGetValue(key, out var current) ? Math.Max(current, rate) : rate;
        }
        var result = new List<TokenRate>();
        foreach (var (key, rate) in groups.OrderBy(g => g.Key.Family, ScalarComparer.Instance)
                     .ThenBy(g => g.Key.Language, ScalarComparer.Instance))
        {
            if (rate > TokenEstimatorV2.MaxRateBp) throw new BenchmarkException("invalidCalibration");
            result.Add(new(key.Family, key.Language, (int)rate));
        }
        return result;
    }

    public static IReadOnlyList<TokenUndercountRow> UndercountRows(IReadOnlyList<TokenSample> samples, IReadOnlyList<TokenRate> rates)
    {
        ArgumentNullException.ThrowIfNull(samples);
        ValidateRates(rates);
        return samples.Select(s =>
        {
            int rate = TokenEstimatorV2.FamilyRate(s.Family, s.Language, rates) ?? throw new BenchmarkException("uncalibratedFamily");
            if (s.Scalars < 0 || s.Tokens < 0) throw new BenchmarkException("invalidCalibration");
            int estimated = (int)TokenEstimatorV2.EstimateScalars(s.Scalars, rate);
            return new TokenUndercountRow(s.Id, estimated, s.Tokens, Math.Max(0, s.Tokens - estimated));
        }).ToArray();
    }

    public static int Undercounts(IReadOnlyList<TokenSample> samples, IReadOnlyList<TokenRate> rates) =>
        UndercountRows(samples, rates).Count(r => r.Undercount > 0);

    /// <summary>Embedding counts and full-prompt checks never enter chat body rates.</summary>
    public static IReadOnlyList<TokenSample> TrainingSamples(IEnumerable<TokenObservation> observations) =>
        observations.Where(o => o.Kind == "body" && o.Sample.Split == "train").Select(o => o.Sample).ToArray();

    internal static string Slice(string text, int start, int end)
    {
        var runes = text.EnumerateRunes().ToArray();
        var builder = new StringBuilder();
        for (int i = start; i < end; i++) builder.Append(runes[i].ToString());
        return builder.ToString();
    }

    internal static string WindowText(string windowId, IReadOnlyDictionary<string, CalibrationDocument> documents)
    {
        int second = windowId.LastIndexOf(':'), first = windowId.LastIndexOf(':', second - 1);
        var doc = documents[windowId[..first]];
        return Slice(doc.Text, int.Parse(windowId[(first + 1)..second], CultureInfo.InvariantCulture),
            int.Parse(windowId[(second + 1)..], CultureInfo.InvariantCulture));
    }

    /// <summary>Frozen train/holdout partition and sample windows (benchmark-v1 §5.2).</summary>
    public static IReadOnlyList<CalibrationPlanSample> SamplePlan(IReadOnlyList<CalibrationDocument> documents,
        IReadOnlyList<CalibrationQuery> queries)
    {
        var partition = new Dictionary<string, string>(StringComparer.Ordinal);
        var samples = new List<CalibrationPlanSample>();
        var windows = new Dictionary<(string Language, string Split), List<(CalibrationDocument Doc, int Start, int End)>>();
        static string Id(string doc, int s, int e) => doc + ":" + s.ToString(CultureInfo.InvariantCulture) + ":" + e.ToString(CultureInfo.InvariantCulture);
        foreach (var language in BodyLanguages)
        {
            var docs = documents.Where(d => d.Language == language).OrderBy(d => d.DocumentId, ScalarComparer.Instance).ToArray();
            for (int index = 0; index < docs.Length; index++)
            {
                var d = docs[index];
                string split = index % 4 < 3 ? "train" : "holdout";
                partition[d.DocumentId] = split;
                var runes = d.Text.EnumerateRunes().ToArray();
                int n = runes.Length;
                var spans = new List<(int, int)>();
                for (int s = 0; s < n; s += 256) spans.Add((s, Math.Min(s + 256, n)));
                foreach (var (s, e) in spans)
                {
                    var key = (language, split);
                    if (!windows.TryGetValue(key, out var list)) windows[key] = list = [];
                    list.Add((d, s, e));
                }
                if (n > 256 && n <= 1024) spans.Add((0, n));
                foreach (var (s, e) in spans)
                {
                    string body = Slice(d.Text, s, e);
                    samples.Add(new(Id(d.DocumentId, s, e), language, split, d.DocumentId, s, e, e - s,
                        Encoding.UTF8.GetByteCount(body), "body", null));
                }
            }
        }
        foreach (var q in queries.OrderBy(q => q.QueryId, ScalarComparer.Instance))
        {
            if (q.CaseType is not ("answer" or "exact_identifier") || q.GoldDocumentIds.Count == 0
                || !BodyLanguages.Contains(q.Language) || q.Text.Length == 0)
                continue;
            var splits = q.GoldDocumentIds.Select(d => partition.TryGetValue(d, out var s) ? s : null).Distinct().ToArray();
            string split = splits.Length == 1 && splits[0] is not null ? splits[0]! : "holdout";
            int n = EmbeddingInput.ScalarCount(q.Text);
            samples.Add(new("query:" + q.QueryId + ":0:" + n.ToString(CultureInfo.InvariantCulture), q.Language, split,
                "query:" + q.QueryId, 0, n, n, Encoding.UTF8.GetByteCount(q.Text), "query", null));
        }
        foreach (var split in new[] { "train", "holdout" })
        {
            var lists = MixedOrder.Select(l => windows.TryGetValue((l, split), out var w) ? w : []).ToArray();
            int count = lists.Min(x => x.Count);
            for (int j = 0; j < count; j++)
            {
                var parts = lists.Select(x => x[j]).ToArray();
                string body = string.Join("\n", parts.Select(p => Slice(p.Doc.Text, p.Start, p.End)));
                var ids = parts.Select(p => Id(p.Doc.DocumentId, p.Start, p.End)).ToArray();
                samples.Add(new(string.Join("+", ids), "mixed", split, null, null, null, EmbeddingInput.ScalarCount(body),
                    Encoding.UTF8.GetByteCount(body), "mixed", ids));
            }
        }
        return samples.OrderBy(s => s.Id, ScalarComparer.Instance).ToArray();
    }
}

/// <summary>Unicode scalar order (contract "scalar order").</summary>
public sealed class ScalarComparer : IComparer<string>
{
    public static readonly ScalarComparer Instance = new();
    public int Compare(string? x, string? y) => ContextPackAlgorithms.CompareScalars(x!, y!);
}

/// <summary>The runtime <c>token-estimate</c> v2 resource (benchmark-v1 §4).</summary>
public sealed record TokenEstimateResource(string Status, string PayloadHash, IReadOnlyList<TokenFamilyBinding> Bindings,
    IReadOnlyList<TokenRate> Rates, IReadOnlyList<JsonElement> Provenance)
{
    public const string FixtureFamily = "fixture-only";

    private static readonly Lazy<TokenEstimateResource> Cached = new(() =>
        Parse(EmbeddingProfiles.ReadBenchmarkResource("token-estimate-v2.json"), production: true));

    /// <summary>The embedded production resource; a production loader rejects <c>fixture-only</c>.</summary>
    public static TokenEstimateResource Bundled() => Cached.Value;

    public static TokenEstimateResource Parse(byte[] json, bool production)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || Str(root, "contract") != "token-estimate"
                || !root.TryGetProperty("version", out var v) || v.ValueKind != JsonValueKind.Number || !v.TryGetInt32(out int version) || version != 2)
                throw new BenchmarkException("invalidCalibration");
            var bindingsRaw = Arr(root, "bindings");
            var ratesRaw = Arr(root, "rates");
            var provenanceRaw = Arr(root, "provenance");
            string hash = PayloadHashOf(bindingsRaw, ratesRaw, provenanceRaw);
            if (Str(root, "payloadHash") != hash) throw new BenchmarkException("invalidCalibration");
            var rates = ratesRaw.EnumerateArray().Select(r => new TokenRate(Str(r, "family")!, Str(r, "language")!,
                r.TryGetProperty("tokensPerScalarBp", out var bp) && bp.ValueKind == JsonValueKind.Number && bp.TryGetInt32(out int x)
                    ? x : throw new BenchmarkException("invalidCalibration"))).ToArray();
            TokenCalibration.ValidateRates(rates);
            var bindings = bindingsRaw.EnumerateArray().Select(b => new TokenFamilyBinding(
                Str(b, "model") ?? throw new BenchmarkException("invalidCalibration"),
                Str(b, "modelDigest") ?? throw new BenchmarkException("invalidCalibration"),
                Str(b, "family") ?? throw new BenchmarkException("invalidCalibration"))).ToArray();
            string? status = Str(root, "status");
            if (status == "pending")
            {
                if (bindings.Length != 0 || rates.Length != 0 || provenanceRaw.GetArrayLength() != 0)
                    throw new BenchmarkException("invalidCalibration");
            }
            else if (status != "calibrated") throw new BenchmarkException("invalidCalibration");
            var families = rates.Select(r => r.Family).ToHashSet(StringComparer.Ordinal);
            var pairs = new HashSet<(string, string)>();
            foreach (var b in bindings)
                if (!BenchmarkReportV1.IsDigest(b.ModelDigest) || !families.Contains(b.Family) || !pairs.Add((b.Model, b.ModelDigest)))
                    throw new BenchmarkException("invalidCalibration");
            if (production && (families.Contains(FixtureFamily) || bindings.Any(b => b.Family == FixtureFamily)))
                throw new BenchmarkException("invalidCalibration");
            return new(status!, hash, bindings, rates, provenanceRaw.EnumerateArray().Select(e => e.Clone()).ToArray());
        }
        catch (JsonException) { throw new BenchmarkException("invalidCalibration"); }
    }

    /// <summary><c>sha256_lowerhex(canonical({bindings, provenance, rates}))</c>.</summary>
    public static string PayloadHashOf(JsonElement bindings, JsonElement rates, JsonElement provenance)
    {
        var builder = new StringBuilder();
        builder.Append("{\"bindings\":");
        CanonicalJson.Append(builder, bindings);
        builder.Append(",\"provenance\":");
        CanonicalJson.Append(builder, provenance);
        builder.Append(",\"rates\":");
        CanonicalJson.Append(builder, rates);
        builder.Append('}');
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(builder.ToString())));
    }

    private static string? Str(JsonElement e, string name) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static JsonElement Arr(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Array ? v : throw new BenchmarkException("invalidCalibration");
}

/// <summary>Sorted keys (scalar order), <c>,</c>/<c>:</c> separators, literal UTF-8, JSON-required escapes only.</summary>
public static class CanonicalJson
{
    public static string Serialize(JsonElement value)
    {
        var builder = new StringBuilder();
        Append(builder, value);
        return builder.ToString();
    }

    public static void Append(StringBuilder builder, JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                builder.Append('{');
                bool first = true;
                foreach (var p in value.EnumerateObject().OrderBy(p => p.Name, ScalarComparer.Instance))
                {
                    if (!first) builder.Append(',');
                    first = false;
                    AppendString(builder, p.Name);
                    builder.Append(':');
                    Append(builder, p.Value);
                }
                builder.Append('}');
                break;
            case JsonValueKind.Array:
                builder.Append('[');
                bool firstItem = true;
                foreach (var item in value.EnumerateArray())
                {
                    if (!firstItem) builder.Append(',');
                    firstItem = false;
                    Append(builder, item);
                }
                builder.Append(']');
                break;
            case JsonValueKind.String: AppendString(builder, value.GetString()!); break;
            case JsonValueKind.True: builder.Append("true"); break;
            case JsonValueKind.False: builder.Append("false"); break;
            case JsonValueKind.Null: builder.Append("null"); break;
            default: builder.Append(value.GetRawText()); break;
        }
    }

    private static void AppendString(StringBuilder builder, string text)
    {
        builder.Append('"');
        foreach (char c in text)
        {
            switch (c)
            {
                case '"': builder.Append("\\\""); break;
                case '\\': builder.Append("\\\\"); break;
                case '\n': builder.Append("\\n"); break;
                case '\r': builder.Append("\\r"); break;
                case '\t': builder.Append("\\t"); break;
                case '\b': builder.Append("\\b"); break;
                case '\f': builder.Append("\\f"); break;
                default:
                    if (c < 0x20) builder.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else builder.Append(c);
                    break;
            }
        }
        builder.Append('"');
    }
}

public sealed record CalibrationReportSample(string Id, string Language, string Split, string? DocumentId, int? Start, int? End,
    int Scalars, int Utf8Bytes, int? Tokens);

public sealed record CalibrationPromptCheck(string QueryId, string Split, string PreparedHash, string WireMessagesHash,
    int? ActualTokens, int? EstimatedTokens);

/// <summary><c>TokenCalibrationReportV1</c> (benchmark-v1 §5.4).</summary>
public sealed record TokenCalibrationReportV1(string Contract, int Version, string Status, string CorpusHash, string Platform,
    string Model, string ModelDigest, string? OllamaVersion, string ShowTemplateSha256, string Family, string Method,
    string? TokenizerId, string? TokenizerRevision, string? TokenizerAssetsSha256, IReadOnlyList<CalibrationReportSample> Samples,
    IReadOnlyList<TokenRate> Rates, int HeadroomBp, IReadOnlyList<CalibrationPromptCheck> PromptChecks,
    int? BodyHoldoutUndercounts, int? PromptHoldoutUndercounts, int? MaxOverestimateTokens, bool Calibrated, string? ErrorCode)
{
    public byte[] JsonBytes() => BenchmarkJson.Bytes(this);

    /// <summary>Recomputes the holdout counters and calibrated flag for counted samples and rates.</summary>
    public static (int? Body, int? Prompt, int? MaxOver, bool Calibrated) Summaries(bool complete, string family,
        IReadOnlyList<CalibrationReportSample> samples, IReadOnlyList<TokenRate> rates, IReadOnlyList<CalibrationPromptCheck> checks)
    {
        var holdout = samples.Where(s => s.Split == "holdout").ToArray();
        bool measured = samples.All(s => s.Tokens is not null);
        int? bodyUnder = null;
        var over = new List<long>();
        if (measured && rates.Count > 0)
        {
            var rows = TokenCalibration.UndercountRows(holdout.Select(s =>
                new TokenSample(s.Id, family, s.Language, s.Split, s.Scalars, s.Tokens!.Value)).ToArray(), rates);
            bodyUnder = rows.Count(r => r.Undercount > 0);
            over.AddRange(rows.Select(r => (long)r.Estimated - r.Actual));
        }
        var prompts = checks.Where(p => p.Split == "holdout").ToArray();
        int? promptUnder = null;
        if (measured && prompts.All(p => p.ActualTokens is not null))
        {
            if (prompts.Any(p => p.EstimatedTokens is null)) throw new BenchmarkException("invalidCalibration");
            promptUnder = prompts.Count(p => p.ActualTokens > p.EstimatedTokens);
            over.AddRange(prompts.Select(p => (long)p.EstimatedTokens!.Value - p.ActualTokens!.Value));
        }
        bool calibrated = complete && bodyUnder == 0 && promptUnder == 0 && holdout.Length > 0 && prompts.Length > 0;
        int? maxOver = bodyUnder is null ? null : over.Count == 0 ? 0 : (int)Math.Max(0, over.Max());
        return (bodyUnder, promptUnder, maxOver, calibrated);
    }

    public void Validate()
    {
        static BenchmarkException Bad() => new("invalidCalibration");
        if (Contract != "token-calibration-report" || Version != 1 || Status is not ("complete" or "incomplete")
            || HeadroomBp != TokenEstimatorV2.HeadroomBp)
            throw Bad();
        if (Method == ChatMethodNames.OllamaRawPrompt)
        {
            if (TokenizerId is not null || TokenizerRevision is not null || TokenizerAssetsSha256 is not null
                || Family != "ollama:" + ModelDigest)
                throw Bad();
        }
        else if (Method == ChatMethodNames.DocumentedTokenizer)
        {
            if (string.IsNullOrEmpty(TokenizerId) || string.IsNullOrEmpty(TokenizerRevision) || !BenchmarkReportV1.IsHex64(TokenizerAssetsSha256)
                || Family != "hf:" + TokenizerId + "@" + TokenizerRevision + ":" + TokenizerAssetsSha256)
                throw Bad();
        }
        else throw Bad();
        if (!BenchmarkReportV1.IsDigest(ModelDigest) || !BenchmarkReportV1.IsHex64(CorpusHash) || !BenchmarkReportV1.IsHex64(ShowTemplateSha256))
            throw Bad();
        var ids = Samples.Select(s => s.Id).ToArray();
        if (ids.Distinct(StringComparer.Ordinal).Count() != ids.Length) throw Bad();
        for (int i = 1; i < ids.Length; i++)
            if (ScalarComparer.Instance.Compare(ids[i - 1], ids[i]) > 0) throw Bad();
        if (Status == "incomplete")
        {
            if (string.IsNullOrEmpty(ErrorCode) || Calibrated) throw Bad();
            return;
        }
        if (ErrorCode is not null || Samples.Any(s => s.Tokens is null)) throw Bad();
        var train = Samples.Where(s => s.Split == "train")
            .Select(s => new TokenSample(s.Id, Family, s.Language, "train", s.Scalars, s.Tokens!.Value)).ToArray();
        if (!TokenCalibration.Fit(train).SequenceEqual(Rates)) throw Bad();
        var (body, prompt, maxOver, calibrated) = Summaries(true, Family, Samples, Rates, PromptChecks);
        if (body != BodyHoldoutUndercounts || prompt != PromptHoldoutUndercounts || maxOver != MaxOverestimateTokens
            || calibrated != Calibrated)
            throw Bad();
    }

    public string Markdown()
    {
        static string V(string? s) => BenchmarkMarkdown.Value(s);
        static string N(long? v) => BenchmarkMarkdown.Value(v);
        static string I(long v) => BenchmarkMarkdown.Int(v);
        var lines = new List<string>
        {
            "# Token calibration report v1", "", $"Status: {Status}", $"Platform: {V(Platform)}",
            $"Model: {V(Model)} ({V(ModelDigest)})", $"Ollama: {V(OllamaVersion)}", $"Template: {V(ShowTemplateSha256)}",
            $"Family: {V(Family)}", $"Method: {V(Method)}",
            TokenizerId is null ? "Tokenizer: none" : $"Tokenizer: {V(TokenizerId)} @ {V(TokenizerRevision)} ({V(TokenizerAssetsSha256)})",
            $"Corpus: {V(CorpusHash)}", $"Headroom: {I(HeadroomBp)} bp", $"Calibrated: {BenchmarkMarkdown.Value(Calibrated)}",
            $"Error: {V(ErrorCode ?? "none")}", "",
            "| sample | language | split | scalars | utf8 bytes | tokens |", "|---|---|---|---:|---:|---:|",
        };
        foreach (var s in Samples)
            lines.Add($"| {V(s.Id)} | {s.Language} | {s.Split} | {I(s.Scalars)} | {I(s.Utf8Bytes)} | {N(s.Tokens)} |");
        lines.AddRange(["", "| family | language | tokens per scalar bp |", "|---|---|---:|"]);
        foreach (var x in Rates) lines.Add($"| {V(x.Family)} | {x.Language} | {I(x.TokensPerScalarBp)} |");
        lines.AddRange(["", "| query | split | prepared | wire | actual | estimated |", "|---|---|---|---|---:|---:|"]);
        foreach (var p in PromptChecks)
            lines.Add($"| {V(p.QueryId)} | {p.Split} | {p.PreparedHash} | {p.WireMessagesHash} | {N(p.ActualTokens)} | {N(p.EstimatedTokens)} |");
        lines.AddRange(["", $"Body holdout undercounts: {N(BodyHoldoutUndercounts)}",
            $"Prompt holdout undercounts: {N(PromptHoldoutUndercounts)}", $"Max overestimate tokens: {N(MaxOverestimateTokens)}"]);
        return string.Join('\n', lines) + "\n";
    }
}

/// <summary>Method labels mirrored here so pure calibration code needs no provider types.</summary>
public static class ChatMethodNames
{
    public const string OllamaRawPrompt = "ollama-raw-prompt";
    public const string DocumentedTokenizer = "documented-tokenizer";
}

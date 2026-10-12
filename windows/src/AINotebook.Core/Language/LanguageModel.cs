using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AINotebook.Core.Language;

internal sealed record LanguageParameters(ImmutableArray<int> MaxFeaturesPerProfile, ImmutableArray<long> OrderWeights,
    int ScoreScale, ImmutableArray<int> LengthBucketStarts, int MinLetters, int MinWords, int MixedDominanceBp,
    int InputCapScalars, int TextCapScalars, int WindowCount, int WindowScalars);
internal sealed record LanguageVocabulary(int Order, ImmutableArray<ImmutableArray<int>> Features);
internal sealed record LanguageOrder(int Order, ImmutableArray<long> Weights, long UnknownWeight);
internal sealed record LanguageProfile(string Id, long PriorWeight, ImmutableArray<LanguageOrder> Orders);
internal sealed record LanguageThreshold(int Start, int Enabled, long MinWinningScore, long MinMargin, long MinKnownCoverageBp);
internal sealed record LanguageAttribution(ImmutableArray<string> SourceIds, ImmutableArray<string> LicenseIds,
    string AttributionPath, string AttributionSha256, string NoticePath, string NoticeSha256)
{
    internal static LanguageAttribution Parse(JsonElement e, bool synthetic)
    {
        LanguageJson.Keys(e, "sourceIds", "licenseIds", "attributionPath", "attributionSha256", "noticePath", "noticeSha256");
        var sources = LanguageJson.Array(e.GetProperty("sourceIds")).Select(x => LanguageJson.Text(x, "^[A-Za-z0-9_-]+$")).ToImmutableArray();
        var licenses = LanguageJson.Array(e.GetProperty("licenseIds")).Select(x => LanguageJson.Text(x)).ToImmutableArray();
        var result = new LanguageAttribution(sources, licenses,
            LanguageJson.Text(e.GetProperty("attributionPath")), LanguageJson.Text(e.GetProperty("attributionSha256"), "^([0-9a-f]{64})?$"),
            LanguageJson.Text(e.GetProperty("noticePath")), LanguageJson.Text(e.GetProperty("noticeSha256"), "^([0-9a-f]{64})?$"));
        LanguageJson.Require(sources.Distinct(StringComparer.Ordinal).Count() == sources.Length &&
            licenses.Distinct(StringComparer.Ordinal).Count() == licenses.Length, "Duplicate attribution identity.");
        if (synthetic)
            LanguageJson.Require(sources.IsEmpty && licenses.IsEmpty && result.AttributionPath.Length == 0 &&
                result.AttributionSha256.Length == 0 && result.NoticePath.Length == 0 && result.NoticeSha256.Length == 0,
                "Synthetic attribution must be empty.");
        else
            LanguageJson.Require(!sources.IsEmpty && !licenses.IsEmpty && licenses.All(x => x.Length > 0) &&
                result.AttributionPath.Length > 0 && result.NoticePath.Length > 0 &&
                result.AttributionSha256.Length == 64 && result.NoticeSha256.Length == 64, "Missing production attribution.");
        return result;
    }

    internal bool SameAs(LanguageAttribution other) => SourceIds.SequenceEqual(other.SourceIds) && LicenseIds.SequenceEqual(other.LicenseIds) &&
        AttributionPath == other.AttributionPath && AttributionSha256 == other.AttributionSha256 &&
        NoticePath == other.NoticePath && NoticeSha256 == other.NoticeSha256;
}

/// <summary>Strictly validated immutable model; synthetic entry points are internal test seams.</summary>
internal sealed record LanguageModel(string Contract, int Version, string Kind, string ModelId,
    ImmutableArray<string> Targets, string NormalizationTablesVersion, int Alpha, LanguageParameters Parameters,
    ImmutableArray<LanguageVocabulary> Vocabulary, ImmutableArray<LanguageProfile> Profiles,
    ImmutableArray<LanguageThreshold> Thresholds, LanguageAttribution Attribution)
{
    internal static LanguageModel Parse(ReadOnlySpan<byte> data, UnicodeTables tables, bool allowSynthetic)
    {
        using var document = LanguageJson.Parse(data);
        var e = document.RootElement;
        LanguageJson.Keys(e, "contract", "version", "kind", "modelId", "targets", "normalizationTablesVersion", "alpha", "parameters",
            "vocabulary", "profiles", "thresholds", "attribution");
        string contract = LanguageJson.Text(e.GetProperty("contract")), kind = LanguageJson.Text(e.GetProperty("kind"));
        int version = (int)LanguageJson.Int(e.GetProperty("version"), 1, 1), alpha = (int)LanguageJson.Int(e.GetProperty("alpha"), 1, 1);
        LanguageJson.Require(contract == "lang-detector" && (kind == "production" || (allowSynthetic && kind == "synthetic")), "Invalid model kind or contract.");
        bool synthetic = kind == "synthetic";
        string modelId = LanguageJson.Text(e.GetProperty("modelId"), "^[A-Za-z0-9._-]+$");
        string normalization = LanguageJson.Text(e.GetProperty("normalizationTablesVersion"));
        LanguageJson.Require(normalization == UnicodeTables.NormalizationVersion, "Incompatible normalization version.");
        var targets = LanguageJson.Array(e.GetProperty("targets"), 2, 4).Select(x => LanguageJson.Text(x, "^[a-z]{2,3}$")).ToImmutableArray();
        LanguageJson.Require(targets.SequenceEqual(targets.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal)), "Unsorted or duplicate targets.");
        if (!synthetic) LanguageJson.Require(targets.SequenceEqual(new[] { "cs", "de", "en", "sk" }), "Invalid production targets.");
        var p = e.GetProperty("parameters");
        LanguageJson.Keys(p, "maxFeaturesPerProfile", "orderWeights", "scoreScale", "lengthBucketStarts", "minLetters", "minWords",
            "mixedDominanceBp", "inputCapScalars", "textCapScalars", "windowCount", "windowScalars");
        var caps = LanguageJson.Array(p.GetProperty("maxFeaturesPerProfile"), 3, 3).Select(x => (int)LanguageJson.Int(x, 1, 4096)).ToImmutableArray();
        var weights = LanguageJson.Array(p.GetProperty("orderWeights"), 3, 3).Select(x => LanguageJson.Int(x, 1, 3)).ToImmutableArray();
        var starts = LanguageJson.Array(p.GetProperty("lengthBucketStarts"), 4, 4).Select(x => (int)LanguageJson.Int(x, 12, 200)).ToImmutableArray();
        LanguageJson.Require(weights.SequenceEqual(new long[] { 1, 2, 3 }) && starts.SequenceEqual(new[] { 12, 32, 80, 200 }), "Changed fixed parameters.");
        var parameters = new LanguageParameters(caps, weights,
            (int)LanguageJson.Int(p.GetProperty("scoreScale"), 1024, 1024), starts,
            (int)LanguageJson.Int(p.GetProperty("minLetters"), 12, 12), (int)LanguageJson.Int(p.GetProperty("minWords"), 3, 3),
            (int)LanguageJson.Int(p.GetProperty("mixedDominanceBp"), 7000, 7000),
            (int)LanguageJson.Int(p.GetProperty("inputCapScalars"), 1, 5000000), (int)LanguageJson.Int(p.GetProperty("textCapScalars"), 1, 5000000),
            (int)LanguageJson.Int(p.GetProperty("windowCount"), 1, 8), (int)LanguageJson.Int(p.GetProperty("windowScalars"), 1, 5000000));
        LanguageJson.Require(parameters.WindowScalars <= parameters.TextCapScalars && parameters.TextCapScalars <= parameters.InputCapScalars, "Invalid cap relationship.");
        if (!synthetic) LanguageJson.Require(caps.SequenceEqual(new[] { 256, 1024, 4096 }) && parameters.InputCapScalars == 5000000 &&
            parameters.TextCapScalars == 8192 && parameters.WindowCount == 8 && parameters.WindowScalars == 512, "Changed production parameters.");

        var vocabulary = LanguageJson.Array(e.GetProperty("vocabulary"), 3, 3).Select((v, index) =>
        {
            LanguageJson.Keys(v, "order", "features");
            int order = (int)LanguageJson.Int(v.GetProperty("order"), index + 1, index + 1);
            var features = LanguageJson.Array(v.GetProperty("features"), 0, (targets.Length + 1) * caps[index]).Select(f =>
            {
                var tuple = LanguageJson.Array(f, order, order).Select(x => (int)LanguageJson.Int(x, -2, 0x10FFFF)).ToImmutableArray();
                ValidateFeature(tuple, tables);
                return tuple;
            }).ToImmutableArray();
            for (int i = 1; i < features.Length; i++)
                LanguageJson.Require(CompareTuple(features[i - 1], features[i]) < 0, "Unsorted or duplicate feature.");
            return new LanguageVocabulary(order, features);
        }).ToImmutableArray();
        long prior = (targets.Length + 1) switch { 3 => -1125, 4 => -1420, 5 => -1648, _ => throw new InvalidDataException("Invalid profile count.") };
        var profiles = LanguageJson.Array(e.GetProperty("profiles"), targets.Length + 1, targets.Length + 1).Select((profile, index) =>
        {
            LanguageJson.Keys(profile, "id", "priorWeight", "orders");
            string id = LanguageJson.Text(profile.GetProperty("id"));
            LanguageJson.Require(id == (index == 0 ? "background" : targets[index - 1]), "Invalid profile order.");
            long priorWeight = LanguageJson.Int(profile.GetProperty("priorWeight"), prior, prior);
            var orders = LanguageJson.Array(profile.GetProperty("orders"), 3, 3).Select((o, n) =>
            {
                LanguageJson.Keys(o, "order", "weights", "unknownWeight");
                int order = (int)LanguageJson.Int(o.GetProperty("order"), n + 1, n + 1);
                var values = LanguageJson.Array(o.GetProperty("weights"), vocabulary[n].Features.Length, vocabulary[n].Features.Length)
                    .Select(x => LanguageJson.Int(x, -1000000, 0)).ToImmutableArray();
                return new LanguageOrder(order, values, LanguageJson.Int(o.GetProperty("unknownWeight"), -1000000, 0));
            }).ToImmutableArray();
            return new LanguageProfile(id, priorWeight, orders);
        }).ToImmutableArray();
        var thresholds = LanguageJson.Array(e.GetProperty("thresholds"), 4, 4).Select((t, i) =>
        {
            LanguageJson.Keys(t, "start", "enabled", "minWinningScore", "minMargin", "minKnownCoverageBp");
            int start = (int)LanguageJson.Int(t.GetProperty("start"), starts[i], starts[i]);
            int enabled = (int)LanguageJson.Int(t.GetProperty("enabled"), 0, 1);
            return new LanguageThreshold(start, enabled, LanguageJson.Int(t.GetProperty("minWinningScore"), -7000000, 0),
                LanguageJson.Int(t.GetProperty("minMargin"), enabled, 7000000), LanguageJson.Int(t.GetProperty("minKnownCoverageBp"), 0, 10000));
        }).ToImmutableArray();
        return new(contract, version, kind, modelId, targets, normalization, alpha, parameters, vocabulary, profiles, thresholds,
            LanguageAttribution.Parse(e.GetProperty("attribution"), synthetic));
    }

    private static void ValidateFeature(ImmutableArray<int> tuple, UnicodeTables tables)
    {
        bool content = false;
        for (int i = 0; i < tuple.Length; i++)
        {
            int symbol = tuple[i];
            if (symbol == -1) LanguageJson.Require(i == 0, "BOS must be first.");
            else if (symbol == -2) LanguageJson.Require(i == tuple.Length - 1, "EOS must be last.");
            else
            {
                LanguageJson.Require(UnicodeTables.IsScalar(symbol), "Invalid feature scalar.");
                string category = tables.GeneralCategory(symbol);
                LanguageJson.Require(category[0] is 'L' or 'M', "Feature contains a word boundary.");
                LanguageJson.Require(!(i == 1 && tuple[0] == -1 && category[0] == 'M'), "Detached mark after BOS.");
                content = true;
            }
        }
        LanguageJson.Require(content || tuple.Length == 1, "Boundary-only feature.");
    }
    private static int CompareTuple(ImmutableArray<int> a, ImmutableArray<int> b)
    {
        for (int i = 0; i < Math.Min(a.Length, b.Length); i++)
            if (a[i] != b[i]) return a[i].CompareTo(b[i]);
        return a.Length.CompareTo(b.Length);
    }
}

/// <summary>Shared lexical validation for artifacts and manifests, before schema validation.</summary>
internal static class LanguageJson
{
    internal static JsonDocument Parse(ReadOnlySpan<byte> data)
    {
        try
        {
            Require(data.Length > 0 && data[^1] == 10 && !data.StartsWith(new byte[] { 0xEF, 0xBB, 0xBF }), "Expected UTF-8 without BOM and final LF.");
            _ = new UTF8Encoding(false, true).GetCharCount(data);
            var reader = new Utf8JsonReader(data, new JsonReaderOptions { MaxDepth = 64, CommentHandling = JsonCommentHandling.Disallow, AllowTrailingCommas = false });
            var objects = new Stack<HashSet<string>>();
            bool first = true;
            while (reader.Read())
            {
                if (first) { Require(reader.TokenType == JsonTokenType.StartObject, "Expected object root."); first = false; }
                switch (reader.TokenType)
                {
                    case JsonTokenType.StartObject: objects.Push(new(StringComparer.Ordinal)); break;
                    case JsonTokenType.EndObject: objects.Pop(); break;
                    case JsonTokenType.String:
                    case JsonTokenType.PropertyName:
                        ValidateEscapes(reader.ValueSpan);
                        string decoded = reader.GetString()!;
                        if (reader.TokenType == JsonTokenType.PropertyName)
                            Require(objects.Peek().Add(decoded), "Duplicate JSON key: " + decoded);
                        break;
                    case JsonTokenType.Number:
                        foreach (byte c in reader.ValueSpan)
                            Require(c is >= (byte)'0' and <= (byte)'9' or (byte)'-', "Expected decimal integer token.");
                        Require(reader.TryGetInt64(out _), "Integer outside Int64.");
                        break;
                }
            }
            Require(!first && objects.Count == 0, "Incomplete JSON object.");
            return JsonDocument.Parse(data.ToArray(), new JsonDocumentOptions { MaxDepth = 64 });
        }
        catch (Exception e) when (e is JsonException or ArgumentException or InvalidOperationException or FormatException or OverflowException)
        {
            throw new InvalidDataException("Malformed language JSON.", e);
        }
    }
    private static void ValidateEscapes(ReadOnlySpan<byte> raw)
    {
        for (int i = 0; i < raw.Length; i++)
        {
            if (raw[i] != '\\') continue;
            Require(++i < raw.Length, "Incomplete string escape.");
            if (raw[i] != 'u') continue; // Utf8JsonReader validates the remaining escape syntax.
            Require(i + 4 < raw.Length, "Incomplete Unicode escape.");
            int cp = Hex4(raw.Slice(i + 1, 4));
            i += 4;
            if (cp is >= 0xD800 and <= 0xDBFF)
            {
                Require(i + 6 < raw.Length && raw[i + 1] == '\\' && raw[i + 2] == 'u', "Unpaired high surrogate.");
                int low = Hex4(raw.Slice(i + 3, 4));
                Require(low is >= 0xDC00 and <= 0xDFFF, "Unpaired high surrogate.");
                i += 6;
            }
            else Require(cp is not (>= 0xDC00 and <= 0xDFFF), "Unpaired low surrogate.");
        }
    }
    private static int Hex4(ReadOnlySpan<byte> value)
    {
        int result = 0;
        foreach (byte c in value)
        {
            int digit = c switch { >= (byte)'0' and <= (byte)'9' => c - '0', >= (byte)'a' and <= (byte)'f' => c - 'a' + 10,
                >= (byte)'A' and <= (byte)'F' => c - 'A' + 10, _ => -1 };
            Require(digit >= 0, "Invalid Unicode escape.");
            result = result * 16 + digit;
        }
        return result;
    }
    internal static void Require(bool valid, string reason)
    {
        if (!valid) throw new InvalidDataException(reason);
    }
    internal static void Keys(JsonElement value, params string[] names)
    {
        Require(value.ValueKind == JsonValueKind.Object, "Expected object.");
        var keys = value.EnumerateObject().Select(p => p.Name).ToArray();
        Require(keys.Length == names.Length && keys.Distinct(StringComparer.Ordinal).Count() == keys.Length &&
            keys.All(k => names.Contains(k, StringComparer.Ordinal)), "Missing or unknown object key.");
    }
    internal static JsonElement[] Array(JsonElement value, int min = 0, int max = int.MaxValue)
    {
        Require(value.ValueKind == JsonValueKind.Array, "Expected array.");
        Require(value.GetArrayLength() >= min && value.GetArrayLength() <= max, "Invalid array length.");
        return value.EnumerateArray().ToArray();
    }
    internal static string Text(JsonElement value, string? pattern = null)
    {
        Require(value.ValueKind == JsonValueKind.String, "Expected string.");
        string text = value.GetString()!;
        if (pattern is not null)
            Require(Regex.IsMatch(text, "\\A(?:" + pattern.TrimStart('^').TrimEnd('$') + ")\\z", RegexOptions.CultureInvariant), "Invalid string format.");
        return text;
    }
    internal static long Int(JsonElement value, long min = long.MinValue, long max = long.MaxValue)
    {
        Require(value.ValueKind == JsonValueKind.Number, "Expected integer.");
        Require(value.TryGetInt64(out long n) && n >= min && n <= max, "Integer outside allowed range.");
        return n;
    }
}

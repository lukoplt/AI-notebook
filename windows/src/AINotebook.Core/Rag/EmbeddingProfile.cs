using System.Text.Json;
using System.Text.Json.Serialization;

namespace AINotebook.Core.Rag;

/// <summary>Typed WP7 error (docs/contracts/benchmark-v1.md). <see cref="Code"/> is the contract code.</summary>
public sealed class EmbeddingProfileException(string code, int? status = null)
    : Exception("EmbeddingProfileError(" + code + ")")
{
    public string Code { get; } = code;
    /// <summary>HTTP status for <c>providerError</c>; never the provider's response body.</summary>
    public int? Status { get; } = status;
}

public enum EmbeddingPurpose { Query, Document }

public static class EmbeddingPurposeExtensions
{
    public static string WireName(this EmbeddingPurpose purpose) =>
        purpose == EmbeddingPurpose.Query ? "query" : "document";
}

/// <summary>One row of the frozen WP7 embedding catalog (benchmark-v1 §2).</summary>
public sealed record EmbeddingProfile(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("tokenizerId")] string TokenizerId,
    [property: JsonPropertyName("queryPrefix")] string QueryPrefix,
    [property: JsonPropertyName("documentPrefix")] string DocumentPrefix,
    [property: JsonPropertyName("nativeDims")] int NativeDims,
    [property: JsonPropertyName("dims")] int Dims,
    [property: JsonPropertyName("maxInputTokens")] int MaxInputTokens,
    [property: JsonPropertyName("matryoshka")] bool Matryoshka,
    [property: JsonPropertyName("ceilingSource")] string CeilingSource = "model-card")
{
    /// <summary>Prefix + text; no trimming or normalization.</summary>
    public string Format(string text, EmbeddingPurpose purpose)
    {
        EmbeddingInput.RequireValidText(text);
        return (purpose == EmbeddingPurpose.Query ? QueryPrefix : DocumentPrefix) + text;
    }

    public string FormatVersion(EmbeddingPurpose purpose, int? effectiveLimit = null) =>
        FormatVersionPrefix(purpose) + (effectiveLimit ?? MaxInputTokens).ToString(System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>
    /// Identity agreement (§2 <c>identity</c>): exact model, dims and both format strings sharing one
    /// ctx value in <c>1…MaxInputTokens</c>. Returns that effective limit.
    /// </summary>
    public int ValidateIdentity(string model, int dims, string queryFormatVersion, string docFormatVersion)
    {
        if (!string.Equals(model, Model, StringComparison.Ordinal) || dims != Dims
            || ContextSuffix(queryFormatVersion, FormatVersionPrefix(EmbeddingPurpose.Query)) is not int limit
            || limit < 1 || limit > MaxInputTokens
            || !string.Equals(queryFormatVersion, FormatVersion(EmbeddingPurpose.Query, limit), StringComparison.Ordinal)
            || !string.Equals(docFormatVersion, FormatVersion(EmbeddingPurpose.Document, limit), StringComparison.Ordinal))
            throw new EmbeddingProfileException("profileIdentityMismatch");
        return limit;
    }

    /// <summary>Parses the ctx value of a stored format string for this profile and purpose.</summary>
    public int EffectiveLimit(string formatVersion, EmbeddingPurpose purpose)
    {
        if (ContextSuffix(formatVersion, FormatVersionPrefix(purpose)) is not int limit
            || limit < 1 || limit > MaxInputTokens
            || !string.Equals(formatVersion, FormatVersion(purpose, limit), StringComparison.Ordinal))
            throw new EmbeddingProfileException("profileIdentityMismatch");
        return limit;
    }

    private string FormatVersionPrefix(EmbeddingPurpose purpose) =>
        "wp7:" + Id + ":" + purpose.WireName() + ":split1:scalarpool1:prefixl2:ctx";

    private static int? ContextSuffix(string value, string prefix)
    {
        if (!value.StartsWith(prefix, StringComparison.Ordinal)) return null;
        var digits = value[prefix.Length..];
        if (digits.Length == 0 || digits.Length > 10 || digits[0] == '0' || digits.Any(c => c < '0' || c > '9'))
            return null;
        return long.TryParse(digits, System.Globalization.NumberStyles.None,
            System.Globalization.CultureInfo.InvariantCulture, out var v) && v <= int.MaxValue ? (int)v : null;
    }
}

public static class EmbeddingProfiles
{
    public static readonly IReadOnlyList<string> Ids =
        ["nomic-v2-256", "nomic-v2-768", "qwen3-06b-256", "qwen3-06b-512", "qwen3-06b-1024", "bge-m3-1024", "paraphrase-768"];

    private static readonly Lazy<IReadOnlyList<EmbeddingProfile>> Cached = new(Load);

    public static IReadOnlyList<EmbeddingProfile> Bundled() => Cached.Value;

    /// <summary>Exact catalog ID only; a model name is never accepted as an ID.</summary>
    public static EmbeddingProfile Require(string id) =>
        Bundled().FirstOrDefault(p => string.Equals(p.Id, id, StringComparison.Ordinal))
        ?? throw new EmbeddingProfileException("unknownProfile");

    /// <summary>
    /// Catalog invariants: seven unique IDs in contract order, positive dims and ceilings,
    /// <c>Dims ≤ NativeDims</c>, reduction only for Matryoshka rows.
    /// </summary>
    public static void Validate(IReadOnlyList<EmbeddingProfile> profiles)
    {
        if (!profiles.Select(p => p.Id).SequenceEqual(Ids, StringComparer.Ordinal))
            throw new EmbeddingProfileException("invalidProfile");
        foreach (var p in profiles)
        {
            if (string.IsNullOrEmpty(p.Model) || string.IsNullOrEmpty(p.TokenizerId) || p.QueryPrefix is null
                || p.DocumentPrefix is null || p.NativeDims <= 0 || p.Dims <= 0 || p.Dims > p.NativeDims
                || p.MaxInputTokens <= 0 || (!p.Matryoshka && p.Dims != p.NativeDims)
                || (p.CeilingSource != "model-card" && p.CeilingSource != "ollama-512"))
                throw new EmbeddingProfileException("invalidProfile");
        }
    }

    /// <summary>Reads an embedded <c>AINotebook.Benchmark.&lt;file&gt;</c> resource (linked from Sources/).</summary>
    internal static byte[] ReadBenchmarkResource(string fileName)
    {
        using var stream = typeof(EmbeddingProfiles).Assembly.GetManifestResourceStream("AINotebook.Benchmark." + fileName)
            ?? throw new EmbeddingProfileException("missingResource");
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return buffer.ToArray();
    }

    private sealed record Catalog(
        [property: JsonPropertyName("contract")] string Contract,
        [property: JsonPropertyName("version")] int Version,
        [property: JsonPropertyName("profiles")] List<EmbeddingProfile> Profiles);

    private static IReadOnlyList<EmbeddingProfile> Load()
    {
        var catalog = JsonSerializer.Deserialize<Catalog>(ReadBenchmarkResource("embedding-profiles-v1.json"))
            ?? throw new EmbeddingProfileException("invalidProfile");
        if (catalog.Contract != "embedding-profiles" || catalog.Version != 1 || catalog.Profiles is null)
            throw new EmbeddingProfileException("invalidProfile");
        Validate(catalog.Profiles);
        return catalog.Profiles.AsReadOnly();
    }
}

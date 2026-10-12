using System.Text.Json;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public sealed class EmbeddingProfileTests
{
    private static readonly JsonElement Root = SharedFixtures.Json("contracts/embedding-profiles-v1.json");

    private static IEnumerable<JsonElement> Cases(string kind) =>
        Root.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("kind").GetString() == kind);

    private static EmbeddingPurpose Purpose(string value) => value switch
    {
        "query" => EmbeddingPurpose.Query,
        "document" => EmbeddingPurpose.Document,
        _ => throw new InvalidOperationException(value),
    };

    internal static float Number(JsonElement e) => e.ValueKind == JsonValueKind.String
        ? e.GetString() switch
        {
            "NaN" => float.NaN,
            "Infinity" => float.PositiveInfinity,
            "-Infinity" => float.NegativeInfinity,
            var s => throw new InvalidOperationException(s),
        }
        : e.GetSingle();

    internal static float[] Vector(JsonElement e) => e.EnumerateArray().Select(Number).ToArray();

    internal static void AssertMillionths(JsonElement expected, float[] actual)
    {
        var want = expected.EnumerateArray().Select(x => x.GetInt64()).ToArray();
        Assert.Equal(want.Length, actual.Length);
        for (int i = 0; i < want.Length; i++)
            Assert.InRange(Math.Abs(actual[i] - want[i] / 1_000_000.0), 0, 1e-6);
    }

    private static string Code(Action action) => Assert.Throws<EmbeddingProfileException>(action).Code;

    [Fact]
    public void SharedFormats()
    {
        int n = 0;
        foreach (var c in Cases("format"))
        {
            var p = EmbeddingProfiles.Require(c.GetProperty("profileId").GetString()!);
            var purpose = Purpose(c.GetProperty("purpose").GetString()!);
            Assert.Equal(c.GetProperty("expected").GetString(), p.Format(c.GetProperty("text").GetString()!, purpose));
            Assert.Equal(c.GetProperty("formatVersion").GetString(), p.FormatVersion(purpose));
            n++;
        }
        Assert.Equal(14, n);
    }

    [Fact]
    public void SharedFormatVersionsWithEffectiveLimit()
    {
        int n = 0;
        foreach (var c in Cases("formatVersion"))
        {
            var p = EmbeddingProfiles.Require(c.GetProperty("profileId").GetString()!);
            int limit = c.GetProperty("effectiveLimit").GetInt32();
            Assert.Equal(c.GetProperty("query").GetString(), p.FormatVersion(EmbeddingPurpose.Query, limit));
            Assert.Equal(c.GetProperty("document").GetString(), p.FormatVersion(EmbeddingPurpose.Document, limit));
            Assert.Equal(limit, p.EffectiveLimit(c.GetProperty("query").GetString()!, EmbeddingPurpose.Query));
            n++;
        }
        Assert.Equal(3, n);
    }

    [Fact]
    public void SharedRequireRejectsUnknownAndModelSpellings()
    {
        int n = 0;
        foreach (var c in Cases("require"))
        {
            Assert.Equal(c.GetProperty("error").GetString(),
                Code(() => EmbeddingProfiles.Require(c.GetProperty("profileId").GetString()!)));
            n++;
        }
        Assert.Equal(2, n);
    }

    [Fact]
    public void SharedIdentityAgreement()
    {
        int n = 0;
        foreach (var c in Cases("identity"))
        {
            var p = EmbeddingProfiles.Require(c.GetProperty("profileId").GetString()!);
            void Check() => p.ValidateIdentity(c.GetProperty("model").GetString()!, c.GetProperty("dims").GetInt32(),
                c.GetProperty("queryFormatVersion").GetString()!, c.GetProperty("docFormatVersion").GetString()!);
            if (c.GetProperty("error").ValueKind == JsonValueKind.Null) Check();
            else Assert.Equal(c.GetProperty("error").GetString(), Code(Check));
            n++;
        }
        Assert.Equal(5, n);
    }

    [Fact]
    public void SharedProjection()
    {
        int n = 0;
        foreach (var c in Cases("project"))
        {
            float[] Run() => EmbeddingInput.Project(Vector(c.GetProperty("vector")),
                c.GetProperty("nativeDims").GetInt32(), c.GetProperty("dims").GetInt32());
            if (c.TryGetProperty("error", out var error)) Assert.Equal(error.GetString(), Code(() => Run()));
            else AssertMillionths(c.GetProperty("expectedMillionths"), Run());
            n++;
        }
        Assert.Equal(8, n);
    }

    [Fact]
    public void SharedPooling()
    {
        int n = 0;
        foreach (var c in Cases("pool"))
        {
            float[] Run() => EmbeddingInput.Pool(
                c.GetProperty("vectors").EnumerateArray().Select(Vector).ToArray(),
                c.GetProperty("scalarWeights").EnumerateArray().Select(x => x.GetInt32()).ToArray());
            if (c.TryGetProperty("error", out var error)) Assert.Equal(error.GetString(), Code(() => Run()));
            else AssertMillionths(c.GetProperty("expectedMillionths"), Run());
            n++;
        }
        Assert.Equal(7, n);
    }

    [Fact]
    public void SharedBisect()
    {
        int n = 0;
        foreach (var c in Cases("bisect"))
        {
            var text = c.GetProperty("text").GetString()!;
            if (c.TryGetProperty("error", out var error))
                Assert.Equal(error.GetString(), Code(() => EmbeddingInput.Bisect(text)));
            else
            {
                var (left, right) = EmbeddingInput.Bisect(text);
                Assert.Equal(c.GetProperty("left").GetString(), left);
                Assert.Equal(c.GetProperty("right").GetString(), right);
                Assert.Equal(text, left + right);
            }
            n++;
        }
        Assert.Equal(4, n);
    }

    [Fact]
    public void ProjectionAndCompleteScalarSplit()
    {
        var v = EmbeddingInput.Project([3, 4, 12], 3, 2);
        Assert.InRange(Math.Abs(v[0] - 0.6f), 0, 0.000001f);
        Assert.InRange(Math.Abs(v[1] - 0.8f), 0, 0.000001f);
        var (a, b) = EmbeddingInput.Bisect("ab😀cd");
        Assert.Equal("ab", a); Assert.Equal("😀cd", b); Assert.Equal("ab😀cd", a + b);
        Assert.Throws<EmbeddingProfileException>(() => EmbeddingInput.Project([0, 0], 2, 2));
    }

    [Fact]
    public void BundledCatalogEqualsSharedProfilesInOrder()
    {
        var bundled = EmbeddingProfiles.Bundled();
        var shared = Root.GetProperty("profiles").EnumerateArray().ToArray();
        Assert.Equal(shared.Length, bundled.Count);
        for (int i = 0; i < shared.Length; i++)
        {
            var s = shared[i]; var p = bundled[i];
            Assert.Equal(s.GetProperty("id").GetString(), p.Id);
            Assert.Equal(s.GetProperty("model").GetString(), p.Model);
            Assert.Equal(s.GetProperty("tokenizerId").GetString(), p.TokenizerId);
            Assert.Equal(s.GetProperty("queryPrefix").GetString(), p.QueryPrefix);
            Assert.Equal(s.GetProperty("documentPrefix").GetString(), p.DocumentPrefix);
            Assert.Equal(s.GetProperty("nativeDims").GetInt32(), p.NativeDims);
            Assert.Equal(s.GetProperty("dims").GetInt32(), p.Dims);
            Assert.Equal(s.GetProperty("maxInputTokens").GetInt32(), p.MaxInputTokens);
            Assert.Equal(s.GetProperty("matryoshka").GetBoolean(), p.Matryoshka);
            Assert.Equal(s.GetProperty("ceilingSource").GetString(), p.CeilingSource);
        }
        Assert.Equal(EmbeddingProfiles.Ids, bundled.Select(p => p.Id));
    }

    [Fact]
    public void CatalogValidationRejectsInvalidRows()
    {
        var rows = EmbeddingProfiles.Bundled().ToList();
        Assert.Equal("invalidProfile", Code(() => EmbeddingProfiles.Validate(rows.Take(6).ToList())));
        var reducedNonMatryoshka = rows.ToList();
        reducedNonMatryoshka[5] = reducedNonMatryoshka[5] with { Dims = 512 };
        Assert.Equal("invalidProfile", Code(() => EmbeddingProfiles.Validate(reducedNonMatryoshka)));
        var zeroCeiling = rows.ToList();
        zeroCeiling[0] = zeroCeiling[0] with { MaxInputTokens = 0 };
        Assert.Equal("invalidProfile", Code(() => EmbeddingProfiles.Validate(zeroCeiling)));
    }

    [Fact]
    public void UnpairedSurrogatesAreRejectedBeforeRuneEnumeration()
    {
        Assert.Equal("invalidText", Code(() => EmbeddingInput.Bisect("ab\uD800cd")));
        var p = EmbeddingProfiles.Require("bge-m3-1024");
        Assert.Equal("invalidText", Code(() => p.Format("x\uDC00", EmbeddingPurpose.Query)));
    }
}

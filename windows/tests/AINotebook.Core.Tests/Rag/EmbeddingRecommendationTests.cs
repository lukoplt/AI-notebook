using System.Text.Json;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public sealed class EmbeddingRecommendationTests
{
    private static readonly JsonElement Root = SharedFixtures.Json("contracts/embedding-default-v1.json");
    private static readonly JsonSerializerOptions Options = new() { PropertyNameCaseInsensitive = true };

    private static IEnumerable<JsonElement> Cases(string kind) =>
        Root.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("kind").GetString() == kind);

    private static string Code(Action action) => Assert.Throws<EmbeddingRecommendationException>(action).Code;

    [Fact]
    public void SharedFreshInstallDecisions()
    {
        int n = 0;
        foreach (var row in Cases("install"))
        {
            var input = row.GetProperty("input");
            var e = input.GetProperty("evidence").Deserialize<EmbeddingInstallEvidence>(Options)!;
            var d = input.GetProperty("decision").Deserialize<EmbeddingDecision>(Options)!;
            var result = EmbeddingRecommendation.Initial(e, d);
            Assert.Equal(row.GetProperty("expected").GetProperty("applyProfileId").GetString(), result?.ProfileId);
            n++;
        }
        Assert.Equal(9, n);
    }

    [Fact]
    public void SharedInvalidDecisionsAreTypedErrors()
    {
        int n = 0;
        foreach (var row in Cases("install-invalid"))
        {
            var input = row.GetProperty("input");
            var e = input.GetProperty("evidence").Deserialize<EmbeddingInstallEvidence>(Options)!;
            var d = input.GetProperty("decision").Deserialize<EmbeddingDecision>(Options)!;
            Assert.Equal(row.GetProperty("error").GetString(), Code(() => EmbeddingRecommendation.Initial(e, d)));
            n++;
        }
        Assert.Equal(5, n);
    }

    [Fact]
    public void SharedSelectionAndIdentity()
    {
        int n = 0;
        foreach (var row in Cases("selection"))
        {
            var s = EmbeddingRecommendation.Selection(row.GetProperty("profileId").GetString()!);
            Assert.Equal(row.GetProperty("expected").Deserialize<EmbeddingModelChoice>(Options), s);
            n++;
        }
        foreach (var row in Cases("identity"))
        {
            var selection = row.GetProperty("selection").Deserialize<EmbeddingModelChoice>(Options)!;
            int? limit = row.GetProperty("effectiveLimit").ValueKind == JsonValueKind.Null ? null : row.GetProperty("effectiveLimit").GetInt32();
            string? digest = row.GetProperty("modelDigest").ValueKind == JsonValueKind.Null ? null : row.GetProperty("modelDigest").GetString();
            GenerationIdentity Run() => EmbeddingRecommendation.Identity(selection, row.GetProperty("endpointRevision").GetString()!,
                digest, row.GetProperty("chunkerVersion").GetString()!, limit);
            if (row.TryGetProperty("error", out var error)) Assert.Equal(error.GetString(), Code(() => Run()));
            else Assert.Equal(row.GetProperty("expected").Deserialize<GenerationIdentity>(Options), Run());
            n++;
        }
        Assert.Equal(4, n);
    }

    [Fact]
    public void IdentityIncludesDimensionAndBothFormats()
    {
        var s = EmbeddingRecommendation.Selection("nomic-v2-256");
        var i = EmbeddingRecommendation.Identity(s, "endpoint-v1:test", "sha256:test", "1");
        Assert.Equal(256, i.Dims);
        Assert.Equal("wp7:nomic-v2-256:query:split1:scalarpool1:prefixl2:ctx512", i.QueryFormatVersion);
        Assert.Equal("wp7:nomic-v2-256:document:split1:scalarpool1:prefixl2:ctx512", i.DocFormatVersion);
        Assert.Throws<EmbeddingRecommendationException>(() =>
            EmbeddingRecommendation.Identity(s with { Model = "other" }, "endpoint-v1:test", null, "1"));
        Assert.Equal("wp7:nomic-v2-256:query:split1:scalarpool1:prefixl2:ctx300",
            EmbeddingRecommendation.Identity(s, "e", null, "2", 300).QueryFormatVersion);
        Assert.Equal("invalidEffectiveLimit", Code(() => EmbeddingRecommendation.Identity(s, "e", null, "2", 513)));
        Assert.Equal("unknownProfile", Code(() => EmbeddingRecommendation.Selection("nomic-embed-text-v2-moe")));
    }

    [Fact]
    public void BundledDecisionIsTheValidatedProductionResource()
    {
        var decision = EmbeddingDecision.Bundled();
        Assert.Equal("embedding-decision", decision.Contract);
        Assert.Equal(1, decision.Version);
        Assert.Contains(decision.Status, new[] { "pending", "accepted" });
        // Valid production data: Initial never throws on a fresh install.
        var fresh = new EmbeddingInstallEvidence(false, false, false, false, false);
        var selection = EmbeddingRecommendation.Initial(fresh, decision);
        Assert.Equal(decision.Status == "accepted" ? decision.ProfileId : null, selection?.ProfileId);
    }
}

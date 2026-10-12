using System.Text.Json;
using System.Text.Json.Serialization;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

/// <summary>Core policy error (benchmark-v1 §8 install/selection/identity), independent of Eval.</summary>
public sealed class EmbeddingRecommendationException : Exception
{
    public string Code { get; }

    public EmbeddingRecommendationException(string code) : base(code) => Code = code;

    public EmbeddingRecommendationException(string code, Exception inner) : base(code, inner) => Code = code;
}

public sealed record EmbeddingInstallEvidence(bool DatabaseExists, bool PreferencesExist,
    bool CompletedOnboarding, bool ExplicitSelection, bool ConvertedChatOnly);

/// <summary>The shipped <c>embedding-decision</c> resource's selection fields.</summary>
public sealed record EmbeddingDecision(
    [property: JsonPropertyName("contract")] string Contract,
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("profileId")] string? ProfileId)
{
    private static readonly Lazy<EmbeddingDecision> Cached = new(() =>
    {
        var decision = Parse(EmbeddingProfiles.ReadBenchmarkResource("embedding-decision-v1.json"));
        // Validate the production data itself, whatever install evidence later meets it.
        EmbeddingRecommendation.Initial(new EmbeddingInstallEvidence(true, true, true, true, true), decision);
        return decision;
    });

    public static EmbeddingDecision Bundled() => Cached.Value;

    public static EmbeddingDecision Parse(byte[] json)
    {
        try
        {
            return JsonSerializer.Deserialize<EmbeddingDecision>(json) ?? throw new EmbeddingRecommendationException("invalidDecision");
        }
        catch (JsonException) { throw new EmbeddingRecommendationException("invalidDecision"); }
    }
}

public sealed record EmbeddingModelChoice(string ProviderId, string Model, string? ProfileId);

/// <summary>Fresh-install default and profile identity policy. No settings, filesystem or HTTP.</summary>
public static class EmbeddingRecommendation
{
    /// <summary>
    /// The accepted profile only for a truly fresh install; null preserves current behavior (including the
    /// legacy default of an existing installation). Malformed decisions throw <c>invalidDecision</c>.
    /// </summary>
    public static EmbeddingModelChoice? Initial(EmbeddingInstallEvidence e, EmbeddingDecision d)
    {
        ArgumentNullException.ThrowIfNull(e);
        ArgumentNullException.ThrowIfNull(d);
        if (d.Contract != "embedding-decision" || d.Version != 1 || d.Status is not ("pending" or "accepted"))
            throw new EmbeddingRecommendationException("invalidDecision");
        if (d.Status == "pending")
        {
            if (d.ProfileId is not null) throw new EmbeddingRecommendationException("invalidDecision");
            return null;
        }
        if (d.ProfileId is null) throw new EmbeddingRecommendationException("invalidDecision");
        var selected = Selection(d.ProfileId); // validated even when this install is preserved
        return e.DatabaseExists || e.PreferencesExist || e.CompletedOnboarding || e.ExplicitSelection || e.ConvertedChatOnly
            ? null : selected;
    }

    /// <summary>Exact catalog ID → local Ollama plus its model; never inferred from a model spelling.</summary>
    public static EmbeddingModelChoice Selection(string profileId)
    {
        var profile = Require(profileId);
        return new(ProviderConfig.OllamaId, profile.Model, profile.Id);
    }

    public static GenerationIdentity Identity(EmbeddingModelChoice selection, string endpointRevision, string? modelDigest,
        string chunkerVersion, int? effectiveLimit = null)
    {
        ArgumentNullException.ThrowIfNull(selection);
        if (selection.ProfileId is null) throw new EmbeddingRecommendationException("profileRequired");
        var profile = Require(selection.ProfileId);
        if (!string.Equals(profile.Model, selection.Model, StringComparison.Ordinal))
            throw new EmbeddingRecommendationException("profileIdentityMismatch");
        int limit = effectiveLimit ?? profile.MaxInputTokens;
        if (limit < 1 || limit > profile.MaxInputTokens) throw new EmbeddingRecommendationException("invalidEffectiveLimit");
        return new GenerationIdentity(selection.ProviderId, endpointRevision, selection.Model, modelDigest, profile.Dims, "l2",
            profile.FormatVersion(EmbeddingPurpose.Query, limit), profile.FormatVersion(EmbeddingPurpose.Document, limit), chunkerVersion);
    }

    private static EmbeddingProfile Require(string profileId)
    {
        try { return EmbeddingProfiles.Require(profileId); }
        catch (EmbeddingProfileException error) when (error.Code == "unknownProfile")
        {
            throw new EmbeddingRecommendationException("unknownProfile");
        }
    }
}

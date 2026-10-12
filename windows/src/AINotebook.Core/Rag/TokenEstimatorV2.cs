using System.Text;
using AINotebook.Core.Eval;

namespace AINotebook.Core.Rag;

public sealed record TokenRate(string Family, string Language, int TokensPerScalarBp);

/// <summary>Exact (model, digest) → calibration family; never a substring or alias match.</summary>
public sealed record TokenFamilyBinding(string Model, string ModelDigest, string Family);

/// <summary>
/// Calibrated estimator v2 (benchmark-v1 §4): per-family scalar rates with 15% headroom; a family
/// without rates is the explicitly uncalibrated UTF-8 byte fallback. Saturates, never wraps.
/// </summary>
public sealed class TokenEstimatorV2 : IContextTokenEstimator
{
    public const int MaxRateBp = 1_000_000;
    public const int MaxScalars = 5_000_000;
    public const int HeadroomBp = 1500;
    public const string UnverifiedFamily = "unverified";

    private readonly TokenRate[] _rates;

    public int Version => 2;
    public string Family { get; }
    public IReadOnlyList<TokenRate> Rates => _rates;

    public TokenEstimatorV2(string family, IReadOnlyList<TokenRate> rates)
    {
        ArgumentNullException.ThrowIfNull(rates);
        Family = family ?? throw new ArgumentNullException(nameof(family));
        _rates = rates.ToArray();
        TokenCalibration.ValidateRates(_rates);
    }

    /// <summary>
    /// The production estimator for a chat model: calibrated rates only for an exact bound
    /// (model, digest); a missing digest or a pending resource is the UTF-8 fallback.
    /// </summary>
    public static TokenEstimatorV2 Bundled(string model, string? modelDigest = null)
    {
        var resource = TokenEstimateResource.Bundled();
        var family = ResolveFamily(model, modelDigest, resource.Bindings);
        return family is null ? new(UnverifiedFamily, []) : new(family, resource.Rates);
    }

    public static string? ResolveFamily(string model, string? modelDigest, IReadOnlyList<TokenFamilyBinding> bindings)
    {
        ArgumentNullException.ThrowIfNull(bindings);
        if (modelDigest is null) return null;
        return bindings.FirstOrDefault(b => string.Equals(b.Model, model, StringComparison.Ordinal)
            && string.Equals(b.ModelDigest, modelDigest, StringComparison.Ordinal))?.Family;
    }

    /// <summary>Exact language row of the family, else the family maximum (so <c>und</c> never borrows English).</summary>
    internal static int? FamilyRate(string family, string language, IReadOnlyList<TokenRate> rates)
    {
        int? max = null;
        foreach (var r in rates)
        {
            if (!string.Equals(r.Family, family, StringComparison.Ordinal)) continue;
            if (string.Equals(r.Language, language, StringComparison.Ordinal)) return r.TokensPerScalarBp;
            max = max is null ? r.TokensPerScalarBp : Math.Max(max.Value, r.TokensPerScalarBp);
        }
        return max;
    }

    internal static long WithHeadroom(long basis) =>
        basis > int.MaxValue / 2 ? int.MaxValue : Math.Min(int.MaxValue, BenchmarkMath.CeilDiv(basis * (10_000 + HeadroomBp), 10_000));

    /// <summary>Scalar-count estimate used by calibration validation (no UTF-8 fallback possible).</summary>
    internal static long EstimateScalars(long scalars, int rateBp) =>
        scalars > MaxScalars ? int.MaxValue : WithHeadroom(BenchmarkMath.CeilDiv(scalars * rateBp, 10_000));

    public int Estimate(string text, string language)
    {
        if (text is null || language is null) throw new ContextPackException("invalidInput");
        long basis;
        if (FamilyRate(Family, language, _rates) is int rate)
        {
            long n = 0;
            foreach (var _ in text.EnumerateRunes())
                if (++n > MaxScalars) return int.MaxValue;
            basis = BenchmarkMath.CeilDiv(n * rate, 10_000);
        }
        else basis = Encoding.UTF8.GetByteCount(text); // explicitly uncalibrated conservative fallback
        return (int)WithHeadroom(basis);
    }
}

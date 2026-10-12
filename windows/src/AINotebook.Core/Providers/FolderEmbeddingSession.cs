using AINotebook.Core.Ingestion;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Providers;

/// <summary>
/// WP6 background-indexing view of one captured <see cref="ProviderEmbeddingSession"/>. The provider session
/// (WP5/WP7) is the single source of truth for endpoint identity, format versions and document/query embedding;
/// this adapter adds only the nonsecret WP6 <see cref="EmbeddingSelection"/> that jobs persist plus response
/// validation. Later configuration edits never redirect it, and the API key lives only inside the provider
/// session's private adapter: it is never exposed, serialized or rendered by <see cref="ToString"/>.
/// </summary>
public sealed class FolderEmbeddingSession
{
    private readonly object _gate = new();
    private GenerationIdentity? _verified;

    /// <summary>Raw-input capture (<c>legacy</c>/<c>1</c> formats) from a provider configuration.</summary>
    public FolderEmbeddingSession(ProviderConfig config, string model, string? apiKey, string? modelDigest,
        string queryFormatVersion, string docFormatVersion, HttpClient http)
    {
        ArgumentNullException.ThrowIfNull(config);
        ArgumentNullException.ThrowIfNull(http);
        if (!config.Enabled) throw new ProviderConfigurationException("providerDisabled");
        if (string.IsNullOrWhiteSpace(model)) throw new ProviderConfigurationException("invalidModel");
        if (!config.Type.SupportsEmbeddings()) throw new ProviderConfigurationException("unsupportedEndpoint");
        if (config.IsCloud && !config.PrivacyAcknowledged)
            throw new ProviderConsentException("Privacy acknowledgement required before background embeddings.");
        if (string.IsNullOrWhiteSpace(queryFormatVersion) || string.IsNullOrWhiteSpace(docFormatVersion))
            throw new ProviderConfigurationException("invalidValue");
        // Named WP7 formats need a prepared profile session (the ProviderEmbeddingSession constructor).
        if (!EmbeddingQueryFormat.IsSupported(queryFormatVersion) || !EmbeddingQueryFormat.IsSupported(docFormatVersion))
            throw new RetrievalException("unsupportedQueryFormat");
        // A raw space pairs one format for both purposes (embedding-raw-format-v2 §2).
        if (!string.Equals(queryFormatVersion, docFormatVersion, StringComparison.Ordinal))
            throw new RetrievalException("unsupportedQueryFormat");
        Provider = ProviderEmbeddingSession.CaptureRaw(config, model, apiKey, http, docFormatVersion);
        Model = model;
        Selection = new EmbeddingSelection(config.Id, Provider.EndpointRevision, model, modelDigest, null, "l2",
            queryFormatVersion, docFormatVersion, "2");
    }

    /// <summary>Adapts a prepared WP7 named-profile session; its identity is the selection.</summary>
    public FolderEmbeddingSession(ProviderEmbeddingSession profileSession)
    {
        ArgumentNullException.ThrowIfNull(profileSession);
        if (profileSession.Profile is null || profileSession.Identity is not { } identity)
            throw new EmbeddingProfileException("unsupportedEmbeddingProfile");
        Provider = profileSession;
        Model = identity.Model;
        Selection = new EmbeddingSelection(identity.ProviderId, identity.EndpointRevision, identity.Model, identity.ModelDigest,
            identity.Dims, identity.Normalization, identity.QueryFormatVersion, identity.DocFormatVersion, identity.ChunkerVersion);
    }

    /// <summary>The shared session every request goes through (document purpose).</summary>
    public ProviderEmbeddingSession Provider { get; }

    public string Model { get; }

    /// <summary>
    /// The captured, nonsecret selection. Raw captures leave dimensions unknown here (see
    /// <see cref="VerifiedIdentity"/>); a named profile knows them up front.
    /// </summary>
    public EmbeddingSelection Selection { get; }

    /// <summary>Full identity once a real response verified the dimensions; null before.</summary>
    public GenerationIdentity? VerifiedIdentity { get { lock (_gate) return _verified; } }

    public GenerationIdentity Identity(int dims)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(dims, 1);
        if (Selection.Dims is int known && known != dims) throw new FolderIngestionException("invalidVector");
        return IngestionGenerationSQL.Identity(Selection, dims);
    }

    /// <summary>
    /// Sends one batch (document purpose) through the shared session. Count, dimensions (consistent across
    /// batches), finiteness and nonzero norm are validated; a violation is <c>invalidVector</c>.
    /// </summary>
    public async Task<float[][]> EmbedAsync(IReadOnlyList<string> inputs, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(inputs);
        if (inputs.Count == 0) return [];
        var vectors = await Provider.EmbedDocumentsAsync(inputs, ct).ConfigureAwait(false);
        int dims = FolderIndexCoordinator.ValidatedDimensions(vectors, inputs.Count);
        lock (_gate)
        {
            if (_verified is { } verified && verified.Dims != dims) throw new FolderIngestionException("invalidVector");
            _verified ??= Identity(dims);
        }
        return vectors;
    }

    public override string ToString() => $"FolderEmbeddingSession({Selection.ProviderId}:{Model})";

    /// <summary>
    /// Pure availability check in contract order (<c>indexing-status-v1</c> §4); <paramref name="loadKey"/> runs only
    /// after every cheaper check passed, and a throwing load is <c>credentialUnavailable</c>.
    /// </summary>
    public static (EmbeddingAvailability Availability, string? Key) Availability(ProviderConfig? config, string? model,
        Func<string?> loadKey)
    {
        ArgumentNullException.ThrowIfNull(loadKey);
        if (config is null) return (EmbeddingAvailability.NoProvider, null);
        if (!config.Type.SupportsEmbeddings()) return (EmbeddingAvailability.ProviderHasNoEmbeddings, null);
        if (!config.Enabled) return (EmbeddingAvailability.ProviderDisabled, null);
        if (string.IsNullOrWhiteSpace(model)) return (EmbeddingAvailability.NoModel, null);
        if (config.IsCloud && !config.PrivacyAcknowledged) return (EmbeddingAvailability.ConsentRequired, null);
        try { return (EmbeddingAvailability.Ready, loadKey()); }
        catch (Exception) { return (EmbeddingAvailability.CredentialUnavailable, null); }
    }

    /// <summary>
    /// Captures a raw-format session from the selected provider, or explains why none exists. Any other capture error
    /// (e.g. a malformed endpoint) maps to <c>noProvider</c>.
    /// </summary>
    public static EmbeddingSessionResolution Resolve(ProviderConfig? config, string? model, Func<string?> loadKey, HttpClient http,
        string? modelDigest = null, string queryFormatVersion = RawEmbeddingFormat.Current, string docFormatVersion = RawEmbeddingFormat.Current)
    {
        ArgumentNullException.ThrowIfNull(http);
        var (availability, key) = Availability(config, model, loadKey);
        if (availability != EmbeddingAvailability.Ready) return EmbeddingSessionResolution.Unavailable(availability);
        try
        {
            return EmbeddingSessionResolution.Ready(new FolderEmbeddingSession(config!, model!, key, modelDigest,
                queryFormatVersion, docFormatVersion, http));
        }
        catch (Exception)
        {
            return EmbeddingSessionResolution.Unavailable(EmbeddingAvailability.NoProvider);
        }
    }
}
